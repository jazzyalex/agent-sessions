package main

import (
	"fmt"
	"strings"
	"time"
)

// Column widths in the session list. Both figures are right-aligned so digits line up.
const (
	tokensWidth = 7 // "tokens▾" is the widest cell; values top out at "20.72M"
	lastWidth   = 8 // "2d 9h", and "dur▾" or "age▾" in the header
	// Below this list width the tokens column is dropped so titles keep room.
	minWidthForTokens = 46
)

// sortModes are the engine's --sort values, in the order `S` cycles through them.
var sortModes = []string{"date", "duration", "tokens"}

// sortLabel names a sort in the header line.
func sortLabel(mode string) string {
	switch mode {
	case "duration":
		return "duration, longest first"
	case "tokens":
		return "tokens, most first"
	default:
		return "date, newest first"
	}
}

// tokensCell is the tokens column of one row: the total when known, "…" while it is still
// being counted, "—" when this agent records no usage.
func tokensCell(r SessionRow) string {
	switch {
	case r.UsageState == "ready" && r.Usage != nil:
		return compactCount(r.Usage.Total)
	case r.UsageState == "pending":
		return "…"
	default:
		return "—"
	}
}

// lastCell is the right-most column: how long ago the session was active, or, when the
// list is sorted by duration, the duration the order is based on.
func lastCell(r SessionRow, sortMode string, now time.Time) string {
	if sortMode == "duration" {
		if r.DurationSeconds == nil {
			return "—"
		}
		return formatDuration(time.Duration(*r.DurationSeconds) * time.Second)
	}
	return relativeTime(r.ActivityTime(), now)
}

// columnHeader labels the list columns and marks the one that drives the order.
func columnHeader(listW int, sortMode string, showTokens bool) string {
	tokens, last := "tokens", "age"
	switch sortMode {
	case "tokens":
		tokens += "▾"
	case "duration":
		last = "dur▾"
	default:
		last += "▾"
	}
	titleW := listW - 8 - 1 - lastWidth - 1
	if showTokens {
		titleW -= tokensWidth + 1
	}
	if titleW < 1 {
		titleW = 1
	}
	line := fmt.Sprintf("%-8s %-*s", "source", titleW, "title")
	if showTokens {
		line += fmt.Sprintf(" %*s", tokensWidth, tokens)
	}
	line += fmt.Sprintf(" %*s", lastWidth, last)
	return strings.TrimRight(line, " ")
}

// rowStats is what the header shows for a session: the figures the list row already
// carries, or, only while the row is still pending, whatever a live `stats` call returned.
func rowStats(r SessionRow, live statsState) statsState {
	switch r.UsageState {
	case "ready":
		if r.Usage != nil {
			return statsState{loaded: true, stats: Stats{
				Tokens:         &r.Usage.TokenStats,
				CostUSD:        r.Usage.CostUSD,
				UnpricedModels: r.Usage.UnpricedModels,
			}}
		}
	case "none", "unsupported":
		return statsState{loaded: true}
	}
	return live
}
