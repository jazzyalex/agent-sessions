package main

import (
	"reflect"
	"testing"
)

func TestSplitHarness(t *testing.T) {
	cases := []struct {
		in     string
		prompt string
		labels []string
	}{
		{"<turn_aborted>\nThe user interrupted.\n</turn_aborted>", "", []string{"turn aborted"}},
		{"<local-command-caveat>Caveat: do not respond.</local-command-caveat>\nfix the build", "fix the build", []string{"local command caveat"}},
		{"<environment_context>\n<cwd>/x</cwd>\n</environment_context>\n\nпроанализируй проект", "проанализируй проект", []string{"environment context"}},
		{"plain question <not-a-harness-tag> stays", "plain question <not-a-harness-tag> stays", nil},
		{"<command-name>/model</command-name><command-args>opus</command-args>", "", []string{"command name", "command args"}},
	}
	for _, c := range cases {
		prompt, labels := splitHarness(c.in)
		if prompt != c.prompt || !reflect.DeepEqual(labels, c.labels) {
			t.Errorf("splitHarness(%q) = %q, %v; want %q, %v", c.in, prompt, labels, c.prompt, c.labels)
		}
	}
}
