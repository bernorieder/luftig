# How luftig works

Technical notes for developers. For using luftig, see the [README](../README.md); for building it, see [Building and releasing](building.md).

## The technical choices

- **Native, and the older of Apple's two text engines.** luftig is written in Swift and AppKit, with no web view and no third-party code. The text is shown by a single standard macOS text view running on TextKit 1, because that is the engine that keeps a 10 or 20 MB file scrolling smoothly; luftig draws the code backgrounds, quote bars and code pills itself. Only the part of the text that is on screen is styled, and a keystroke restyles only its own paragraph, which is why document size barely matters.
- **A regular macOS document app underneath.** Open, save, autosave, undo, tabs, window restoration and Find are the system's own. Files are read with the lowest-level system call, so a file that is being rewritten by another program is never mapped into memory; the character encoding and the line endings a file came with are written back unchanged. Changes on disk are noticed through the system's file-change notifications, with the system's own document coordination as a second channel.
- **Its own Markdown lexer.** A small lexer (`Sources/MarkdownKit`) turns the text into styled runs, and can restart from a checkpoint near an edit instead of reading the whole document again. It is checked against the CommonMark specification and against markdown-it on a corpus of real documents.
- **Colour schemes built by rule.** Every scheme is built from a theme's palette by the same steps: the Markdown roles, the tinted bands, and a legibility step that moves a colour only as far as needed to keep text readable on every surface. Custom schemes skip that step and use the colours as picked.
- **Tested without a screen.** 117 automated scenarios with about 4,470 checks cover the file handling, the editor driven by real key events, the pixels it draws, the colour contrast of every scheme, memory and speed; another 1,900 checks cover the Markdown lexer.

## Where to read on

| Document | What it covers |
| --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | The design, the data flow from file to pixels, a map of the code, the invariants, the pitfalls found on the way, and what is not verified |
| [MANUAL.md](MANUAL.md) | Every shortcut and setting, the reload behaviour in every case, the look on recent macOS versions, the limits, and how each number was measured |
| [color-schemes.md](color-schemes.md) | The palettes and their sources, how a theme becomes Markdown roles, the contrast thresholds, and what the legibility step changed in each scheme |
| [DESIGN.md](DESIGN.md) | The original design and its performance budget |
| [spike-textkit.md](spike-textkit.md), [spike-document.md](spike-document.md) | The measurements behind choosing TextKit 1 and the document model |
