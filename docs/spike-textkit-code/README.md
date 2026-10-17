# spike-textkit-code

Companion code for `../spike-textkit.md`.

## Drop-in files (this directory)

AppKit only, Swift 5 language mode, macOS 14. Compile-checked inside the harness; exercised end-to-end at 20 MB by `spike dropin`.

| file | what |
|---|---|
| `Decorations.swift` | `.scribeBlock` / `.scribeInline` attribute keys, `BlockKind`, `DecorationMetrics`, `DecorationPalette`, band path/fill helpers |
| `ScribeLayoutManager.swift` | TextKit 1: code bands, quote bars, rules, inline pills (`drawDecorations(in:origin:container:)`) |
| `ScribeEditorTextView.swift` | TextKit 1: `drawBackground(in:)` hook that calls the layout manager (AppKit clips the layout manager's own `drawBackground` to the text container) |
| `ScribeLayoutFragment.swift` | TextKit 2 alternative: `NSTextLayoutFragment` subclass + `NSTextStorage.invalidateNeighbourParagraphs(of:)` |
| `ScribeEditorFactory.swift` | the recommended stack (TK1, non-contiguous layout) and the exact plain-text configuration |
| `LazyStyler.swift` | viewport styling, styled-range set, edit handling from `didProcessEditing`, IME guard, `scroll(toCharacter:)` |
| `ReadableColumnController.swift` | centred readable column via `textContainerInset` |

`Decorations.swift` is self-contained. `LazyStyler` talks to the lexer through two closures (`runs`, `restyleRange`).

## `reference/`

Spike-only stand-ins, useful as reference for MarkdownKit/Theme: `Theme.swift` (attribute dictionaries cached per style value, uniform line
heights, palette; needs `dynamicColor` from `Decorations.swift`), `MiniLexer.swift` (UTF-16 line lexer + fence index), `Styler.swift`,
`Corpus.swift` (deterministic Markdown corpus generator, 20 KB .. 20 MB, long-line and pathological variants).

## `spike-harness/`

The complete measuring package. Build and run:

```sh
cd spike-harness
swift build -c release --scratch-path "$SCRATCH/build-textkit"
export SPIKE_SCRATCH="$SCRATCH"            # corpora are cached in $SPIKE_SCRATCH/corpora
"$SCRATCH/build-textkit/out/Products/Release/spike" open --corpus 1m,20m --engine tk1n,tk2 --runs 7
```

Commands: `open attrs typing scroll truth draw invalidate config sanity dropin probe settle marked clip fileload`
(common flags: `--engine tk1c|tk1n|tk2|all|a,b`, `--corpus 100k|1m|5m|10m|20m|1m-long|20m-long|2m-oneline|10m-oneline`, `--runs N`).
GUI work is headless (`NSApp.setActivationPolicy(.prohibited)`, offscreen window, `cacheDisplay`); nothing takes focus. `draw` and `dropin`
write PNGs to `docs/spike-textkit-code/snapshots` (path is a constant in `ExpDraw.swift`).

## `results/`, `snapshots/`

Raw experiment output (Markdown tables) and the PNGs referenced by the report. Selection colour in the snapshots is the *inactive* grey
(the offscreen window is never key).
