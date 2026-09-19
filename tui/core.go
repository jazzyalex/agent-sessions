package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// The TUI never parses session files itself: every read goes through the `as-core`
// binary, which shares its parsers and index with the macOS app. Output is one JSON
// object per line on stdout (see cli/as-core/Output.swift); schema 1.

const coreSchema = 1

// SessionRow is one `list` / `search` result (cli/as-core/Commands.swift metaSummary).
type SessionRow struct {
	ID       string  `json:"id"`
	Source   string  `json:"source"`
	Path     string  `json:"path"`
	Title    *string `json:"title"`
	Model    *string `json:"model"`
	Cwd      *string `json:"cwd"`
	Repo     *string `json:"repo"`
	Start    *string `json:"start"`
	End      *string `json:"end"`
	Modified *string `json:"modified"`
	Messages int     `json:"messages"`
	Commands int     `json:"commands"`
}

func (r SessionRow) DisplayTitle() string {
	if r.Title != nil && strings.TrimSpace(*r.Title) != "" {
		return oneLine(*r.Title)
	}
	return "(untitled)"
}

// ActivityTime is what `list` sorts by, so the age column agrees with the order.
func (r SessionRow) ActivityTime() time.Time {
	for _, s := range []*string{r.Modified, r.End, r.Start} {
		if s != nil {
			if t, err := time.Parse(time.RFC3339, *s); err == nil {
				return t
			}
		}
	}
	return time.Time{}
}

// Event is one `show` event line.
type Event struct {
	Type       string  `json:"type"`
	Kind       string  `json:"kind"`
	Timestamp  *string `json:"timestamp"`
	Text       *string `json:"text"`
	ToolName   *string `json:"toolName"`
	ToolInput  *string `json:"toolInput"`
	ToolOutput *string `json:"toolOutput"`
}

// ResumeCommand is the `resume` line.
type ResumeCommand struct {
	Command string  `json:"command"`
	Shell   string  `json:"shell"`
	Cwd     *string `json:"cwd"`
}

// IndexResult is one `index` line.
type IndexResult struct {
	Source    string `json:"source"`
	Files     int    `json:"files"`
	Processed int    `json:"processed"`
	Error     string `json:"error"`
}

// findCore resolves the as-core binary: $AS_CORE, then next to this executable,
// then $PATH.
func findCore() (string, error) {
	if p := os.Getenv("AS_CORE"); p != "" {
		return p, nil
	}
	if self, err := os.Executable(); err == nil {
		candidate := filepath.Join(filepath.Dir(self), "as-core")
		if st, err := os.Stat(candidate); err == nil && !st.IsDir() {
			return candidate, nil
		}
	}
	if p, err := exec.LookPath("as-core"); err == nil {
		return p, nil
	}
	return "", fmt.Errorf("as-core not found: set $AS_CORE, put it next to this binary, or on $PATH")
}

type Core struct{ bin string }

// run executes one as-core command and decodes each stdout line into T.
func run[T any](c Core, args ...string) ([]T, error) {
	cmd := exec.Command(c.bin, args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if i := strings.LastIndex(msg, "\n"); i >= 0 {
			msg = msg[i+1:]
		}
		return nil, fmt.Errorf("as-core %s: %v %s", args[0], err, msg)
	}
	var rows []T
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 0, 1<<20), 64<<20)
	for sc.Scan() {
		line := sc.Bytes()
		var probe struct {
			Schema int `json:"schema"`
		}
		if err := json.Unmarshal(line, &probe); err != nil {
			return nil, fmt.Errorf("as-core %s: bad JSON: %v", args[0], err)
		}
		if probe.Schema != coreSchema {
			return nil, fmt.Errorf("as-core %s: schema %d, want %d", args[0], probe.Schema, coreSchema)
		}
		var row T
		if err := json.Unmarshal(line, &row); err != nil {
			return nil, fmt.Errorf("as-core %s: %v", args[0], err)
		}
		rows = append(rows, row)
	}
	return rows, sc.Err()
}

func sourceArgs(source string) []string {
	if source == "" {
		return nil
	}
	return []string{"--source", source}
}

func (c Core) List(source string, limit int) ([]SessionRow, error) {
	args := append([]string{"list", "--limit", fmt.Sprint(limit)}, sourceArgs(source)...)
	return run[SessionRow](c, args...)
}

func (c Core) Search(query, source string, limit int) ([]SessionRow, error) {
	args := append([]string{"search", query, "--limit", fmt.Sprint(limit)}, sourceArgs(source)...)
	return run[SessionRow](c, args...)
}

func (c Core) Index() ([]IndexResult, error) {
	return run[IndexResult](c, "index")
}

// Show returns the session's events (the header line is skipped).
func (c Core) Show(row SessionRow) ([]Event, error) {
	lines, err := run[Event](c, "show", row.Source, row.Path, "--id", row.ID)
	if err != nil {
		return nil, err
	}
	events := lines[:0]
	for _, e := range lines {
		if e.Type == "event" {
			events = append(events, e)
		}
	}
	return events, nil
}

func (c Core) Resume(row SessionRow) (ResumeCommand, error) {
	cmds, err := run[ResumeCommand](c, "resume", row.Source, row.Path, "--id", row.ID)
	if err != nil {
		return ResumeCommand{}, err
	}
	if len(cmds) != 1 {
		return ResumeCommand{}, fmt.Errorf("as-core resume: expected one line, got %d", len(cmds))
	}
	return cmds[0], nil
}

func oneLine(s string) string {
	return strings.Join(strings.Fields(s), " ")
}
