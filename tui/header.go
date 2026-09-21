package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// The session header above the transcript: title, project directory, duration and message
// counts, then tokens and cost. Everything except tokens and cost comes from the list row;
// those two need a separate `stats` pass over the file, so they fill in when it finishes.

// headerLines is how many terminal lines the header takes, including its rule.
const headerLines = 5

// statsState is what the header knows about a session's token usage.
type statsState struct {
	loaded bool
	err    error
	stats  Stats
}

// formatDuration renders a span as its two most significant units: "45s", "12m", "2h 14m",
// "3d 4h".
func formatDuration(d time.Duration) string {
	if d < 0 {
		d = 0
	}
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		h, m := int(d.Hours()), int(d.Minutes())%60
		if m == 0 {
			return fmt.Sprintf("%dh", h)
		}
		return fmt.Sprintf("%dh %dm", h, m)
	default:
		days, h := int(d.Hours())/24, int(d.Hours())%24
		// Past a hundred days the hours are noise, and the shorter text keeps list columns tidy.
		if h == 0 || days >= 100 {
			return fmt.Sprintf("%dd", days)
		}
		return fmt.Sprintf("%dd %dh", days, h)
	}
}

// compactCount abbreviates a token count: 950, 12.3k, 1.24M, 2.1B.
func compactCount(n int) string {
	switch {
	case n < 1_000:
		return fmt.Sprintf("%d", n)
	case n < 100_000:
		return trimZero(fmt.Sprintf("%.1f", float64(n)/1e3)) + "k"
	case n < 1_000_000:
		return fmt.Sprintf("%dk", (n+500)/1000)
	case n < 100_000_000:
		return trimZero(fmt.Sprintf("%.2f", float64(n)/1e6)) + "M"
	case n < 1_000_000_000:
		return fmt.Sprintf("%dM", (n+500_000)/1_000_000)
	case n < 10_000_000_000:
		return trimZero(fmt.Sprintf("%.2f", float64(n)/1e9)) + "B"
	case n < 100_000_000_000:
		return trimZero(fmt.Sprintf("%.1f", float64(n)/1e9)) + "B"
	default:
		return fmt.Sprintf("%dB", (n+500_000_000)/1_000_000_000)
	}
}

func trimZero(s string) string {
	if strings.Contains(s, ".") {
		s = strings.TrimRight(strings.TrimRight(s, "0"), ".")
	}
	return s
}

func formatCost(usd float64) string {
	switch {
	case usd <= 0:
		return "$0"
	case usd < 0.01:
		return "<$0.01"
	case usd < 100:
		return fmt.Sprintf("$%.2f", usd)
	default:
		return fmt.Sprintf("$%.0f", usd)
	}
}

// shortenPath replaces the home directory with ~ and, if the result still exceeds max
// columns, keeps the tail (the project name matters more than its parents).
func shortenPath(path, home string, max int) string {
	if home != "" && (path == home || strings.HasPrefix(path, home+"/")) {
		path = "~" + strings.TrimPrefix(path, home)
	}
	r := []rune(path)
	if max <= 1 || len(r) <= max {
		return path
	}
	return "…" + string(r[len(r)-(max-1):])
}

func plural(n int, one, many string) string {
	if n == 1 {
		return fmt.Sprintf("%d %s", n, one)
	}
	return fmt.Sprintf("%s %s", groupThousands(n), many)
}

func groupThousands(n int) string {
	s := fmt.Sprintf("%d", n)
	for i := len(s) - 3; i > 0; i -= 3 {
		s = s[:i] + "," + s[i:]
	}
	return s
}

// sessionDuration is the wall-clock span from the first to the last event, which for a
// resumed session includes the time it sat idle.
func sessionDuration(r SessionRow) (time.Duration, bool) {
	var start, end time.Time
	if r.Start != nil {
		start, _ = time.Parse(time.RFC3339, *r.Start)
	}
	if r.End != nil {
		end, _ = time.Parse(time.RFC3339, *r.End)
	}
	if start.IsZero() || end.IsZero() || end.Before(start) {
		return 0, false
	}
	return end.Sub(start), true
}

// tokensLine describes token usage and cost, or why there is none.
func tokensLine(st statsState, source string) string {
	switch {
	case !st.loaded:
		return "tokens  counting…"
	case st.err != nil:
		return "tokens  unavailable"
	case st.stats.Tokens == nil:
		return "tokens  not recorded for " + source + " sessions"
	}
	t := st.stats.Tokens
	line := fmt.Sprintf("%s tokens", compactCount(t.Total))
	if t.HasBreakdown {
		parts := []string{"in " + compactCount(t.Input)}
		if t.CacheRead > 0 {
			parts = append(parts, "cached "+compactCount(t.CacheRead))
		}
		if t.CacheWrite > 0 {
			parts = append(parts, "cache write "+compactCount(t.CacheWrite))
		}
		parts = append(parts, "out "+compactCount(t.Output))
		line += " (" + strings.Join(parts, " · ") + ")"
	}
	switch {
	case st.stats.CostUSD != nil:
		// The app labels this the same way: what the tokens would cost at API rates, not
		// what a subscription was billed.
		line += " · ≈" + formatCost(*st.stats.CostUSD) + " at API rates"
	case len(st.stats.UnpricedModels) > 0:
		line += " · cost n/a (no price for " + strings.Join(st.stats.UnpricedModels, ", ") + ")"
	}
	return line
}

// sessionHeader returns exactly headerLines lines for the right pane.
func sessionHeader(r SessionRow, st statsState, width int) []string {
	home, _ := os.UserHomeDir()

	dir := "—"
	if r.Cwd != nil && *r.Cwd != "" {
		dir = shortenPath(*r.Cwd, home, width-6)
		// The project is the directory itself for most sessions; name the repository only
		// when it says something the path does not.
		if r.Repo != nil && *r.Repo != "" && filepath.Base(*r.Cwd) != *r.Repo {
			dir += "  ·  repo " + *r.Repo
		}
	}

	facts := []string{}
	if d, ok := sessionDuration(r); ok {
		facts = append(facts, "duration "+formatDuration(d))
	}
	facts = append(facts, plural(r.Messages, "message", "messages"))
	if r.Commands > 0 {
		facts = append(facts, plural(r.Commands, "tool call", "tool calls"))
	}
	if r.Model != nil && *r.Model != "" {
		facts = append(facts, *r.Model)
	}

	lines := []string{
		styleHeader.Render(truncate(r.DisplayTitle(), width)),
		styleDim.Render("dir     ") + truncate(dir, width-8),
		truncate(strings.Join(facts, "  ·  "), width),
		styleDim.Render(truncate(tokensLine(st, r.Source), width)),
		styleBorder.Render(strings.Repeat("─", width)),
	}
	return lines
}
