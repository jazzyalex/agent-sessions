package main

import (
	"strings"
	"testing"
	"time"
)

func ready(total int) SessionRow {
	return SessionRow{UsageState: "ready", Usage: &RowUsage{TokenStats: TokenStats{Total: total}}}
}

func TestTokensCell(t *testing.T) {
	cases := []struct {
		row  SessionRow
		want string
	}{
		{ready(266_000_000), "266M"},
		{ready(1_240_000), "1.24M"},
		{ready(5_545_482_155), "5.55B"},
		{ready(950), "950"},
		{SessionRow{UsageState: "pending"}, "…"},
		{SessionRow{UsageState: "none"}, "—"},
		{SessionRow{UsageState: "unsupported"}, "—"},
		{SessionRow{}, "—"},
	}
	for _, c := range cases {
		if got := tokensCell(c.row); got != c.want {
			t.Errorf("tokensCell(%s) = %q, want %q", c.row.UsageState, got, c.want)
		}
	}
	// every ready cell must fit its column
	for _, n := range []int{0, 999, 99_999, 12_345_678, 999_999_999, 9_999_999_999, 123_456_789_012} {
		if w := len([]rune(tokensCell(ready(n)))); w > tokensWidth {
			t.Errorf("tokensCell(%d) is %d wide, column is %d", n, w, tokensWidth)
		}
	}
}

func TestLastCellFollowsSort(t *testing.T) {
	now := time.Date(2026, 9, 21, 12, 0, 0, 0, time.UTC)
	end := "2026-09-21T10:00:00Z"
	secs := 2*3600 + 14*60
	r := SessionRow{End: &end, DurationSeconds: &secs}
	if got := lastCell(r, "date", now); got != "2h" {
		t.Errorf("date sort shows age, got %q", got)
	}
	if got := lastCell(r, "tokens", now); got != "2h" {
		t.Errorf("tokens sort still shows age, got %q", got)
	}
	if got := lastCell(r, "duration", now); got != "2h 14m" {
		t.Errorf("duration sort shows duration, got %q", got)
	}
	if got := lastCell(SessionRow{}, "duration", now); got != "—" {
		t.Errorf("no duration, got %q", got)
	}
}

func TestColumnHeaderMarksTheSortedColumn(t *testing.T) {
	for mode, marked := range map[string]string{"date": "age▾", "duration": "dur▾", "tokens": "tokens▾"} {
		h := columnHeader(60, mode, true)
		if !strings.Contains(h, marked) {
			t.Errorf("sort %s: %q lacks %q", mode, h, marked)
		}
		if strings.Count(h, "▾") != 1 {
			t.Errorf("sort %s: exactly one column should be marked: %q", mode, h)
		}
	}
	if strings.Contains(columnHeader(40, "date", false), "tokens") {
		t.Error("narrow layout must drop the tokens column")
	}
}

func TestRowStatsPrefersTheRow(t *testing.T) {
	cost := 12.5
	r := ready(1_000)
	r.Usage.CostUSD = &cost
	live := statsState{loaded: true, stats: Stats{Tokens: &TokenStats{Total: 7}}}
	got := rowStats(r, live)
	if !got.loaded || got.stats.Tokens.Total != 1_000 || *got.stats.CostUSD != 12.5 {
		t.Errorf("a ready row must win over a live call: %+v", got)
	}
	if got := rowStats(SessionRow{UsageState: "unsupported"}, statsState{}); !got.loaded || got.stats.Tokens != nil {
		t.Errorf("unsupported: known, no tokens: %+v", got)
	}
	if got := rowStats(SessionRow{UsageState: "pending"}, statsState{}); got.loaded {
		t.Errorf("pending without a live result stays loading: %+v", got)
	}
}

func TestSortModesCycleStartsAtDate(t *testing.T) {
	if sortModes[0] != "date" || len(sortModes) != 3 {
		t.Errorf("default sort must be date and there are three modes: %v", sortModes)
	}
	seen := map[string]bool{}
	for _, m := range sortModes {
		if !strings.Contains(sortLabel(m), ",") || seen[sortLabel(m)] {
			t.Errorf("label for %s: %q", m, sortLabel(m))
		}
		seen[sortLabel(m)] = true
	}
}

// Nothing in the last column may exceed its width, or the row wraps and breaks the list.
func TestLastCellFitsItsColumn(t *testing.T) {
	now := time.Date(2026, 9, 21, 12, 0, 0, 0, time.UTC)
	for _, secs := range []int{0, 59, 3599, 86399, 86400 * 99, 86400*99 + 3600*23, 86400 * 107, 86400 * 1200} {
		s := secs
		r := SessionRow{DurationSeconds: &s}
		if got := lastCell(r, "duration", now); len([]rune(got)) > lastWidth {
			t.Errorf("%ds renders %q (%d wide) in a %d-wide column", secs, got, len([]rune(got)), lastWidth)
		}
	}
	for mode := range map[string]bool{"date": true, "duration": true, "tokens": true} {
		if h := columnHeader(60, mode, true); len([]rune(h)) > 60 {
			t.Errorf("column header for %s is %d wide in a 60-wide list", mode, len([]rune(h)))
		}
	}
}
