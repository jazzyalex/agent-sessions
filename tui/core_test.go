package main

import (
	"os"
	"path/filepath"
	"testing"
)

func touch(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestFindCoreNear(t *testing.T) {
	prefix := t.TempDir()
	exeDir := filepath.Join(prefix, "bin")
	libexec := filepath.Join(prefix, "libexec", "agent-sessions", "agent-sessions-core")
	lib := filepath.Join(prefix, "lib", "agent-sessions", "agent-sessions-core")
	beside := filepath.Join(exeDir, "as-core")

	if _, ok := findCoreNear(exeDir); ok {
		t.Fatal("found an engine in an empty tree")
	}
	touch(t, lib)
	if got, _ := findCoreNear(exeDir); got != lib {
		t.Errorf("Debian layout: got %q, want %q", got, lib)
	}
	touch(t, libexec)
	if got, _ := findCoreNear(exeDir); got != libexec {
		t.Errorf("libexec should win over lib: got %q, want %q", got, libexec)
	}
	touch(t, beside)
	if got, _ := findCoreNear(exeDir); got != beside {
		t.Errorf("a sibling (tarball) should win: got %q, want %q", got, beside)
	}
}
