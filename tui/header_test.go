package main

import (
	"strings"
	"testing"
	"time"
)

func TestFormatDuration(t *testing.T) {
	cases := map[time.Duration]string{
		0:                               "0s",
		45 * time.Second:                "45s",
		12*time.Minute + 40*time.Second: "12m",
		2 * time.Hour:                   "2h",
		2*time.Hour + 14*time.Minute:    "2h 14m",
		3*24*time.Hour + 4*time.Hour:    "3d 4h",
		5 * 24 * time.Hour:              "5d",
		-time.Minute:                    "0s",
		23*time.Hour + 59*time.Minute:   "23h 59m",
		24*time.Hour + 30*time.Minute:   "1d",
		107*24*time.Hour + 8*time.Hour:  "107d",
	}
	for d, want := range cases {
		if got := formatDuration(d); got != want {
			t.Errorf("formatDuration(%v) = %q, want %q", d, got, want)
		}
	}
}

func TestCompactCount(t *testing.T) {
	cases := map[int]string{
		0: "0", 950: "950", 1_000: "1k", 12_345: "12.3k", 99_999: "100k", 410_000: "410k",
		1_528: "1.5k", 1_240_000: "1.24M", 217_555_118: "218M", 221_738_768: "222M",
		34_047_415: "34.05M", 2_100_000_000: "2.1B", 5_545_482_155: "5.55B", 12_345_678_901: "12.3B", 123_456_789_012: "123B",
	}
	for n, want := range cases {
		if got := compactCount(n); got != want {
			t.Errorf("compactCount(%d) = %q, want %q", n, got, want)
		}
	}
}

func TestFormatCost(t *testing.T) {
	cases := map[float64]string{0: "$0", 0.004: "<$0.01", 0.42: "$0.42", 23.126: "$23.13", 155.07: "$155", 1234.5: "$1234"}
	for usd, want := range cases {
		if got := formatCost(usd); got != want {
			t.Errorf("formatCost(%v) = %q, want %q", usd, got, want)
		}
	}
}

func TestShortenPath(t *testing.T) {
	if got := shortenPath("/home/aaa/projects/x", "/home/aaa", 40); got != "~/projects/x" {
		t.Errorf("home not abbreviated: %q", got)
	}
	if got := shortenPath("/home/aaabbb/x", "/home/aaa", 40); got != "/home/aaabbb/x" {
		t.Errorf("a sibling directory sharing the home prefix must not be abbreviated: %q", got)
	}
	got := shortenPath("/very/long/path/to/some/project", "", 14)
	if !strings.HasPrefix(got, "…") || !strings.HasSuffix(got, "some/project") || len([]rune(got)) != 14 {
		t.Errorf("tail not kept: %q", got)
	}
}

func str(s string) *string   { return &s }
func flt(f float64) *float64 { return &f }

func TestTokensLine(t *testing.T) {
	if got := tokensLine(statsState{}, "codex"); !strings.Contains(got, "counting") {
		t.Errorf("not loaded: %q", got)
	}
	if got := tokensLine(statsState{loaded: true}, "opencode"); !strings.Contains(got, "not recorded for opencode") {
		t.Errorf("unsupported source: %q", got)
	}
	st := statsState{loaded: true, stats: Stats{
		Tokens:  &TokenStats{Total: 221_738_768, Input: 1_528, CacheRead: 217_555_118, CacheWrite: 3_772_178, Output: 409_944, HasBreakdown: true},
		CostUSD: flt(155.07),
	}}
	want := "222M tokens (in 1.5k · cached 218M · cache write 3.77M · out 410k) · ≈$155 at API rates"
	if got := tokensLine(st, "claude"); got != want {
		t.Errorf("got  %q\nwant %q", got, want)
	}
	st.stats.CostUSD = nil
	st.stats.UnpricedModels = []string{"new-model"}
	if got := tokensLine(st, "claude"); !strings.Contains(got, "no price for new-model") {
		t.Errorf("unpriced: %q", got)
	}
}

func TestSessionHeaderShape(t *testing.T) {
	row := SessionRow{
		ID: "x", Source: "claude", Title: str("Fix the build"), Cwd: str("/work/app"), Repo: str("app"),
		Start: str("2026-09-19T10:00:00Z"), End: str("2026-09-19T12:14:00Z"), Messages: 1337, Commands: 262, Model: str("claude-opus-5"),
	}
	lines := sessionHeader(row, statsState{}, 80)
	if len(lines) != headerLines {
		t.Fatalf("header has %d lines, want %d", len(lines), headerLines)
	}
	joined := strings.Join(lines, "\n")
	for _, want := range []string{"Fix the build", "/work/app", "duration 2h 14m", "1,337 messages", "262 tool calls", "claude-opus-5"} {
		if !strings.Contains(joined, want) {
			t.Errorf("header lacks %q:\n%s", want, joined)
		}
	}
	if strings.Contains(joined, "repo app") {
		t.Errorf("repo equal to the directory name should not be repeated:\n%s", joined)
	}
}
