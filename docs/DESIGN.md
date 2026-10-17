# luftig — design brief

A small, very fast, native macOS Markdown editor. **One text view, no preview.** The Markdown source is
edited directly and is styled in place ("visual Markdown"): headings are larger, code blocks and quotes are
visibly marked, emphasis looks emphasised, syntax characters are dimmed but stay visible and editable.

## Product requirements (from the user)

1. Open a file (⌘O, Finder double-click / "Open With", drag onto Dock icon, File ▸ Open Recent).
2. Edit directly in the Markdown text, with nice colour coding. No preview pane / mode.
3. Headings a bit bigger; code blocks and block quotes clearly marked; lists, links, emphasis, strong,
   strikethrough, inline code, tables, rules, task lists, front matter, HTML comments styled.
4. **Auto-reload** when the file changes on disk in the background.
5. **Create a new file** (⌘N). First save of an untitled doc asks for a name (default extension `.md`).
6. **Very fast**, especially opening a file. Native Swift/AppKit. No web views, no SwiftUI text editing.

Nice-to-haves that are cheap with AppKit: light/dark mode, system tabs, ⌘F find, ⌘+/⌘− font size,
Open Recent, autosave-in-place, undo/redo, spell-check toggle, comfortable line length for reading.

## Performance budget (release build, Apple Silicon)

| What | Target |
|---|---|
| Cold launch to first window (empty/untitled) | < 150 ms feel; no work at startup beyond what is needed |
| Open a 1 MB / ~20k-line `.md` → first screen visible **and styled** | < 100 ms |
| Open a 10 MB `.md` → first screen visible and styled | < 400 ms; UI never beachballs |
| Typing latency in a normal (≤ 200 KB) document | < 8 ms per keystroke incl. restyle |
| Typing latency in a 10 MB document | no perceptible lag (< 16 ms) |
| Full-document lex throughput (MarkdownKit) | ≥ 50 MB/s in release |

Consequences for the design:
* Style **lazily around the viewport** (plus a margin), then fill the rest in small idle slices.
  Never attribute-style a whole big document synchronously on open.
* Lexing is incremental: an edit re-lexes only from the edited line until block state converges.
* Hot loops work on UTF-16 code units (`NSString` / `[UInt16]` buffers). No `Regex`, no `String.Index`
  walking, no per-character `Character` handling in the lexer.
* Style *runs* (not per-character attributes), attribute dictionaries cached per style value.

## Architecture

```
Package.swift                SwiftPM (swift-tools 6.0, Swift 5 language mode, macOS 14+)
Sources/
  MarkdownKit/               Foundation only. Markdown -> style runs. Incremental. Unit-testable. No AppKit.
  MarkdownKitChecks/         `mdkit-checks`: executable test runner (no XCTest available, see below)
  luftig/                    AppKit app (NSDocument based): documents, windows, text view, theme, menus
Scripts/build-app.sh         release build -> luftig.app bundle (Info.plist, icon, ad-hoc codesign)
Resources/                   Info.plist template, icon sources
docs/                        this file + spike reports
```

### MarkdownKit contract (what the app expects)

Style is a **composable bit set** (`MDStyle: OptionSet`, plus a 3-bit heading level field), and the lexer emits
**non-overlapping, ordered runs** `MDRun { range: NSRange (UTF-16), style: MDStyle }` that fully partition
the lexed range (adjacent equal styles coalesced). Combining styles (bold inside a heading, code inside a
quote, link text that is also italic) is therefore a property of the *run*, and the app's `Theme` maps one
`MDStyle` value → one attribute dictionary (cached by raw value).

Required style facets (names are indicative; the lexer owner may refine, but must document the final set in
`Sources/MarkdownKit/README.md`): heading level 1–6, bold, italic, strikethrough, inline code, code block body,
code fence line, code-fence language, blockquote (with depth if feasible), syntax marker (dim punctuation:
`#`, `>`, `*`, `_`, `` ` ``, `~~`, `[]()`, …), list marker, task marker, link text, link destination, image,
autolink / bare URL, table (cell / delimiter row / pipe), horizontal rule, front matter, HTML / comment,
backslash escape, footnote / reference label.

The styler is **lazy + incremental** (this is what makes open fast):
* `styleRuns(in:of:)` lexes a (line-expanded) range, continuing from the nearest cached block-state checkpoint
  and extending the checkpoint frontier as it goes. Cheap when called repeatedly with nearby ranges.
* `noteEdit(...)`/`update(...)` after an edit invalidates checkpoints at/after the edit, re-lexes from the
  edited line, and stops when the block state re-converges with the previous state (or at the frontier);
  it reports exactly which range was re-styled so the app can re-apply attributes there.
* Correctness invariant (fuzz-tested): after any sequence of edits, incremental styling of any range is
  identical to a fresh full lex of the final text.

### App shape

* `NSDocument` subclass owns the file. It gives us for free: open/new/save/Save As, autosave in place, Open
  Recent, window restoration, undo integration, document-edited dot, **file-presenter based external-change
  detection** (to be validated and supplemented where it falls short — see the document spike).
* One `NSWindowController`/`NSViewController` per document: `NSScrollView` → `EditorTextView` (NSTextView).
* `HighlightController` is the `NSTextStorageDelegate`; it asks `MarkdownStyler` for runs and applies them
  with `setAttributes` on the minimum range, inside `beginEditing/endEditing`, never touching the undo stack
  or marking the document dirty (attribute-only changes).
* `Theme` = fonts (body font, monospaced font, heading sizes) and dynamic colours (light/dark), derived from
  one base font size; user font-size changes rebuild the attribute cache and restyle visible runs.

## Toolchain constraints (important — read before running anything)

* Machine: macOS 27, Apple Silicon, **Swift 6.4 with only the Command Line Tools — there is no Xcode and no
  `xcodebuild`**. Everything goes through SwiftPM (`swift build`, `swift run`). The `.app` bundle is
  assembled by `Scripts/build-app.sh` (plain shell) and ad-hoc signed with `codesign -s -`.
* `swift build` uses the new swift-build engine: products live in `.build/out/Products/{Debug,Release}`.
  Use `swift build --show-bin-path` instead of hard-coding it.
* **XCTest and swift-testing do not work here** (no XCTest.framework; the Testing macro plugin is missing).
  Tests are plain executables with a tiny assertion harness (`mdkit-checks`, `luftig --selftest …`). Exit
  status ≠ 0 on failure, readable output on stdout.
* SwiftPM takes a lock on `.build`. When several agents work at once, **each agent builds with its own
  `--scratch-path` in the scratchpad** (e.g. `swift build --scratch-path $SCRATCH/build-<name>`), and works
  in its own copy/dir unless told it owns a directory of the main project.
* GUI processes started from a shell **must not steal focus or flash windows on the user's screen**: in
  test/self-test modes use `NSApp.setActivationPolicy(.prohibited)` (or `.accessory`) and `orderBack`/offscreen
  windows. Window snapshots without Screen-Recording permission: `view.bitmapImageRepForCachingDisplay(in:)`
  + `cacheDisplay(in:to:)` → PNG (verified to work from the shell; Retina 2×). View PNGs with the Read tool.
* Language mode is Swift 5 (not 6) to avoid strict-concurrency friction with AppKit/NSDocument overrides.
* Never put build output or large files inside OneDrive; the project lives in `~/Developer/luftig`.
* Deployment target macOS 14. Prefer public API only.
