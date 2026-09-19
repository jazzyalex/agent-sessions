package main

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
)

var (
	styleUser      = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("12"))
	styleAssistant = lipgloss.NewStyle()
	styleTool      = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	styleDim       = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	styleError     = lipgloss.NewStyle().Foreground(lipgloss.Color("9"))
)

// Per-source badge colors, roughly matching the macOS app's brand hues.
var sourceColors = map[string]string{
	"codex":       "4",
	"claude":      "173",
	"opencode":    "135",
	"copilot":     "7",
	"antigravity": "6",
}

func sourceBadge(source string) string {
	color, ok := sourceColors[source]
	if !ok {
		color = "7"
	}
	label := source
	if len(label) > 8 {
		label = label[:8]
	}
	return lipgloss.NewStyle().Foreground(lipgloss.Color(color)).Render(fmt.Sprintf("%-8s", label))
}

const toolOutputPreviewLines = 6

// renderTranscript turns events into wrapped, styled text for the preview pane.
func renderTranscript(events []Event, width int) string {
	if width < 20 {
		width = 20
	}
	wrap := lipgloss.NewStyle().Width(width)
	var b strings.Builder
	for _, e := range events {
		text := ""
		if e.Text != nil {
			text = strings.TrimSpace(*e.Text)
		}
		switch e.Kind {
		case "user":
			if text == "" {
				continue
			}
			b.WriteString(wrap.Render(styleUser.Render("› " + text)))
		case "assistant":
			if text == "" {
				continue
			}
			b.WriteString(wrap.Render(styleAssistant.Render(text)))
		case "tool_call":
			name := "tool"
			if e.ToolName != nil && *e.ToolName != "" {
				name = *e.ToolName
			}
			line := "⚙ " + name
			if e.ToolInput != nil {
				line += " " + truncate(oneLine(*e.ToolInput), width-len(line)-2)
			}
			b.WriteString(styleTool.Render(truncate(line, width)))
		case "tool_result":
			out := text
			if e.ToolOutput != nil && *e.ToolOutput != "" {
				out = *e.ToolOutput
			}
			if strings.TrimSpace(out) == "" {
				continue
			}
			b.WriteString(styleDim.Render(indentPreview(out, width, toolOutputPreviewLines)))
		case "error":
			b.WriteString(wrap.Render(styleError.Render("! " + text)))
		default: // meta
			continue
		}
		b.WriteString("\n\n")
	}
	if b.Len() == 0 {
		return styleDim.Render("(no user or assistant messages)")
	}
	return b.String()
}

func indentPreview(s string, width, maxLines int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	extra := 0
	if len(lines) > maxLines {
		extra = len(lines) - maxLines
		lines = lines[:maxLines]
	}
	for i, l := range lines {
		lines[i] = "  " + truncate(l, width-2)
	}
	if extra > 0 {
		lines = append(lines, fmt.Sprintf("  … %d more lines", extra))
	}
	return strings.Join(lines, "\n")
}

func truncate(s string, max int) string {
	if max <= 1 {
		return ""
	}
	r := []rune(s)
	if len(r) <= max {
		return s
	}
	return string(r[:max-1]) + "…"
}

func relativeTime(t time.Time, now time.Time) string {
	if t.IsZero() {
		return "—"
	}
	d := now.Sub(t)
	switch {
	case d < time.Minute:
		return "now"
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	case d < 30*24*time.Hour:
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	case t.Year() == now.Year():
		return t.Format("Jan 2")
	default:
		return t.Format("2006")
	}
}
