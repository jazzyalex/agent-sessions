package main

import (
	"os"

	"github.com/aymanbagabas/go-osc52/v2"
)

// copyToClipboard uses OSC 52, so the text lands in the clipboard of whatever machine the
// terminal runs on — including over SSH, where xclip/wl-copy would target the wrong host.
// Terminals that do not implement OSC 52 silently ignore it, hence the caller also shows
// the copied text in the status line.
func copyToClipboard(text string) {
	if text == "" {
		return
	}
	// stderr is the terminal here (stdout belongs to Bubble Tea's renderer).
	osc52.New(text).WriteTo(os.Stderr)
}
