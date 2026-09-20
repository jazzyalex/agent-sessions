// Command as is the terminal UI for Agent Sessions: browse, search, and read local
// coding-agent sessions. All data comes from the `as-core` binary (the macOS app's
// shared Swift core), so parsing and search behave exactly as in the app.
package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

const listLimit = 500

type focus int

const (
	focusList focus = iota
	focusPreview
	focusSearch
)

// Messages from background as-core calls.
type (
	rowsMsg struct {
		rows  []SessionRow
		query string
		err   error
	}
	indexMsg struct {
		results []IndexResult
		err     error
	}
	previewMsg struct {
		id     string
		events []Event
		err    error
	}
	// previewDueMsg fires after the cursor has rested on a row for previewDelay.
	previewDueMsg struct{ id string }
	// refreshMsg fires while indexing so sessions show up as the engine stores them.
	refreshMsg struct{}
	resumeMsg  struct {
		cmd ResumeCommand
		err error
	}
	sourcesMsg struct {
		sources []Source
		err     error
	}
	// copyMsg carries a resume command fetched for the clipboard rather than for exec.
	copyMsg struct {
		cmd ResumeCommand
		err error
	}
)

// Each preview is a full parse in a separate as-core process, which can take seconds for
// a large Codex rollout; wait until the cursor stops instead of parsing every row passed.
const previewDelay = 150 * time.Millisecond

const ageWidth = 6

// While the index builds, re-read the list this often. The engine commits session by
// session, so a first run over gigabytes of history fills the list instead of showing an
// empty screen until the whole pass ends.
const refreshInterval = 2 * time.Second

func refreshTick() tea.Cmd {
	return tea.Tick(refreshInterval, func(time.Time) tea.Msg { return refreshMsg{} })
}

type model struct {
	core     Core
	rows     []SessionRow
	cursor   int
	offset   int
	focus    focus
	search   textinput.Model
	query    string // active search; "" means the plain newest-first list
	sources  []string
	srcIdx   int // index into sources; 0 = all
	preview  viewport.Model
	cache    map[string][]Event
	shownID  string
	status   string
	indexing bool
	width    int
	height   int
	// resume is set when the user picked "open in agent"; main execs it after the
	// TUI exits so the agent takes over this terminal.
	resume *ResumeCommand
}

func newModel(core Core) model {
	ti := textinput.New()
	ti.Placeholder = "search sessions"
	ti.Prompt = "/ "
	return model{
		core:   core,
		search: ti,
		// Replaced by the engine's own list once `sources` answers; "" means all.
		sources:  []string{""},
		cache:    map[string][]Event{},
		status:   "loading…",
		indexing: true,
	}
}

func (m model) source() string { return m.sources[m.srcIdx] }

func (m model) Init() tea.Cmd {
	// Show what the index already has right away, then refresh it in the background.
	return tea.Batch(m.loadRows(), m.runIndex(), m.loadSources(), refreshTick())
}

func (m model) loadRows() tea.Cmd {
	core, query, source := m.core, m.query, m.source()
	return func() tea.Msg {
		var rows []SessionRow
		var err error
		if query == "" {
			rows, err = core.List(source, listLimit)
		} else {
			rows, err = core.Search(query, source, listLimit)
		}
		return rowsMsg{rows: rows, query: query, err: err}
	}
}

func (m model) loadSources() tea.Cmd {
	core := m.core
	return func() tea.Msg {
		sources, err := core.Sources()
		return sourcesMsg{sources: sources, err: err}
	}
}

func (m model) runIndex() tea.Cmd {
	core := m.core
	return func() tea.Msg {
		results, err := core.Index()
		return indexMsg{results: results, err: err}
	}
}

func (m model) schedulePreview() tea.Cmd {
	if len(m.rows) == 0 {
		return nil
	}
	id := m.rows[m.cursor].ID
	if _, ok := m.cache[id]; ok {
		return nil
	}
	return tea.Tick(previewDelay, func(time.Time) tea.Msg { return previewDueMsg{id: id} })
}

func (m model) loadPreview() tea.Cmd {
	if len(m.rows) == 0 {
		return nil
	}
	row := m.rows[m.cursor]
	if _, ok := m.cache[row.ID]; ok {
		return nil
	}
	core := m.core
	return func() tea.Msg {
		events, err := core.Show(row)
		return previewMsg{id: row.ID, events: events, err: err}
	}
}

func (m *model) layout() {
	listW := m.listWidth()
	m.preview.Width = m.width - listW - 3
	m.preview.Height = m.bodyHeight()
	m.search.Width = listW - 4
}

func (m model) listWidth() int {
	w := m.width * 2 / 5
	if w < 30 {
		w = 30
	}
	return w
}

func (m model) bodyHeight() int {
	h := m.height - 3 // header + search/status line + footer
	if h < 3 {
		h = 3
	}
	return h
}

func (m *model) refreshPreview() {
	if len(m.rows) == 0 {
		m.preview.SetContent("")
		m.shownID = ""
		return
	}
	row := m.rows[m.cursor]
	if m.shownID == row.ID {
		return
	}
	events, ok := m.cache[row.ID]
	if !ok {
		m.preview.SetContent(styleDim.Render("loading…"))
		return
	}
	m.shownID = row.ID
	m.preview.SetContent(renderTranscript(events, m.preview.Width))
	m.preview.GotoTop()
}

func (m *model) moveCursor(delta int) tea.Cmd {
	if len(m.rows) == 0 {
		return nil
	}
	m.cursor += delta
	if m.cursor < 0 {
		m.cursor = 0
	}
	if m.cursor >= len(m.rows) {
		m.cursor = len(m.rows) - 1
	}
	h := m.bodyHeight()
	if m.cursor < m.offset {
		m.offset = m.cursor
	}
	if m.cursor >= m.offset+h {
		m.offset = m.cursor - h + 1
	}
	m.refreshPreview()
	return m.schedulePreview()
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.layout()
		m.shownID = "" // re-wrap at the new width
		m.refreshPreview()
		return m, nil

	case rowsMsg:
		if msg.query != m.query {
			return m, nil // stale result from an earlier query
		}
		if msg.err != nil {
			m.status = msg.err.Error()
			return m, nil
		}
		prevID, prevOffset := "", m.offset
		if len(m.rows) > 0 {
			prevID = m.rows[m.cursor].ID
		}
		m.rows = msg.rows
		m.cursor, m.offset = 0, 0
		for i, r := range m.rows {
			if r.ID == prevID {
				// Same session still there: keep it selected and the view where it was, so a
				// background refresh does not make the list jump.
				m.cursor, m.offset = i, prevOffset
				break
			}
		}
		m.shownID = ""
		cmd := m.moveCursor(0)
		if m.indexing {
			m.status = fmt.Sprintf("%d sessions so far", len(m.rows))
		} else {
			m.status = m.countStatus()
		}
		return m, cmd

	case refreshMsg:
		if !m.indexing {
			return m, nil // the index finished; stop polling
		}
		return m, tea.Batch(m.loadRows(), refreshTick())

	case indexMsg:
		m.indexing = false
		if msg.err != nil {
			m.status = "index failed: " + msg.err.Error()
			return m, nil
		}
		processed := 0
		for _, r := range msg.results {
			processed += r.Processed
		}
		m.status = fmt.Sprintf("index up to date (%d updated)", processed)
		return m, m.loadRows()

	case sourcesMsg:
		if msg.err != nil {
			m.status = msg.err.Error()
			return m, nil
		}
		current := m.source()
		m.sources = []string{""}
		for _, s := range msg.sources {
			m.sources = append(m.sources, s.Name)
		}
		m.srcIdx = 0
		for i, name := range m.sources {
			if name == current {
				m.srcIdx = i
			}
		}
		return m, nil

	case copyMsg:
		if msg.err != nil {
			m.status = msg.err.Error()
			return m, nil
		}
		copyToClipboard(msg.cmd.Shell)
		m.status = "copied: " + msg.cmd.Shell
		return m, nil

	case resumeMsg:
		if msg.err != nil {
			m.status = msg.err.Error()
			return m, nil
		}
		m.resume = &msg.cmd
		return m, tea.Quit

	case previewDueMsg:
		if len(m.rows) == 0 || m.rows[m.cursor].ID != msg.id {
			return m, nil // the cursor moved on
		}
		return m, m.loadPreview()

	case previewMsg:
		if msg.err != nil {
			m.cache[msg.id] = []Event{{Kind: "error", Text: strPtr(msg.err.Error())}}
		} else {
			m.cache[msg.id] = msg.events
		}
		m.refreshPreview()
		return m, nil

	case tea.KeyMsg:
		if m.focus == focusSearch {
			return m.updateSearch(msg)
		}
		switch msg.String() {
		case "ctrl+c", "q":
			return m, tea.Quit
		case "/":
			m.focus = focusSearch
			m.search.SetValue(m.query)
			return m, m.search.Focus()
		case "esc":
			if m.query != "" {
				m.query = ""
				return m, m.loadRows()
			}
		case "tab":
			if m.focus == focusList {
				m.focus = focusPreview
			} else {
				m.focus = focusList
			}
		case "s":
			m.srcIdx = (m.srcIdx + 1) % len(m.sources)
			return m, m.loadRows()
		case "y":
			if len(m.rows) > 0 {
				row, core := m.rows[m.cursor], m.core
				return m, func() tea.Msg {
					cmd, err := core.Resume(row)
					return copyMsg{cmd: cmd, err: err}
				}
			}
		case "Y":
			if len(m.rows) > 0 {
				path := m.rows[m.cursor].Path
				copyToClipboard(path)
				m.status = "copied path: " + path
			}
		case "o":
			if len(m.rows) > 0 {
				row, core := m.rows[m.cursor], m.core
				m.status = "preparing resume…"
				return m, func() tea.Msg {
					cmd, err := core.Resume(row)
					return resumeMsg{cmd: cmd, err: err}
				}
			}
		case "r":
			if !m.indexing {
				m.indexing = true
				m.status = "indexing…"
				return m, tea.Batch(m.runIndex(), refreshTick())
			}
		}
		if m.focus == focusPreview {
			var cmd tea.Cmd
			m.preview, cmd = m.preview.Update(msg)
			return m, cmd
		}
		switch msg.String() {
		case "up", "k":
			return m, m.moveCursor(-1)
		case "down", "j":
			return m, m.moveCursor(1)
		case "pgup":
			return m, m.moveCursor(-m.bodyHeight())
		case "pgdown":
			return m, m.moveCursor(m.bodyHeight())
		case "home", "g":
			return m, m.moveCursor(-len(m.rows))
		case "end", "G":
			return m, m.moveCursor(len(m.rows))
		case "enter":
			m.focus = focusPreview
		}
	}
	return m, nil
}

func (m model) updateSearch(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "enter":
		m.query = strings.TrimSpace(m.search.Value())
		m.focus = focusList
		m.search.Blur()
		m.status = "searching…"
		return m, m.loadRows()
	case "esc":
		m.focus = focusList
		m.search.Blur()
		return m, nil
	}
	var cmd tea.Cmd
	m.search, cmd = m.search.Update(msg)
	return m, cmd
}

func (m model) countStatus() string {
	if m.query != "" {
		return fmt.Sprintf("%d matches for %q", len(m.rows), m.query)
	}
	return fmt.Sprintf("%d sessions", len(m.rows))
}

var (
	styleHeader   = lipgloss.NewStyle().Bold(true)
	styleSelected = lipgloss.NewStyle().Reverse(true)
	styleBorder   = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
)

func (m model) View() string {
	if m.width == 0 {
		return ""
	}
	listW := m.listWidth()
	h := m.bodyHeight()
	now := time.Now()

	filter := "all sources"
	if m.source() != "" {
		filter = m.source()
	}
	header := styleHeader.Render("Agent Sessions") + styleDim.Render("  ·  "+filter)
	if m.query != "" {
		header += styleDim.Render("  ·  search: ") + m.query
	}

	var list strings.Builder
	for i := m.offset; i < len(m.rows) && i < m.offset+h; i++ {
		r := m.rows[i]
		age := fmt.Sprintf("%*s", ageWidth, relativeTime(r.ActivityTime(), now))
		titleW := listW - 8 - 1 - ageWidth - 2
		line := sourceBadge(r.Source) + " " + truncate(r.DisplayTitle(), titleW)
		pad := listW - lipgloss.Width(line) - lipgloss.Width(age)
		if pad < 1 {
			pad = 1
		}
		line += strings.Repeat(" ", pad) + styleDim.Render(age)
		if i == m.cursor {
			if m.focus == focusList {
				line = styleSelected.Render(lipgloss.NewStyle().Width(listW).Render(line))
			} else {
				line = styleHeader.Render(line)
			}
		}
		list.WriteString(line + "\n")
	}
	if len(m.rows) == 0 {
		if m.indexing {
			list.WriteString(styleDim.Render("Indexing your session history. The first run can take a few minutes; sessions appear here as they are found."))
		} else {
			list.WriteString(styleDim.Render("no sessions"))
		}
	}
	left := lipgloss.NewStyle().Width(listW).Height(h).MaxHeight(h).Render(list.String())
	sep := styleBorder.Render(strings.Repeat("│\n", h-1) + "│")
	body := lipgloss.JoinHorizontal(lipgloss.Top, left, " ", sep, " ", m.preview.View())

	status := styleDim.Render(m.status)
	if m.indexing {
		status = styleDim.Render("indexing… " + m.status)
	}
	if m.focus == focusSearch {
		status = m.search.View()
	}
	footer := styleDim.Render("↑↓ move · enter/tab read · o open · y copy command · Y copy path · / search · s source · r reindex · q quit")
	return lipgloss.JoinVertical(lipgloss.Left, header, body, status, footer)
}

func strPtr(s string) *string { return &s }

const usage = `agent-sessions - browse, search, read and resume local coding-agent sessions

usage: agent-sessions [--core-path | --help]

keys:  up/down move   enter read   / search   esc clear   s source   r reindex
       o open in agent   y copy resume command   Y copy path   q quit

The engine (agent-sessions-core) is found next to this program, in ../libexec/agent-sessions
or ../lib/agent-sessions, or on $PATH; $AS_CORE overrides. The index lives in
$XDG_DATA_HOME/agent-sessions/index.db (default ~/.local/share).
`

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "--help", "-h":
			fmt.Print(usage)
			return
		case "--core-path":
			bin, err := findCore()
			if err != nil {
				fmt.Fprintln(os.Stderr, "as:", err)
				os.Exit(1)
			}
			fmt.Println(bin)
			return
		default:
			fmt.Fprint(os.Stderr, usage)
			os.Exit(2)
		}
	}
	bin, err := findCore()
	if err != nil {
		fmt.Fprintln(os.Stderr, "as:", err)
		os.Exit(1)
	}
	ctx, cancel := context.WithCancel(context.Background())
	core := Core{bin: bin, ctx: ctx, running: &sync.WaitGroup{}}
	p := tea.NewProgram(newModel(core), tea.WithAltScreen())
	final, err := p.Run()
	// Stop a still-running index and wait for it to die (bounded), so nothing keeps
	// writing after we exit or hand the terminal to an agent via syscall.Exec.
	cancel()
	stopped := make(chan struct{})
	go func() { core.running.Wait(); close(stopped) }()
	select {
	case <-stopped:
	case <-time.After(3 * time.Second):
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "as:", err)
		os.Exit(1)
	}
	if m, ok := final.(model); ok && m.resume != nil {
		execResume(*m.resume)
	}
}

// execResume replaces this process with the agent, so it owns the terminal exactly as
// if the user had typed the command.
func execResume(cmd ResumeCommand) {
	fmt.Fprintln(os.Stderr, "→", cmd.Shell)
	sh, err := exec.LookPath("sh")
	if err != nil {
		fmt.Fprintln(os.Stderr, "as: sh not found:", err)
		os.Exit(1)
	}
	err = syscall.Exec(sh, []string{"sh", "-c", cmd.Shell}, os.Environ())
	fmt.Fprintln(os.Stderr, "as: exec failed:", err)
	os.Exit(1)
}
