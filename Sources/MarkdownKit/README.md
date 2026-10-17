# MarkdownKit

A fast, incremental Markdown **lexer for syntax highlighting**. It turns Markdown text into *style runs*
(UTF-16 ranges with a composable style) for a syntax-highlighting `NSTextView`. It is not a renderer: it favours
robust, predictable-while-typing results over CommonMark corner cases. Foundation only (no AppKit), Swift 5
language mode, macOS 14+, public API only.

```
Sources/MarkdownKit/        this library (internal: Lexer*.swift, BlockState.swift; public: MDStyle.swift, MarkdownStyler.swift)
Sources/MarkdownKitChecks/  `mdkit-checks`, the test / fuzz / benchmark runner (XCTest is not available on this machine)
```

## Public API

```swift
public struct MDStyle: OptionSet, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: UInt32
    // facets: see the table below
    public var facets: MDStyle { get }          // without heading level / quote depth
    public var headingLevel: Int { get set }    // 0 = none, 1...6 (clamped)
    public var quoteDepth: Int { get set }      // 0 = none, 1...3 (saturating); setting > 0 also sets .blockquote
    public static func heading(_ level: Int) -> MDStyle
    public static func quote(depth: Int) -> MDStyle
}

public struct MDRun: Equatable, Sendable { public var range: NSRange; public var style: MDStyle }   // UTF-16 units

public struct MDResult: Sendable {
    public var range: NSRange        // the line-aligned range these runs cover
    public var runs: [MDRun]         // ordered, non-overlapping, non-empty, fully partition `range`, equal neighbours coalesced
    public var staleFrom: Int?       // only set by the bounded update(...maxRegion:), see below
}

public final class MarkdownStyler {                 // not thread safe: one thread / queue at a time (it may hop between calls)
    public init()
    public func reset()                             // text was replaced wholesale: drop all cached state
    public func styleRuns(in range: NSRange, of text: NSString) -> MDResult
    public func update(afterEdit editedRange: NSRange, changeInLength delta: Int, of text: NSString) -> MDResult
    public func update(afterEdit editedRange: NSRange, changeInLength delta: Int, of text: NSString, maxRegion: Int?) -> MDResult
    public func lexAll(_ text: NSString) -> [MDRun]  // non-incremental reference implementation / oracle

    // diagnostics / test hooks (not needed by an app)
    public var debugCheckpointCount: Int { get }
    public var debugFrontier: Int { get }
    public func debugDumpCheckpoints() -> [String]
    public func debugConfigure(strideUnits:maxParagraphLines:maxParagraphUnits:frontMatterWindow:chunk:slideMin:slideLow:poison:)
}
public enum MarkdownKitVersion { public static let string: String }
```

### Contract

* **`styleRuns(in:of:)`** lexes a line-aligned superset of `range`. Its result starts at the beginning of the block
  (paragraph, table, ...) that contains `range.location` - not necessarily at `range.location` - and ends at a block
  boundary at or after `range.upperBound`. It resumes from the nearest cached block-state checkpoint and extends
  the lexed *frontier* as needed, so repeated calls with nearby, overlapping or out-of-order ranges are cheap. A
  range beyond the frontier first advances the frontier with a block-state-only pass (no runs, ~1 GB/s).
  Out-of-range / empty / negative ranges are clamped; an empty text gives an empty result.
* **`update(afterEdit:changeInLength:of:)`**: call it after *every* edit, with the POST-edit text and the values of
  `NSTextStorage.editedRange` / `changeInLength` **as delivered to `textStorage(_:didProcessEditing:range:changeInLength:)`**
  (they read `{NSNotFound, 0}` after the edit cycle has finished). It invalidates checkpoints at/after the edit, re-lexes
  from the block containing the edit, and stops when the block state re-converges with the previously known state or
  reaches the known frontier. It returns exactly the re-lexed line-aligned region and its runs: **re-apply attributes
  only there; everything outside is unchanged** (this is fuzz-tested against a model of the app).
  NSTextStorage's coalesced edits (one `editedRange` covering several changes in a batch) are fine.
* **`update(..., maxRegion:)`** is the bounded variant for the typing path. It always covers the edited lines but gives
  up after about `maxRegion` units. When it stops before re-converging (typically: typing an opening code fence near the
  top of a huge document without any fence below) `result.staleFrom` is the offset from which previously applied styling
  can no longer be trusted. The styler has forgotten everything beyond it, so call `styleRuns` for those ranges when
  they scroll into view / during idle time. (Unbounded, that case costs ~1 ms per MB of document in MarkdownKit - the
  expensive part for an app is re-applying attributes to that many characters.)
* **Self-healing**: if `delta` does not match the length the styler last saw (missed or wrongly described edit) or the
  text length changed without `update`, the cache is reset and the edited region is restyled (for `update`,
  `staleFrom` marks the rest). Never a crash, never wrong output - just slower.
* **Invariant (fuzz-tested)**: after any sequence of edits, styling any range, in any order of calls interleaved with
  edits, is identical to the corresponding slice of a fresh `lexAll` of the final text.
* **Threading**: use from one thread/queue at a time. All value types are `Sendable`. Typical use: call everything on the main
  thread - a keystroke costs ~10 us, a first screen ~0.1 ms. For a 10 MB cold open do the frontier skim on a background
  queue or accept ~5-10 ms.
* **Text access**: the text is pulled in bulk with `getCharacters(_:range:)` into reusable `UInt16` buffers (a 16K-unit
  window costs ~4 us on `NSTextStorage.string`, an `NSBigMutableString`); there are no per-character ObjC calls.

### Wiring it into an NSTextStorage (sketch)

```swift
func textStorage(_ ts: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
    guard mask.contains(.editedCharacters) else { return }
    let r = styler.update(afterEdit: range, changeInLength: delta, of: ts.string as NSString)
    apply(r.runs, to: ts)                        // setAttributes per run, inside beginEditing/endEditing, no undo registration
    if let s = r.staleFrom { scheduleRestyle(from: s) }
}
// on open:  styler.reset();  apply(styler.styleRuns(in: visibleRangePlusMargin, of: string).runs)  then idle-time slices of ~8 KB
```

## Style facets

A run's style is the set of facets that apply to it. Facets *combine*: a bold word inside a heading inside a quote is
`h2 + q1 + bold`. Syntax punctuation carries `marker` **in addition to** the facets of the construct it belongs to
(the `**` of a bold span is `[bold, marker]`, a heading's `## ` is `h2 + marker`), so a theme decides whether dimmed
punctuation also takes the construct's font traits. Line breaks take the style of the line they end (so a heading's
line height is consistent). The container prefix of a continuation line (list indentation) is unstyled; quote markers
are `marker + q<level>`.

| `MDStyle` member | bit | what it marks | example (run notation `[style:text]`) |
|---|---|---|---|
| `.bold` | 0 | `**x**`, `__x__` content and its markers | `**a**` -> `[bold·marker:**][bold:a][bold·marker:**]` |
| `.italic` | 1 | `*x*`, `_x_` | `***a***` -> `[italic·marker:*][bold·italic·marker:**][bold·italic:a]...` |
| `.strikethrough` | 2 | `~~x~~` (two tildes only) | `~~x~~` -> `[strike·marker:~~][strike:x][strike·marker:~~]` |
| `.inlineCode` | 3 | code span; the backticks are markers | ``` `a` ``` -> `[code·marker:\`][code:a][code·marker:\`]` |
| `.codeBlock` | 4 | body lines of fenced and indented code (incl. line break) | fence, `x`, fence -> `[fence:\`\`\`⏎][codeblock:x⏎][fence:\`\`\`⏎]` |
| `.codeFence` | 5 | the fence lines, including indentation and info string | see above |
| `.codeLanguage` | 6 | first word of the info string (together with `.codeFence`) | an opening fence with `swift` -> `[fence:\`\`\`][fence·lang:swift][fence:⏎]` |
| `.blockquote` | 7 | inside a quote; `quoteDepth` 1...3 says how deep (saturates) | `> > x` -> `[q1·marker:> ][q2·marker:> ][q2:x]` |
| `.marker` | 8 | dim syntax punctuation: `# `, `> `, `*`, `_`, backticks, `~~`, `[` `]` `(` `)`, setext underlines, front matter delimiters | `# H` -> `[h1·marker:# ][h1:H]` |
| `.listMarker` | 9 | `-` `*` `+` `1.` `1)` and the space after it | `- a` -> `[list:- ][:a]` |
| `.taskMarker` | 10 | `[ ]` / `[x]` after a list marker | `- [ ] t` -> `[list:- ][task:[ ]][: t]` |
| `.taskChecked` | 11 | set *in addition* to `.taskMarker` for `[x]` / `[X]` | `- [x] d` -> `[list:- ][task·checked:[x]]...` |
| `.linkText` | 12 | `[text]` of inline and reference links (brackets are markers) | `[a](b)` -> `[marker·link:[][link:a][marker·link:]]...` |
| `.linkDestination` | 13 | `(url "title")` of links, `<url>`, `url "title"` of definitions; parens are markers | `[a](b)` -> `...[marker·dest:(][dest:b][marker·dest:)]` |
| `.image` | 14 | the whole `![alt](src)`; the source also has `.linkDestination` | `![a](b)` -> `[marker·image:![][image:a][marker·image:]][marker·dest·image:(]...` |
| `.autolink` | 15 | `<https://x>`, `<a@b.c>`, bare `http(s)://...` and `www....` URLs | `http://x.org` -> `[auto:http://x.org]` |
| `.table` | 16 | every table row (cell content) | |
| `.tableHeader` | 17 | the header row, in addition to `.table` | |
| `.tableDelimiter` | 18 | pipes and the whole delimiter row, in addition to `.table` | header `\| a \|` -> `[table·thead·tdelim:\|][table·thead: a ]...` |
| `.horizontalRule` | 19 | `***`, `---`, `___`, `- - -` lines | `***` -> `[hr:***⏎]` |
| `.frontMatter` | 20 | YAML front matter lines (delimiters also `.marker`) | `---\na: b\n---` -> `[marker·fm:---⏎][fm:a: b⏎][marker·fm:---⏎]` |
| `.html` | 21 | HTML blocks, comments, inline tags / comments | `<b>x</b>` -> `[html:<b>][:x][html:</b>]` |
| `.escape` | 22 | backslash escapes (`\*`) and entities (`&amp;`) | `\*` -> `[esc:\*]` |
| `.footnote` | 23 | `[^1]` references and `[^1]:` definitions (brackets are markers) | `a[^1]` -> `[:a][marker·fn:[^][fn:1][marker·fn:]]` |
| `.referenceLabel` | 24 | `ref` of `[text][ref]` and of `[ref]: url` | `[a][b]` -> `...[marker·ref:[][ref:b][marker·ref:]]` |
| `headingLevel` | 25-27 | 1...6 on the whole heading line: markers, text, closing `#`s, setext text lines *and* underline | `Sub\n---` -> `[h2:Sub⏎][h2·marker:---][h2:⏎]` |
| `quoteDepth` | 28-29 | 1...3 | |

`MDStyle.description` prints the compact names used above (`h1·bold·marker`, `q2·code`); `mdkit-checks --show '<text>'`
prints the run notation for any text.

## Semantics and deliberate decisions

*Predictable while typing beats spec corner cases.* Deviations from CommonMark / GFM:

* **Unclosed inline delimiters degrade to plain text** and never restyle the rest of the document. Inline constructs
  never cross a paragraph boundary but may span soft line breaks inside one paragraph (emphasis, code spans, link text).
* **Unclosed fences run to the end of the document** (CommonMark), as does an unclosed HTML comment / `<script>` / CDATA
  block. Those are the only constructs that do.
* **Setext underlines need at least 2 characters** (`a` / `-` is plain text, `a` / `--` is an H2): a lone `-` on the next line
  is far more often a list item being typed. An empty list item (`-`) cannot interrupt a paragraph, and an ordered item
  interrupts only when it starts with 1 (CommonMark).
* **Indented code**: a line indented >= 4 columns *beyond the content column of its innermost container* (tabs: next multiple of 4)
  when no paragraph is open - at top level, inside block quotes and inside list items (`- a` + blank + 6 spaces is code, `- a` +
  4 spaces is a continuation paragraph). Blank lines between indented code lines belong to the block (CommonMark 4.4): they are
  painted plain when seen and re-painted as code when another code line follows (a "pending blank lines" state like a pending
  paragraph, capped at 256 blank lines: a longer run ends the block). The text after a task checkbox (`- [ ]      x`) or a
  footnote label is always paragraph text, however far it is indented.
* **Empty list items**: a list item can begin with at most one blank line, so `-` / `1.` followed by a blank line ends the item
  (`-` + blank + 4 spaces + `code` is a code block); `-` + 4 spaces + `code` (no blank line) is the item's content.
* **Tables**: a delimiter row (must contain a pipe, `:--` alignment allowed) whose cell count equals that of the preceding
  line turns that line into the header, even in the middle of a paragraph (as GitHub does). Rows continue until a blank
  line or another block start - a table is not a paragraph (GFM), so *every* block start ends it, also indented code, an HTML
  block of type 7, `2.` and an empty `-` (a link reference definition cannot). Lines without pipes are rows too (GFM); surplus
  cells beyond the header's count are styled as table text although a renderer drops them. Cells split on unescaped pipes, also
  inside code spans.
* **Front matter**: line 0 is `---` and a line that is exactly `---` or `...` (<= 3 trailing blanks) starts within the first
  16,384 units; otherwise line 0 is a horizontal rule. Only at the very start of the document.
* **Links**: `[text](dest "title")`, `[text][ref]` and `[text][]` are styled; a bare `[text]` (shortcut reference) is *not*
  (definitions are not resolved, and brackets are common in prose). `[a][b]` directly after a word character (`arr[i][j]`) is
  not a reference link. Link text cannot contain links; images can contain links. Definitions `[ref]: url "title"` are single
  line only and cannot interrupt a paragraph. Footnote definitions `[^1]:` open an indented container (continuation lines
  indented 4 spaces belong to it).
* **Bare URLs**: `http://` / `https://` may follow any character that is not a letter (`"http://x.org"`, `k=http://x.org`,
  `,http://x.org`, as in cmark-gfm); `www.` needs a boundary before it (start, blank, `*`, `_`, `~`, `(`; GFM). Neither is
  recognised while a `[` / `![` opener is still waiting for its `]` (cmark-gfm: the text may be link text). Trailing
  `?!.,:;*_~'"` are not part of the URL, nor is a trailing `&letters;` that looks like an entity reference (GFM), nor an unbalanced
  `)` / `]` - which also ends the URL when more characters follow (deviation). Bare e-mail addresses and `ftp://` are not linked;
  `<a@b.co>` is an autolink only when it is a valid e-mail address, `<scheme:...>` per CommonMark.
* **Inline HTML**: any well-formed single-line open / close tag, comment (`<!-->` and `<!--->` included), processing instruction, declaration or CDATA section
  (a tag, comment or attribute spanning lines is not recognised). HTML blocks: all seven CommonMark start conditions; type 7
  (a lone tag such as `<br>`) cannot interrupt a paragraph - also not on a lazy continuation line (`- item` / `<br>` / `text`
  is one paragraph; cmark lets the tag start a block there, commonmark.js / markdown-it and the spec text do not). Closing
  `</pre>` / `</script>` lines start a type 7 block like any other closing tag, as in every reference implementation.
* **Character references** `&amp;` `&#35;` `&#x1F;`: numeric ones with at most 7 decimal / 6 hexadecimal digits; named ones
  are not checked against the entity table (`&bogus;` is styled as an entity).
* **Emphasis**: left/right-flanking rules, intraword `_` rule, rule of three. "Unicode whitespace" (category Zs, plus tab / LF / FF /
  CR) and "Unicode punctuation" (categories P and S: the punctuation and symbols of every script, currency, emoji) are looked up in
  the runtime's Unicode data (`Unicode.Scalar.Properties.generalCategory`), cached per BMP scalar on first use; surrogate pairs are
  decoded. (`mdkit-checks --unicode-class` compares the lexer's class of every scalar of planes 0-2 with its category.)
  `~~` only (a single `~` is plain), only runs of exactly two tildes.
* **Containers**: block quotes (nesting depth saturates at 3 in the style, the stack holds 16 containers, deeper
  markers are plain text), bullet / ordered lists (content column <= 127), task items, footnote definitions; fences, tables,
  HTML blocks, headings and everything else work inside them. Lazy continuation lines keep their container's style.
* **Line breaks** are `\n`, `\r\n` and lone `\r`; a `\r\n` pair is never split. Tabs advance to the next multiple of 4 columns
  for indentation. Text may contain NUL, lone surrogates and any other UTF-16; run boundaries never split a surrogate pair of
  well-formed text. A final line without a line break is fine.
* **Work caps (degrade to plain, never quadratic)**: a paragraph is lexed in chunks of at most 256 lines; a chunk larger than
  65,536 units gets no inline styling (so a 5 MB single line is one plain run, in ~4 ms); at most 1,024 emphasis delimiter runs
  and 256 open brackets per chunk; link destinations <= 1,024 units, inline HTML tags <= 600, autolinks <= 2,048; code-span
  openers of 64+ backticks are plain. Chunking is a deterministic function of the text, so incremental == full.

## The incremental algorithm (one paragraph)

Block structure is lexed line by line (container stack of quotes / list items, plus one leaf state: fence, HTML block, front
matter, table, or "paragraph open") and inline syntax is lexed per paragraph chunk once the chunk is complete. Styles are painted
(OR-ed) into a `UInt32`-per-code-unit buffer parallel to a sliding window of the text and turned into runs at the end of a
session, so nesting and overlap need no special handling. The compact **block state** (24 bytes; a checkpoint is 40 bytes with its offset and `validAfter`) at a line start with nothing
pending is a *checkpoint*; one is stored every ~2 KB (or at the next paragraph start) in a sorted array, plus a frontier
checkpoint at the end of everything lexed so far. A checkpoint taken at a paragraph's first line that itself *closed* the
previous paragraph (dense lists, consecutive quote items) is "weak": it is a valid restart point only for edits after that line
(`validAfter`). `update` finds the last valid checkpoint before the edit (so re-lexing starts at the beginning of the paragraph /
setext / table-header block containing the edit - possibly lines before the edited one), re-lexes forward, and at every
later checkpoint position compares the freshly computed block state with the old stored one (offsets shifted by `changeInLength`);
when they are equal and the text after is unchanged everything after is identical, so it splices the new checkpoints in, shifts the
old tail and stops. If it reaches the old frontier first, the frontier simply moves. Front matter is the only construct with
lookahead (checked against the window `frontMatterWindow` and re-lexed from offset 0 when an edit can change it); every other
construct is decided from the lines before it plus the current paragraph, which is why a pending paragraph can be flushed and
restarted deterministically.

## Tests (`mdkit-checks`)

```
swift build -c release --scratch-path $SCRATCH/build-lexer --product mdkit-checks
$(swift build -c release --scratch-path $SCRATCH/build-lexer --show-bin-path)/mdkit-checks            # all fast checks, exit status 1 on failure
... --fuzz <edits> <seed>      # differential fuzzing, reproducible, minimal repro printed on mismatch
... --bench                    # benchmarks;   --sweep  # checkpoint-stride experiment
... --show '<text with \n escapes>'   # print the run notation;   --showfile <path>
... --conformance              # CommonMark / GFM conformance table + the documented deviations
... --corpus <edits per file> <seed> [oddities] [review=N] [oracle] [real] [inline]   # every *.md under /opt/homebrew, /Library/Developer, /Applications
... --stress [bytes] [name]    # pathological inputs (1 MB each): MB/s, keystroke, cold end-of-document first screen
... --ref-fuzz / --oracle-fuzz / --block-fuzz <n> <seed>   # inline / block differentials against a spec-literal reference and cmark-gfm
... --mdit-export / --mdit-compare   # differential against markdown-it-py (needs Python with markdown-it-py; see Scripts/mdit_oracle.py)
... --unicode-class            # the flanking class of every scalar of planes 0-2 vs its general category
```

Long runs are meant to be started under a wall-clock limit (`perl -e 'alarm shift; exec @ARGV' 120 mdkit-checks ...`); no check
creates anything but regular files, and the corpus runner only reads.

* **Expectation tables** (283 cases, each also run through a cold `styleRuns`): one human-readable line per case, e.g.
  `ex("## T ##\n", "[h2·marker:## ][h2:T ][h2·marker:##][h2:⏎]")`, for every construct and the edge cases above.
* **Independent conformance suite** (`SpecInline`, `SpecBlocks`, `SpecReal`, `SpecHarness`; 731 cases): written from CommonMark 0.31 /
  GFM and common real-world idioms (the expectations state what the specification says, not what the lexer printed), every case marked `spec` (the spec mandates it) or `judge`
  (highlighter judgement: what a writer wants to see). A case passes, is a documented *deviation* (`accept:` states the lexer's
  deliberate output, the expectation keeps the ideal) or fails; `--conformance` prints the table. Current result: spec 591 cases,
  579 pass, 12 deviations, 0 fail; judgement 140 cases, 137 pass, 3 deviations, 0 fail. The 15 deviations: link destination and
  title on different lines; shortcut references `[foo]` (definitions are not resolved); definitions with the destination on the
  next line; an unbalanced `)` ending a `www.` URL; the domain of a bare URL is not validated (GFM rejects `www.x_y.com`,
  `http://my_host/`); `ftp://` and bare e-mail addresses not linked; tags / comments spanning lines; unknown entity names
  styled; single-tilde strikethrough; one-character setext underline; TOML (`+++`) front matter.
* **Structural invariants** on *every* result of every test and fuzz step: in bounds, line-aligned range, ordered, non-empty,
  gap-free, coalesced, no split surrogate pairs, requested range covered.
* **Differential fuzzing** (incremental == full): random Markdown from a grammar of ~180 block / inline fragments (stray delimiters,
  unclosed fences, nested quotes / lists, empty list items, indented code with blank lines, tables, front matter, CR / LF / CRLF,
  tabs, emoji, ZWJ sequences, NUL ...), then random inserts, deletes and replacements at line starts / ends / anywhere, followed
  by `update` and 0-5 `styleRuns` at random ranges in random order, occasional `reset`, 25% of updates through the bounded
  variant. After every step the result is compared with a fresh `lexAll` of the current text **and** a model of the app
  (attributes applied only inside returned regions) must agree with the fresh lex everywhere (catches "region too small" bugs).
  Each document randomises the internal limits (checkpoint stride 1...2048, paragraph caps 2...256 lines / 12...65,536 units,
  front matter window 24...16,384, text window chunk 1...200 units, sliding window, poison-filled unloaded window) while the
  oracle runs with the production window settings.
* **Differential against other implementations** (what the spec suite and the incremental fuzzer cannot tell): a naive
  spec-literal emphasis / code span reference implementation (`--ref-fuzz`, 200,000 paragraphs, 0 mismatches), cmark-gfm through
  Foundation's `AttributedString(markdown:)` (`--oracle-fuzz`, `--oracle-fuzz2` for HTML / entities / URLs with links compared,
  `--block-fuzz`, `--corpus ... oracle [links]`), and markdown-it-py (`--mdit-*`: letters / digits with em, strong, code, strike,
  image, code block, quote, table and heading-level flags; generators: random paragraphs, block soups, list / indentation soups, fence and
  HTML soups, a Unicode-class soup, ...). About 812,000 random paragraphs / small documents (several generators,
  among them real documents with random line-level mutations) and the 1,300 real documents without footnote definitions were
  compared with markdown-it-py: in 99.97 % the lexer's token stream equals markdown-it-py's or (where markdown-it-py has a quirk)
  cmark-gfm's, and the remaining 244 documents are explained by the documented deviations, by one-column
  tables and surplus table cells, and by quirks of the *oracles* (both mis-pair code spans in some paragraphs with an unmatched
  backtick run - a lookup cache; markdown-it needs a pipe in a table header, treats `| x |` + `---` as a table and handles lazy
  lines in nested quotes differently; cmark-gfm and markdown-it drop surplus table cells; Foundation loses code and emphasis inside
  link text). Where cmark-gfm and markdown-it disagree with each other the lexer follows the specification text.
* **Real-world corpus** (`--corpus`): all 1,358 `*.md` files found under /opt/homebrew, /Library/Developer and /Applications
  (9.86 MB, read only): `lexAll` with the structural invariants, cold `styleRuns` slices against `lexAll`, 150 random edits per file
  (copy / paste a line, delete lines, open a fence / comment, type, backspace ...; incremental == full) and an "oddity detector"
  over the runs (very long bold / italic / code runs, code blocks covering > 50 % of a document, `#` comments of unfenced code
  shown as headings, tables swallowing prose, links never closed, stray `**`, ...). 0 failures in 203,250 edits.
* Verified by mutation testing (breaking restart selection, convergence equality - including the empty-item flag -, weak-checkpoint
  validity, front matter restart each makes the fuzzer or a scripted scenario fail), an AddressSanitizer build of the whole suite,
  and a poison-fill hook for reads beyond the loaded window.
* Large-document tests: 2 MB idle-fill in 4 KB slices == one full lex, 300 random ranged calls on a 3 MB document, 300 KB / 2 MB
  single lines, 60 random edits in a 1 MB document, bounded-update behaviour, a 300,000-line blank run after indented code.

## Measured numbers

Apple M5 Pro, macOS 27, Swift 6.4 (Command Line Tools), `swift build -c release`, one thread. Corpora: synthetic but realistic
Markdown (front matter, headings, hard-wrapped and single-line paragraphs with emphasis / strong / code / links / URLs / strike,
nested and task lists, quotes, fenced code, tables, rules, comments; ~8.7 bytes per style run). 1 MB = 21,770 lines,
10 MB = 217,210 lines. All numbers from `mdkit-checks --bench` / `--sweep`; "us" = microseconds.

| What | Result | Target |
|---|---|---|
| Full lex (`lexAll`), 1 MB / 10 MB | 4.2 ms (237 MB/s) / 43.1 ms (232 MB/s); same on `NSTextStorage.string` (233 MB/s) | >= 50 MB/s |
| Cold first screen (~80 lines, fresh styler), 10 MB doc, at start / middle / end | 0.02 ms / 4.6 ms / 9.0 ms (the latter two are the block-state-only skim at ~1.1 GB/s, 2,317 / 4,623 checkpoints) | < 400 ms |
| Cold first screen, 1 MB doc, at start / middle / end | 0.02 / 0.5 / 0.9 ms | < 100 ms |
| Keystroke (insert / backspace), 10 MB doc fully lexed, at start | p50 13.4 / 12.8 us, p90 15.4 / 13.5 us, p99 18.7 / 18.1 us, max 30 us | p99 < 5 ms |
| ... in the middle | p50 11.5 / 11.2 us, p99 16.1 / 15.8 us, max 36 us | |
| ... at the end | p50 9.0 / 7.7 us, p99 11.8 / 9.8 us, max 27 us | |
| ... 10 MB doc with only the area around the cursor lexed (lazy open) | p50 7.5-9.1 us, p99 9.5-12.8 us, max 57 us | |
| ... 1 MB doc, middle | p50 10.3 / 8.8 us, p99 13.6 / 10.7 us | |
| Same through a real `NSTextStorage` + delegate (10 MB), start / middle / end | p50 14.6 / 11.9 / 10.0 us, p99 19.3 / 15.5 / 13.6 us, max 44 us | |
| Region returned per keystroke | mean 1,300-1,700 units, 90-135 runs (stride 2048; at most the block containing the edit + up to ~2 KB until the next checkpoint) | |
| Idle fill, whole 10 MB front to back in 8 KB slices | 1,203 calls, 51 ms total (195 MB/s), per call p50 42 us / p99 52 us / max 68 us | |
| Checkpoint memory | 4,812 checkpoints for 10 MB, 40 bytes each = 188 KB (~19 bytes per KB of text) | |
| Typing a code fence at the top of an 8.6 MB document with no fence below it (no re-convergence) | 9.2 ms to re-lex 8.6M units unbounded; `maxRegion` caps it | |
| 5 MB single line (prose, `*`, backticks, `[a](`, `<a `, `_a `) | lexAll 3.7-6.9 ms, first screen 3.6-6.4 ms, keystroke 3.7-4.9 ms (plain beyond the 64K inline cap) | no quadratic blow-up |
| 1 MB of deep quotes / empty lines / 40-char lines without blank / table rows / nested lists / CRLF / emoji | lexAll 3.7 / 9.7 / 4.5 / 14.1 / 12.8 / 7.9 / 5.1 ms; keystroke 0.02-0.06 ms | |

Review-round re-measurement (shared machine, load average 4-7, so slower than an idle one): `lexAll` 1 MB / 10 MB 4.4 ms / 43-45 ms
(224-233 MB/s; the whole real corpus 420-465 MB/s because its files are small and mostly prose), keystroke at 10 MB p50 9-14 us /
p99 12-24 us, cold first screen at the end of a 10 MB document 9.4 ms. `--stress` (60 pathological 1 MB inputs plus 40 x 60 KB single
paragraphs): the slowest input still runs at 69 MB/s, the slowest keystroke is 1.1 ms (typing inside a 1 MB unclosed `<!--` comment)
and the slowest cold end-of-document first screen 13 ms (1 MB of blank lines after an indented code line). The review fixes did not change these numbers: baseline and fixed lexer
measured back to back, 3 rounds each: `lexAll` 10 MB 228.8-230.6 vs 224.1-233.0 MB/s, keystroke in the middle p50 11.8-12.2 vs
11.5-12.2 us.

Checkpoint stride (`--sweep`, 10 MB, typing at the start, p50 per keystroke): 256 units: 36 us (27,062 checkpoints); 512: 24 us;
1,024: 16 us; **2,048: 13 us (default; 4,623 checkpoints)**; 4,096: 17 us; 8,192: 26 us; 16,384: 59 us. Smaller strides shrink the returned region but make
shifting the checkpoint tail after each edit more expensive; cold-start cost is flat (9.1-9.5 ms).

Test run (`mdkit-checks`, no arguments): 283 expectation cases + 731 conformance cases + regression scenarios + invariant /
incremental / large-document / API scenarios = **1,921 checks**, ~0.7 s, includes a 6,000-edit fuzz pass. Differential fuzzing,
final code: **14 seeds (7301-7314) x 250,000 edits = 3,500,000 edits** plus 6 seeds (7401-7406) x 250,000 edits with the grammar
extended by the last fixes (each run under a 120 s wall-clock guard, ~3.5 s each); the previous revisions passed 20 + 12 such seeds
too. Each edit is followed by one `update` and 0-5 random `styleRuns` calls checked against a fresh lex; also 3 x 100,000 edits under
AddressSanitizer. Earlier seeds that exposed
real bugs (all fixed, regression-tested by the fuzzer): convergence at offset 0 vs the front matter rule, stale `validAfter` on a
retained weak checkpoint, front matter closing line without line break at EOF.


## Known limitations

* Reference definitions are not resolved: `[text][ref]` is styled whether or not `[ref]` exists; `[text]` alone never is.
* Link reference definitions with the title on the next line, multi-line inline HTML tags / comments inside a paragraph,
  nested block structure beyond 16 containers, and list items whose content column exceeds 127 are not recognised.
* An edit that changes block structure (opening / closing a fence or HTML comment, `<!--`) re-lexes until the block state
  re-converges, i.e. possibly to the end of a document that has no further fences. MarkdownKit does that at ~1 ms per MB;
  the bounded `update(..., maxRegion:)` caps the work and reports `staleFrom`.
* One keystroke inside an enormous *single* line or paragraph chunk (5 MB line: ~4 ms, 64 KB inline-lexed chunk: ~0.5 ms) costs
  time proportional to the line, because the line is the unit of re-lexing; such lines are plain beyond the 64K cap.
* Inside the first 16,384 units of a document that starts with a front matter *candidate* (`---`) whose closing delimiter is
  not yet known, edits re-lex from offset 0 (bounded, ~10-100 us); once the closing line is known only edits above it do.
* Not thread safe (by contract); `MarkdownStyler` is not `Sendable`.
* Link destination / title on a line other than the link text's closing `]` (`[a](` + newline + `url)`) and tags / comments that
  span lines are plain text (inline syntax is lexed per line within a paragraph chunk).
* A one-character setext underline (`a` / `-`) is plain, and TOML (`+++`) front matter is not recognised (see the deviations above).
* Text after a task checkbox in a *setext heading* inside a list item does not carry the heading level (`- [x] done` + `  ===`).
