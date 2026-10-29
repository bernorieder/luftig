# luftig architecture

This document is for the person who changes the code next. It says where things are, how data flows, which invariants hold the
design together and which pitfalls (found in the two spikes and during integration) are the most likely to bite. The measurements
behind the decisions are in `spike-textkit.md` (text engine) and `spike-document.md` (documents, packaging, external changes);
the product brief and the performance budget are in `DESIGN.md`; the lexer has its own `Sources/MarkdownKit/README.md`.

## 1. Module and file map

```
Package.swift   swift-tools 6.0, Swift 5 language mode, macOS 14. Products: luftig (app), mdkit-checks (lexer tests). Re-stamps the luftig executable SDK 27.0 / minos 14.0 (pitfall 13).

Sources/MarkdownKit/          Foundation only. Text -> [MDRun] (UTF-16 range + composable MDStyle bit set). Incremental and
                              viewport-lazy: MarkdownStyler.styleRuns(in:of:) / update(afterEdit:changeInLength:of:maxRegion:) / reset().
Sources/MarkdownKitChecks/    mdkit-checks: 1932 checks (expectation tables, invariants, the 731-case CommonMark / GFM conformance suite, review regressions),
                              differential fuzzer (incremental == fresh lex), oracles (cmark-gfm through Foundation, markdown-it-py through Scripts/mdit_oracle.py),
                              real-corpus runs, stress inputs, benchmarks. (Read-only: it never writes the files it reads.)

Sources/luftig/
  main.swift, AppDelegate.swift, MainMenu.swift          entry point, lifecycle policy, the whole menu (built in code, no nib)

  -- the document layer (docs/spike-document.md) ---------------------------------------------------------------------------------
  MarkdownDocument.swift                NSDocument subclass: read(2)-based open, encode, save gate, presenter hooks, close / Save As sheets,
                                        the "edited" dot, autosave in place (3 s)
  MarkdownDocument+ExternalChanges.swift  the external-change policy: check -> silent reload | 3-way merge | conflict | deleted
  DocumentText.swift                    TextCodec (encoding / BOM / line endings, byte-exact round trip, strict UTF-8 validation), LuftigError
  BulkDecode.swift                      bytes -> NSString for big non-ASCII texts without NSString(bytes:length:encoding:) (a leak on macOS 27, see pitfall 16)
  DiskFile.swift                        FileSignature (dev, ino, size, mtime, ctime), FastHash, DiskReader (read(2), O_NONBLOCK + fstat: regular files only, retry while changing)
  TextDiff.swift                        UTF-16 prefix/suffix + line-level Myers diff (minimal edits), position mapping, Diff3.merge
  ExternalChangeMonitor.swift           kqueue on file + folder, coalescing / throttle, descriptor re-binding, 2 s poll for non-local volumes,
                                        1 s stat poll while the folder of the file is missing (deleted + recreated)
  EditorHost.swift                      the ONLY coupling document -> editor: protocol EditorHost / TextViewEditorHost, ViewportAnchor
                                        (top-of-window anchor that survives text changes), TextDiff.apply

  -- the editor (docs/spike-textkit.md) -------------------------------------------------------------------------------------------
  EditorWindowController.swift          window (zoomed to the screen's visible frame when opened, tabbing identifier, full screen), hosts the view controller; tabbingMode from Settings > General (never the system's
                                        "Prefer tabs"); `leaveFullScreenEverywhere` (MarkdownDocument.showWindows calls it: a file opened while another fills the screen opens on the desktop)
  EditorViewController.swift            THE editor: TextKit 1 stack + styler + column + banner; EditorHost conformance; font size; actions
  EditorPreferences.swift               every setting in UserDefaults (font size, text / code family, line spacing, column width, readable-width flag, colour scheme),
                                        (while a slider / stepper of the Settings window is dragged the broadcast is bounded: `beginAdjusting` / `endAdjusting`, invariant 25)
                                        validated on every read, broadcast to every window; `themeSettings` is what a Theme is built from
  LuftigEditorFactory.swift             the exact NSTextView / NSScrollView configuration (non-contiguous TextKit 1)
  LuftigEditorTextView.swift            drawBackground hook for the decorations; pre-styles jump targets (scrollRangeToVisible, Cmd-Up/Down); no responsive scrolling
                                        (pitfall 31); the drawInsertionPoint override that keeps full-screen scrolling smooth (pitfall 33); ⌘-click on a link (mouseDown)
  LuftigLayoutManager.swift             draws bands, quote bars, rules, inline-code pills (from the text view's drawBackground)
  Decorations.swift                     .luftigBlock / .luftigInline keys, BlockMark encoding, metrics, band path helpers
  ReadableColumnController.swift        centred column of `EditorPreferences.columnWidth` (480 ... 1400, default 760 pt) via textContainerInset and the text container's WIDTH
                                        (widthTracksTextView is off and the container's width is set by hand, pitfall 34); follows the clip view's frame;
                                        Typewriter Mode's vertical inset (half the viewport, so the first and the last line can sit in the middle)
  BannerView.swift                      the non-modal strip for external-change messages
  EditorChrome.swift                    the three elements around the text, without views: OutlineScanner (ATX / setext headings outside fences and front matter,
                                        chunked), WordCounter (chunked), SyntaxInsertion (text + selection -> TextChange: wrap / unwrap, link, line prefixes, blocks)
  EditorChromeViews.swift               OutlineView (NSTableView, no selection, hover), WordCountView, SyntaxBarView (SoftLabel: text that acts, never a bezel),
                                        EditorRootView (the page colour behind everything); all in Palette.marker, the body / code family at 12 pt; wired in
                                        EditorViewController's `chrome` extension: coalesced recomputation in 1 M-unit steps after edits, View menu switches
  ListEditing.swift                     Return / Tab / Shift-Tab on list and quote lines (pure: text + selection -> TextChange): the next item with the same prefix, the next
                                        number (the sequence below renumbered), an unchecked task box, an empty item outdented or unmarked, nesting by the marker's width;
                                        wired through `textView(_:doCommandBy:)`, never inside a code block or a composition; Settings > General > Continue lists on Return
  LinkFollowing.swift                   ⌘-click / Edit > Open Link (pure): the link under a character from the lexer's runs (inline, image, autolink, bare URL, reference
                                        through its definition, `[shortcut]` from the brackets), a destination -> web URL / file (relative to the document, with #anchor) /
                                        anchor in this document (GitHub heading slugs); the `links` extension of EditorViewController opens them (openExternally /
                                        openDocument are replaceable for the tests)
  MarkdownHTML.swift                    Markdown -> HTML from the lexer's runs (pure): the line-level facets open and close blocks, the inline facets nested tags, markers
                                        left out; Edit > Copy as HTML / Copy as Rich Text (RTF made from the HTML by AppKit), File > Export as HTML… (a page with a small
                                        stylesheet in the editor's fonts, light and dark)
  SettingsWindowController.swift        luftig > Settings... (Cmd-,): one singleton window; the preview on top, under it a switch between three screens (General: open files in
                                        tabs, what happens when the file changes on disk, continue lists on Return; Text, whose scheme popup also imports Base16 files; Layout:
                                        the three pane switches, the padding, pane font / size / opacity, outline wrapping and spacing), each an NSGridView in a
                                        container of its own; every control applies live and is saved; observes EditorPreferences.didChange
  SingleInstance.swift                  one running luftig: a second process of the bundle id (a second copy of the bundle, `open -n`) takes the 'odoc' Apple event itself, hands the
                                        files to the instance running longest (NSWorkspace.open withApplicationAt:), activates it and quits before it shows anything
  Padding.swift                         ONE number of points (Settings > Layout > Padding, 0 ... 50, default 20) that is every gap: the window frame on the left and the right
                                        (EditorViewController.windowPaddingConstraints; the top and the bottom are HALF of it, `windowVertical`: topPaddingConstraint,
                                        bottomPaddingConstraint), the margin above and below the text viewport and the outline alike (`textInsetVertical`, also half,
                                        verticalInsetConstraints: outside the scrolling, so scrolled text starts exactly where the outline's first entry starts; the text
                                        container has no vertical inset), the text's side inset (ReadableColumnController.minInset); the word count row
                                        is its line (16 pt), the syntax bar its symbols (18 pt); NOT padding: the outline's width, the indent per level, fonts, the gaps between
                                        the bar's symbols, the outline's row height (Outline spacing, a slider of its own). The Settings preview applies the same inset
                                        (SettingsPreview.applyPadding: its pixels are compared with an editor's)
                                        FIXED layout (plain constraints, fixed column widths and label widths: nothing moves or resizes whatever a value says, invariant 24); the size field shows the
                                        size in use even while it is being edited (pitfall 24); sliders and the stepper report their drags (`tracking`)
  SettingsPreview.swift                 the live preview in that window: the SAME factory, Theme and lexer as an editor (pixel-identical to an editor of the same width: matrix-preview)

  -- styling: lexer -> text view --------------------------------------------------------------------------------------------------
  Palette.swift                         every colour, read from the CURRENT colour scheme (plain loads of objects built once per scheme); Palette.apply(schemeID:);
                                        the contrast tables of the self-test
  ColorSchemes.swift                    the contract (ColorScheme, ColorSchemes.all / defaultID), SchemeColors, the default scheme (the palette luftig always had)
  ColorSchemesData.swift                the authentic palettes of 15 editor themes (hex values) and the role each colour plays (docs/color-schemes.md)
  ColorSchemesBuild.swift, ColorSchemesMath.swift   roles -> tints -> surfaces -> the contrast-driven lightness adjustment (OKLCH) -> SchemeColors
  ColorSchemesImport.swift              schemes from Base16 / Base24 YAML files in ~/Library/Application Support/<bundle id>/Color Schemes (both spellings of the format;
                                        the 16 slots mapped onto the roles; light / dark from the variant or the page's luminance), listed under the family "Imported",
                                        built like every theme; ColorSchemes.all reads the folder once and again after an import or when the Settings window opens
  ColorSchemesCustom.swift              CustomScheme: the user's own scheme from seven colours (Settings > Colors, which also holds the scheme popup), stored as a Base16 YAML
                                        file in the same folder with the line `luftig: custom` (listed under "Custom"); the draft the editors show live (ColorSchemes.draft,
                                        id custom-draft, never stored; editors rebuild on Palette.serial, not on the scheme id), Save (custom schemes only) / Save as New…
                                        (asks for a name, made free) / Delete; no legibility step (SchemeSpec.adjustsForLegibility false: the colours exactly as picked)
  SettingsFontFactory.swift             ThemeSettings (what a Theme is built from), FontFactory (faces of any installed family via NSFontManager, cached) and FontFace
                                        (what a family cannot provide - italic, semibold, bold - is faked with `.obliqueness` / `.strokeWidth`)
  Theme.swift                           MDStyle -> COMPLETE attribute dictionary, cached; built from ThemeSettings; uniform line heights; line-level normalisation
  MarkdownRunProvider.swift             adapter: LazyStyler closures <-> MarkdownStyler <-> Theme; widens a region to the whole tables it touches
  TableRender.swift                     tables drawn as grids while the caret is elsewhere (TableRenderer: column widths, wrapped cells, drawing; the
                                        row to draw is the `.luftigTableRow` attribute, LuftigLayoutManager hides its glyphs)
  TableAlignment.swift                  tables aligned on screen (TableAligner: `.kern` before each closing pipe, measured with CoreText; TableExtent: a
                                        table's start / end through the lexer), Format > Align Table (TableFormatter: the padded source)
  HangingIndent.swift                   hanging indents: the head indent of list items / indented lines (prefix width in the real fonts), HangMeasurer cache
  LazyStyler.swift                      viewport styling, the styled-range set, didProcessEditing restyle, IME guard, stale-tail handling

  SelfTest/                             everything below is compiled ONLY with -DLUFTIG_SELFTEST (Scripts/build-app.sh --selftest)
    SelfTest.swift, SelfTestUITrap.swift, SelfTestHooks.swift       runner, alert / save-panel trap, launch hooks
    SelfTestScenarios / Reload / Dirty / App / Bench.swift          the 18 scenarios of the document spike (codec ... menu, bench)
    SelfTestIntegration.swift, SelfTestRender.swift, SelfTestSupport.swift   integration scenarios, render, corpus, oracle, metrics
    SelfTestAuditDoc*.swift             auditdoc-*: property tests (diff / merge / codec), bytes in = bytes out, reload through the real editor, saving,
                                        coordinated writers, policy, model-based fuzz of the clean / dirty / conflict / deleted state machine, monitor, limits
    SelfTestAuditEditor*.swift          audit-*: real key events, clipboard, appearance, IME, leaks, lazy styling under random scroll / edit / font / resize,
                                        glyphs of CJK / emoji / RTL text, nested styling inside an edit cycle
    SelfTestVisual*.swift               visual-*: how it LOOKS, measured on pixels (metrics, bands, selection, rtl, contrast of every colour, partial redraw)
    SelfTestRobust*.swift               monkey (seeded random user), leaks, hostile files, resource policy, event storms, reader race, robust-regress
                                        (one group per defect the review fixed); Scripts/robust-soak.sh runs the heavy versions
    SelfTestSettings*.swift             settings-*: preferences, two windows following every setting, the oracle with non-default fonts, line boxes of 12 families, synthetic faces,
                                        the Settings window (controls driven with sendAction), Restore Defaults == the default look byte for byte, the budgets
    SelfTestSchemes.swift               schemes-*: every role of every scheme, contrast of every colour on every surface, Palette.apply x 60, selection on pixels, golden default
    SelfTestIndent*.swift               indent-*: independent oracle of the head indent, the real layout of every wrapped line, 2 x 1000 random edits, A/B measurements
    SelfTestLook*.swift                 look-*: the macOS 26+ look (the SDK 27.0 stamp): the stamp itself, the editor under the new chrome (first line not covered, TextKit 1 kept, legacy scroller, find bar), the banner with the translucent buttons,
                                        the Settings window under the new control metrics; internal: look-render (PNGs: banner, find bar, legacy scroller, alerts, icon), look-defaults (property dump to diff two builds), look-cost (first-use cost)
    SelfTestMatrix.swift                matrix-*: the three features together - decorations, hanging indent, the Settings preview and Print... under 5 combinations of scheme x font x size x spacing x column
    SelfTestFixSettings.swift           fix-settings-*: the Settings window's layout (nothing moves, 252 states), the size field with a field editor, dragging a slider over a 10 MB document
    SelfTestFixScroll.swift             fix-scroll (regression guard), fix-scroll-path (the editor opts out of responsive scrolling, NSScrollView agrees), fix-scroll-bench (measurement:
                                        trackpad-style scrolling in a full-screen-sized window, cold and warm, `--spell`), fix-probe-overdraw (what the responsive-scrolling overdraw costs),
                                        fix-scroll-screen (ON SCREEN: a real full-screen window on this display, one clip-view scroll per display frame, dropped frames per pass: pitfall 33)
    SelfTestChrome.swift                chrome-outline / chrome-words / chrome-syntax (the pure logic: tables of cases, chunked == whole, caps, speed), chrome-editor
                                        (the real editor: preferences + View menu, data after open, outline click, syntax bar click undoable + dirty + fresh lex,
                                        coalesced recomputation after typing, 6 MB in run-loop steps, fonts / colours follow the Settings and the scheme)
    SelfTestMergeLook.swift             look-settings-fixed: the fixed Settings layout under the new look (four appearances x every control's range, frames identical everywhere), the focused
                                        size field, clicks on the hosted sliders / stepper still reach their `mouseDown` (what the drag coalescing relies on)
    SelfTestPerf*.swift                 perf-guard (REGRESSION GUARD with generous budgets, skipped on a loaded machine) and the measurement scenarios perf-*
    SelfTestTables.swift                table-align (pipes line up in the laid-out text, file unchanged, aligned / tab tables left alone, a too wide one hangs),
                                        table-align-edit (a keystroke re-aligns the whole table, a long table styled from its middle, the size bound,
                                        narrower / wider window, == a fresh restyle), table-format (Align Table: the source, the caret, undo, the menu item)
    SelfTestTableRender.swift           table-render: tables drawn as grids (hidden glyphs, row heights, wrapping, the Markdown when the caret enters by
                                        selection / click / Select All, a narrower window, the switch, == a fresh restyle with the same selection)
    SelfTestFixTyping.swift             fix-typing-after-save: letters typed after an autosave survive a coordinated write, NSDocument's revert and an
                                        external change, also when the change count missed them (pitfall 40)
    SelfTestAuditShell.swift            the audit-shell-* scenarios: menu matrix, Info.plist / icon / claimed file extensions, preferences, the runner itself.
                                        SelfTestHooks.swift also holds LaunchProbe and CommandPump (drive a Launch Services launch from a script)

Scripts/build-app.sh            release or --selftest bundle; ad-hoc signing; verification; Resources/{Info.plist,AppIcon.icns,make-icon.swift}
Scripts/test-build-app.sh       tests of build-app.sh with a stub compiler (icon handling, the test-code guard, --out safety), ~8 s
Scripts/test-lifecycle.sh       black-box launch / reopen / quit / restoration tests of a COPY of the self-test bundle through Launch Services, ~45 s
```

## 2. Data flow

### Open: file -> styled first screen -> pixels

```
Finder / Dock / open -a -> odoc Apple event -> NSDocumentController -> MarkdownDocument.read(from:)
    DiskReader.readFile (read(2), signature) -> TextCodec.decode (-> NSString, LF) -> hash; text kept in `pendingText`
-> makeWindowControllers -> EditorWindowController -> EditorViewController.init
    LuftigEditorFactory.make (TextKit 1, allowsNonContiguousLayout = true), Theme(settings: EditorPreferences.themeSettings),
    MarkdownRunProvider + LazyStyler wired, ReadableColumnController
-> EditorHost.loadInitialText(text)
    undo off; LazyStyler.replacingWholeText { textView.string = text ... }     (13 ms at 20 MB; the styler ignores these edits and resets afterwards)
    one setAttributes(Theme.baseAttributes) over everything   (what not-yet-styled text looks like: same line height as styled text)
    undoManager.removeAllActions()                  (string = does not reset undo)
    styler.styleVisible()
-> LazyStyler.styleVisible: visible range from the layout manager (O(visible), +- 60 lines; no viewport yet -> the first 60 lines)
    provider.runs(in:) -> MarkdownStyler.styleRuns (skims block state from the frontier up to the range, ~1 GB/s; then lexes the range)
                       -> Theme.styledRuns (attributes per run; line-level normalisation)
    ONE beginEditing / setAttributes per run / endEditing; the range goes into `styled`
-> draw: NSTextView.draw -> drawBackground(in:) -> LuftigLayoutManager.drawDecorations (bands, bars, rules, pills) -> selection, glyphs
```
Scrolling: the clip view's `boundsDidChange` calls `styleVisible()`; when a screenful above and below is already styled it is a
0.0015 ms no-op. Jumps (`scrollRangeToVisible`, Cmd-Up/Down in `LuftigEditorTextView`) style the landing zone first, then scroll.

### Edit: keystroke -> restyled line

```
NSTextView.insertText -> delegate textView(_:shouldChangeTextIn:...) -> document.editorWillChangeText()   (captures the 3-way-merge base lazily)
-> NSTextStorage edit -> processEditing -> textStorage(_:didProcessEditing:range:changeInLength:)  [LazyStyler]
     keep `styled` in step (remove the replaced range, shift the rest)
     provider.update -> MarkdownStyler.update(afterEdit:changeInLength:of:maxRegion:)   ONLY here: the values AppKit passes are valid only here
         -> the re-lexed line-aligned region + runs (+ staleFrom when the bounded re-lex gave up)
     plain setAttributes per run INSIDE the callback (no begin/endEditing, no undo entry, document not dirtied)
     staleFrom: forget `styled` from there on, restyle the visible part right after the edit cycle (async, before the next display)
     IME composition (hasMarkedText): tell the lexer, apply nothing, leave a hole in `styled`; NSText.didChange after the commit fills it
```
A key press costs ~2-3 ms including the redraw of the edited lines (the lexer part is ~10 us, the restyle of the edited paragraph ~20-60 runs, `insertText` with restyle ~1.5 ms).

### External change: disk -> editor

```
ExternalChangeMonitor (kqueue) | NSFilePresenter | app activation / window key | save gate
 -> MarkdownDocument.checkForExternalChange (stat; background read + hash; decode only if the bytes differ)
 -> clean:  EditorHost.applyExternalText(.silent)      dirty: 3-way merge -> .undoable | conflict banner | deleted banner
 -> TextDiff.edits (minimal replaceCharacters in ONE beginEditing/endEditing; selection mapped through the edits)
 -> LazyStyler restyles the touched region from didProcessEditing (a huge hunk list just forgets `styled`)
 -> EditorViewController.applyExternalText: styleVisible(), then ViewportAnchor restore (the line at the top of the window stays there)
```

### Settings: font size (Cmd +, Cmd -, Cmd 0), text / code font, line spacing, colour scheme (luftig > Settings..., Cmd-,)
```
a control of the Settings window | View > Bigger / Smaller / Actual Size | View > Wrap to Readable Width
 -> EditorPreferences.<setting> = v      clamps, ignores NaN, writes only on change, posts EditorPreferences.didChange ONCE
    (colorSchemeID: Palette.apply(schemeID:) FIRST - NSApp.appearance, Palette.didChangeNotification -, then the post)
    (while a slider or the stepper is DRAGGED - `SettingsWindowController.tracking` between mouse down and up - the post goes out at once if the last one is old enough, else
     a little later with the newest values: at most one per max(40 ms, the cost of the last one); editors in windows nobody can see wait; the mouse-up posts the final
     values once more to every window: invariant 25)
 -> EVERY editor (EditorViewController.preferencesDidChange):
      settings (ThemeSettings) or scheme id changed:  new `Theme(settings:)` (new caches, new colour objects), provider.theme, base attributes over the whole
        text (so not-yet-styled text changes too), `styler.reset()`, `styleVisible()`, restore the line at the top of the window; page colour, caret and the
        window's appearance follow the scheme
      column width / readable-width flag: ReadableColumnController only (no Theme)
 -> the Settings window (SettingsWindowController.syncFromPreferences): shows the preferences, rebuilds its preview Theme the same way
```
`NSTextView.font =` is never used on a non-empty text view (it re-fonts the whole document). Measured: 10 MB document, the change + restyle + layout + repaint of the visible part
66-74 ms for a font, size, spacing or colour scheme (1 MB: 18-23 ms), column width 9 ms.

### Around the text: outline, word count, syntax bar (View menu; EditorChrome.swift, EditorChromeViews.swift)

```
open / external reload / NSText.didChange  -> scheduleChromeRefresh: a timer (0.3 s; 1 s above 4 M units; 0.15 s after open) restarts on every edit
 -> startChromeScan: OutlineScanner + WordCounter over the storage's NSString (no copy), 1 M units per run-loop turn (~1 ms per step on fresh text,
    6 MB in ~60 steps, the longest wait of the run loop 8 ms), abandoned and restarted when the text changes under them
 -> outline.entries (NSTableView reload), wordCount.text; the current section (the heading at or above the character under the top edge + inset)
    follows the clip view's bounds notification; the selection's own count is counted right away for selections up to 200 000 units
outline click  -> prestyle, layout around the heading, the heading line at the top (minus the text inset), caret on it, first responder
syntax bar click -> SyntaxInsertion.change(for:in:selection:) (pure) -> shouldChangeText / replaceCharacters / didChangeText on the text view
    (undoable with a named action, marks the document dirty, restyled by the styler from didProcessEditing), then the selection the change asks for
View > Show / Hide ... -> EditorPreferences.showOutline / showWordCount / showSyntaxBar -> didChange -> every editor: applyChromeVisibility
    (NSStackView detaches a hidden element: the text takes its place; an element shown without data for the current text - hidden at open, or during
    the last edit: chromeOutlineValid / chromeWordsValid - is computed at once). The bar belongs to the TEXT COLUMN (viewport over bar), so it is centred
    under the text; the outline runs on past it.
```
Nothing here is ever computed per keystroke; a hidden element costs nothing (no scan while both outline and count are hidden).

### Keys, links, Typewriter Mode, HTML (ListEditing.swift, LinkFollowing.swift, MarkdownHTML.swift, the `typewriter` / `links` / `html` extensions of EditorViewController)

```
Return / Tab / Shift-Tab  -> textView(_:doCommandBy:) -> ListContinuation.returnChange / indentChange (pure, on the storage's NSString) -> apply(_:actionName:)
    (the same change protocol as the syntax bar: shouldChangeText / replaceCharacters / didChangeText, one named undo step); nil -> the text view's own key.
    Never inside a code block (the `.luftigBlock` mark at the caret) or a composition; off with Settings > General > Continue lists on Return.
Format menu / ⌘B ...    -> luftigInsertSyntax (the item's tag names the SyntaxElement) -> insert(_:) - the same edit as a click on the bar.
⌘-click, Edit > Open Link -> LuftigEditorTextView.mouseDown (the glyph under the mouse, not the insertion index) -> followLink(at:) -> the lexer's runs of that
    line (styleRuns) -> LinkFollowing.destination -> LinkFollowing.target -> NSWorkspace (web, other files) / NSDocumentController (Markdown, at its anchor)
    / jump(toAnchor:) (this document: the outline's jump). A jump up to 300 K units into the text styles and lays out everything above its target first
    (exactJumpLimit, pitfall 36); beyond, it lands on the estimate.
View > Typewriter Mode  -> ReadableColumnController.typewriter (vertical inset = half the viewport less half a line) + centerCaretLine on every selection /
    text change: the caret's line fragment (the extra fragment after a trailing line break) to the middle, settling over up to 4 passes (pitfall 27).
Edit > Copy as HTML / Rich Text, File > Export as HTML… / Rich Text… / PDF… -> MarkdownStyler.lexAll (the whole text: a line's block depends on what is
    above) -> MarkdownHTML.html(text, runs, range: the selection's lines or everything) -> the pasteboard (.html + .string; Rich Text adds .rtf from
    NSAttributedString(html:)) / MarkdownHTML.document (stylesheet in the editor's fonts; without the web page's column for the rich-text exports) ->
    the save panel; RTF = NSAttributedString.rtf, PDF = that attributed string in an NSTextView of the paper's width through an NSPrintOperation that
    saves (jobDisposition .save, like matrix-print).
View > Show Reading Time -> EditorPreferences.showReadingTime -> the word count's row (shown when the count or the time is on): WordCountView.label
    (words, selection count, "7 min read" at 200 words a minute, rounded up) from the same WordCounter scan.
Settings > General > When the file changes on disk -> EditorPreferences.reloadBehavior -> MarkdownDocument.externalChangeArrived (the policy's one entry for a
    changed file) and the save gate: automatic (as always), ask (the banner for every change, no merge), never (nothing shown; the other version remembered
    so that a save asks). The invariant stays: luftig never writes over a version it was not told to.
```

## 3. Invariants (a change that breaks one of these breaks the editor)

1. **TextKit 1 with non-contiguous layout, one `NSTextView`.** Built by `LuftigEditorFactory` only. Never `NSTextView.scrollableTextView()` (TextKit 2) and never contiguous layout (a 2.5-10 s main-thread stall after open at 5-20 MB).
2. **Never style more than the viewport (+- 60 lines) or the edited region synchronously.** Whole-document styling is 1 s and +110 MB at 20 MB. There is no background fill by design (it would cost CPU and memory for nothing).
3. **Every attribute application is batched** (`beginEditing`/`endEditing`: 0.6 ms instead of 83 ms per 1000 runs). The single exception is the restyle inside `didProcessEditing`, which uses plain `setAttributes` and no begin/end.
4. **The lexer hears about EVERY character edit, from inside `didProcessEditing`, with the values AppKit passes** (afterwards they read `{NSNotFound, 0}`), and is `reset()` whenever the text is replaced wholesale. (MarkdownKit self-heals on a mismatch, but that costs a re-skim and a stale tail.)
5. **`styled` only contains text whose attributes equal a fresh lex.** Keep it in step with edits; apply the WHOLE region the lexer returns (it may start at the beginning of the paragraph / table containing the request, and the invariant "incremental == fresh lex" holds for the whole region, not for a clipped part); remove from `staleFrom` on.
6. **Complete attribute dictionaries** (`setAttributes`, never `addAttributes`: 2.8x cheaper, and nothing stale survives), cached per (style, line-level style).
7. **Uniform line heights**: every paragraph style has `minimumLineHeight == maximumLineHeight` (body: size x the line-spacing factor of the Settings window, 1.1 ... 2.0, or - "Automatic", the default - `Theme.lineHeightRatio`, rounded to whole points: 1.46 at 11 pt down to 1.31 at 28 pt; headings 1.3 x their size); only headings are taller. The box is never smaller than ascent + descent of the tallest face a line can hold (`FontFactory.lineExtent`: a tall family raises it and the Settings window says so; the system fonts at 9-40 pt are untouched by it); TextKit adds a font's own *leading* on top of the box (system fonts have none; Helvetica Neue ~3 %, Monaco 5-8 %). Styled and unstyled text then have the same height, which is what keeps the scroller monotone and scroll positions stable while styling is lazy.
8. **One paragraph style and one block mark per LINE, including its line break.** TextKit takes the paragraph style from the first character of a line. The lexer's runs do not guarantee that (the `> ` prefix of a quote line, the indentation of a continuation line inside a setext heading or of a fence inside a list item), so `Theme.styledRuns` gives every character of a line the line-level facets of the run that holds the line's break and splits runs at line breaks where lines differ. The setext underline LINE (`====`) is detected from the text and shown as a plain dim line (the run after the marker is split at its first line break, so the result does not depend on how the lexer cut its runs). (Both were found by the differential self-test - once through a 2-document soak run, 24 seeds x 2000 edits, 26 documents in total pass: a paragraph style that differed inside a line is silently replaced by AppKit's attribute fixing.)
9. **`.luftigBlock` on every character of a code / quote / rule line including its newline; `.luftigInline` on inline code including the backticks.** The renderer reads the mark at the first character of each line fragment.
10. **Decorations are drawn from the text view's `drawBackground(in:)`, not from the layout manager** (AppKit clips the layout manager's background drawing to the text container, so bands could not reach into the inset). `textContainerInset.width >= DecorationMetrics.bandOutset + 1`. The big fills (bands, panels) are OPAQUE colours (the tint composited over the page, `DecorationDrawing.Colors`: 10x cheaper to paint), bars and pills are translucent, and the SELECTION is painted translucent too (`LuftigLayoutManager.fillBackgroundRectArray`), so a band or pill under it stays visible and coloured text stays readable.
11. **Never override `setNeedsDisplay` on the text view**, never `tv.font =` / `tv.textColor =` on a non-empty document, never touch `textView.textLayoutManager` (it is nil: this is a TextKit 1 view).
12. **No manual scroll compensation while styling** (NSTextView already preserves the anchor when text above the viewport gets laid out; doing it again double-corrects: jumps of 500 pt). `ViewportAnchor` is only used for deliberate content changes (external reload, font size).
13. **Main thread only** for the lexer, theme and styler.
14. **Document layer**: the editor calls `document.editorWillChangeText()` before every user edit; the text view uses the document's undo manager; a held-back autosave is silent (`NSUserCancelledError`) and must not make close or Save As fail silently; `fileModificationDate` is synced after every silent reload; `revert(toContentsOf:)` never calls `super` and never discards unsaved edits on NSDocument's OWN initiative (a coordinated writer - File Provider / OneDrive / iCloud / Finder - makes NSDocument call it ~0.5 s after our own merge: it used to throw the merged text away without a word; now it runs the merge / conflict policy instead; only the explicit commands - the banner's Reload from Disk, File > Reload from Disk - call `revertNow(toContentsOf:)`); files are read with `read(2)`, never mapped, and only regular files (`O_NONBLOCK` + `fstat`).
15. **The shipping binary contains no test code**: everything under `SelfTest/` and `LaunchProbe` calls are inside `#if LUFTIG_SELFTEST`; `Scripts/build-app.sh` fails the build if a `selftest` string is found in the shipping executable.
16. **Menu**: install it in `applicationWillFinishLaunching` WITHOUT an "Open Recent" item (AppKit adds one; two otherwise); a menu item wired straight to `toggleContinuousSpellChecking:` is renamed by AppKit, hence the View item has its own action. The Help menu is registered but EMPTY (AppKit adds its search field): an enabled `showHelp:` item in a bundle without a help book only opens the alert "Help isn't available" (`audit-shell-menu` asserts there is none). View > Bigger has a hidden twin with key `=`: a menu item keyed `+` answers only ⇧⌘= on a US keyboard, not ⌘= (`audit-shell-menu` presses both).
17. **Launch**: AppKit opens the initial untitled document itself, except when the previous session ended with no window (every window closed before ⌘Q, or every restorable file gone): then the app started with NO window and looked dead (measured: 0 documents, 0 windows, until ⌘N or a Dock click). `AppDelegate.openUntitledIfNothingRestored` handles a plain launch (`currentAppleEvent` is 'oapp'; it is nil when a file is on its way) by opening the untitled document half a second later if there is still no document. A restore that takes longer than that adds one empty untitled window next to the restored ones (harmless; not seen: restoring two documents takes ~65 ms). `Scripts/test-lifecycle.sh` fails without it.
18. **A decoration is a function of its own line fragment and of the ATTRIBUTES of the characters around it, never of which neighbouring fragments are in the dirty rect.** AppKit repaints strips: the rows a scroll exposes (any height, at any y), the few lines after an edit, the caret. A strip drawn alone must equal the same strip of a full draw (`visual-redraw`, pixel for pixel). So shapes are built per fragment run, square where the block carries on (decided from the neighbouring character's attributes) and rounded only at true ends; the fragment ABOVE the dirty rect is drawn as well (the padding of a band reaches into the next fragment's rect), and the TOP edge of a band never lies above its own fragment's rect (with a tight line box - spacing 1.1, a font whose glyphs fill the box - there is no leading above the text, and the 2 pt minimum padding used to reach into the fragment above, which a strip drawn on its own did not draw: 12 pixels differed from the full draw, found by `matrix-visual`); the dirty rect is widened to the full container width (a rect that lies wholly in the inset still has bands in it); the hairline of Increase contrast is stroked only on closed sides; band edges are snapped to the DEVICE pixel grid of the window (a hairline on a fractional edge differed between a partial and a full draw on a 1x display).
19. **The styler restores what AppKit's attribute fixing would have given the text, and never styles from inside an edit cycle.** `LazyStyler` replaces attributes wholesale (invariant 6) AFTER AppKit's fixing pass, so text that needs a fallback font (CJK, emoji, Hebrew, Arabic, symbols) was laid out with glyph id 0 - invisible - after typing, paste, undo, an external reload or a font size change. `LazyStyler.apply` writes pure-ASCII runs as before; runs with characters >= U+0080 are fixed on a scratch copy and only the pieces that differ from the storage are written (typing in a 3 MB CJK document: 10-14 ms; Latin unchanged at ~1.5 ms). And `style()` returns and re-schedules itself when `ts.editedMask` is non-empty (AppKit calls `scrollRangeToVisible` and the clip view's bounds notification from inside its own `processEditing`; a nested `beginEditing` / `setAttributes` there left lines laid out from the OLD attributes after a font size change: 51 of 138 renderings differed from a fresh layout).
20. **Bytes in, bytes out; and what luftig writes it can read.** `TextCodec.decode` validates UTF-8 strictly (the Foundation decoder is not a validator: a lone 0xA9 became U+FFFD and was written back as EF BF BD), falls back to Windows-1252 / Mac Roman only for text with no valid multi-byte sequence and verifies the byte-exact round trip of every fallback; UTF-8 that is damaged (valid multi-byte text plus a stray byte) is refused untouched (`damagedUTF8`) because opening it as 1252 would garble every umlaut and the first typed arrow would save the mojibake as UTF-8; UTF-16/32 files are verified to round-trip, an odd trailing byte refuses them; a handful of NULs (<= 4 or <= 1 %) in otherwise valid UTF-8 is text, not binary (a pasted U+0000 is written back as a NUL byte and the document used to become unreadable). Before a 3-way merge the base is re-encoded and compared with what was last on disk (a base captured late made the merge delete the user's line), and a merge, silent reload or autosave waits for an open undo group and for IME composition.
21. **List items and indented lines hang; the head indent is a pure function of the line's own runs and the theme's fonts** (`HangingIndent.swift`). When such a line wraps, the second and following lines start where the TEXT of the first line starts, not at the left edge. TextKit takes `headIndent` from the paragraph style of a paragraph = one source line (invariant 8), so the whole feature is one number per line. A plain line (not a heading, code, rule, table, front matter, HTML or right-to-left line) hangs when its PREFIX - spaces / tabs, block quote markers, a list marker, a task marker, the spaces after each - holds a list marker or white space beyond the quote markers, and text follows. `headIndent` is then the x position where that text starts: the line's own indent (a quote's) + the width of the prefix, measured with CoreText in the fonts the prefix characters really have (the marker run is semibold; white space has the style of whichever run the lexer put it in, which can be the tail of the previous line's run; a tab advances to the next multiple of 28 pt, which `paragraphStyle` spells out: `tabStops = []`, `defaultTabInterval = 28`, AppKit's own grid). It is quantised to 0.5 pt, lives in `LineKey` (bits 10...21: so in the attribute cache key and the paragraph style cache) and is measured once per distinct prefix (`HangMeasurer`, one per Theme, checked against the fonts it measured with). Because it depends only on the characters and runs of the line, a fresh lex and an incremental restyle give the same value (`indent-diff`, `style-differential`); because every piece of a line carries the same value (`styledRuns` splits a multi-line run where it changes) invariant 8 holds. Never hard-code font metrics: the widths come from `Theme.font(for:)` / `Theme.attributes(for:)`, so the indent follows the text font, the size and the faked bold / italic of a family. The position that is measured is that of the FIRST GLYPH of the text, not the end of the prefix: many families kern the space before a T, A, V, W or Y (Avenir Next at 28 pt: TextKit puts the T 0.67 pt left of the end of the prefix), so the first text character is measured together with the prefix, read from the CTRun glyph positions (not from `CTLineGetOffsetForStringIndex`, the caret position, which gives each of the two glyphs half of the kerning); found by `matrix-indent` (wrapped lines were up to 0.9 pt right of the text). Not hung: right-to-left lines (right-aligned paragraphs have no left edge; left as they were), and prefixes wider than 10 em (TextKit gives every character its own line once `headIndent` reaches the container width, measured). Deliberate reading of "inside a list item": the rule looks at the line only, so a paragraph line indented by three spaces hangs by those three spaces too (CommonMark ignores the indentation, the editor shows it, and the wrapped part should line up with the text above it).
22. **A `Theme` is a pure function of `ThemeSettings` (size, text family, code family, line-height factor) and of the current colour scheme, and every font comes from `FontFactory`.** `Theme(settings:)` builds all its faces through `FontFactory.face` (NSFontManager, cached per family / size / weight / italic; a family that is not installed resolves to the system font and its saved name is never overwritten; a family without an italic or bold face gets `.obliqueness` / `.strokeWidth` attributes from `Theme.attributes(for:)`) and is never mutated afterwards: a changed setting or scheme is a NEW Theme (new attribute, paragraph and font caches), base attributes over the whole text, `styler.reset()`, `styleVisible()`, the line at the top put back (`EditorViewController.rebuildTheme`; the column width and the readable-width flag change no Theme). The attribute cache of a Theme is keyed by (style, line facets: heading, quote, block, setext underline, right-to-left, head indent) because everything else - fonts, colours, line box - is fixed for the life of the Theme. Code that needs a width or a metric (the hanging indent, the Settings preview, the tests) asks the theme and never hard-codes system fonts. A Theme costs 0.6 ms for the first one of a process and ~0.01 ms after.
23. **Colour: `Palette` reads are loads; a scheme change is `Palette.apply` THEN a new Theme.** The colours of a scheme (`ColorSchemes*.swift`: authentic palette -> roles -> tints -> a contrast-driven lightness adjustment -> `SchemeColors`) are built once per scheme (0.2-0.35 ms), so `Palette.text` is a load. A `Theme` caches NSColor OBJECTS in its attribute dictionaries, so after `Palette.apply(schemeID:)` every editor must build a new Theme: `EditorPreferences.colorSchemeID` applies first and posts after, and `rebuildTheme` compares scheme ids as well as settings. `Palette.apply` forces `NSApp.appearance` (Aqua / Dark Aqua for a fixed scheme, nil for the default), so the Settings window, find bar and sheets follow a fixed scheme; the page, the scroll view's background and the caret follow `Palette.didChangeNotification` (observed by the text view); the decoration colours are cached per `Palette.serial`. A fixed scheme ignores a window's `appearance`; the default scheme's colours are dynamic and follow it and Increase contrast. Printing is plain black on white and ignores schemes (`matrix-print`).

24. **The Settings window's layout is FIXED: nothing a value, a note or a font name says can move a control or resize the window.** The controls grid has fixed column widths (the widest
    label; slider + gap + value label) and is centred by plain constraints, every label that shows a value has a fixed width (monospaced digits, truncating, low compression resistance), the
    note under "Line spacing" sits next to the "Automatic" box (empty most of the time) instead of in a row of its own that comes and goes, and the window's height is computed once from
    the content (its width is the user's, 560 ... 2000 pt). It used to be an `NSStackView` holding a grid that was only bounded by two `>=` / `<=` margins and a `centerX`: the grid was
    then as wide as the window (fitting width 457 pt, frame 639 pt) and `NSGridView` handed the spare width to its FIRST column when the note row was shown and to its SECOND when it was
    hidden: with Fira Code at 14 pt the controls jumped 181 pt to the right when the line-spacing slider went below 1.36 (`fix-settings-layout`: 252 states, every control, to the pixel).
25. **A preference is written at once, its BROADCAST can be bounded, and the last value always arrives.** `EditorPreferences.beginAdjusting()` / `endAdjusting()` (the Settings sliders and
    stepper call them from `mouseDown`, which returns when the mouse is released: AppKit's tracking loop runs inside it - with a real mouse; headless it returns at once, pitfall 30) make `post()` send at most one `didChange` per max(40 ms, cost of the previous one) with the newest
    values (editors read the live preferences, so an old value can never follow a newer one), keep the labels and the Settings preview exact on every event, let editors in windows
    nobody can see (`isVisible` false: minimized, a background tab, a hidden app; no `.visible` occlusion state: another Space) skip the broadcasts of the drag, and end with ONE
    unconditional broadcast that brings every window, also those that skipped, to the final values. Outside a drag every change is broadcast at once, exactly once (tests, menu and
    shortcuts rely on it). Measured on a 10 MB document, 150 slider events at 120 Hz: 80 restyles before, 31 after (visible windows), 80 before and 1 after (hidden windows).
    If a future AppKit returned from `mouseDown` before the drag ends, the drag would be closed at once and every later event broadcast on its own: un-coalesced, as before the fixes
    round, never stale. Under the current look (pitfall 13) the sliders and the stepper draw through a hosted SwiftUI view INSIDE them, but a click still hit-tests to the control itself,
    so the override runs (`look-settings-fixed`).

## 4. Pitfalls, ranked by how likely they are to bite

1. TextKit 1 *contiguous* layout (the default of a hand-built stack) looks fastest in an open benchmark and then blocks the main thread for seconds. Check `allowsNonContiguousLayout` first when a big file hangs.
2. Un-batched `setAttributes` on non-contiguous layout: 83 ms per 1000 runs (a quick test on contiguous layout would show 2 ms).
3. Re-applying identical attributes to styled text invalidates layout and moves content (the styled-range set exists for this). Only the block straddling the edge of a styled range is re-applied now.
4. **TextKit 1 re-estimates the height of text it has not laid out** whenever the text changes. After an external edit far below the viewport the visible text can drift by a line, and `lineFragmentRect` and `glyphIndex(for:)` can disagree by a few points until the neighbourhood is laid out. `ViewportAnchor.restore` therefore lays out +- 3000 characters around the anchor and iterates up to four times; tests compare the *character at the top of the window* once layout has settled, not the absolute scroll offset.
5. **AppKit's attribute fixing replaces `.font` on runs with characters the font cannot render** (emoji, CJK, Hebrew) by a fallback font, and copies the first character's paragraph style over the rest of a line. The fallback must be restored after every `setAttributes` of the styler (invariant 19: without it the text drew as nothing), any comparison of the storage with the theme (the differential test) must allow it, and the paragraph style is invariant 8.
6. An Objective-C exception inside a block on the main queue is swallowed by `NSApplication` (nothing is logged, the work is abandoned) - in the test runner a scenario then "hangs" until the timeout. `NSApplicationCrashOnExceptions` is set in the self-test so it crashes instead (`~/Library/Logs/DiagnosticReports`). Typical cause in tests: undo manager with `groupsByEvent == false` and an edit outside `beginUndoGrouping`.
7. `NSTextStorage.string` bridges to a snapshot: cheap (lazy copy), but it is a snapshot - use it synchronously. `NSString.range(of:)` / `data(using:)` on a 10 MB storage string are 40 ms; use bulk `getCharacters` / bytes.
8. The first far attribute lookup in a never-touched 20 MB document costs ~9 ms per MB of distance (jump to the middle: ~100 ms, jump to the end: a few ms). Do not call `attribute(at:)` at the far end of a huge document at open. With lots of NON-LATIN text it is much worse (AppKit's lazy font fixing, `NSFont bestMatchingFontForCharacters`, runs over everything between the last fixed place and the requested one): the first click, keystroke or jump into the middle of a 10 MB document takes 0.5-2.7 s (RTL 2.7 s, CJK 1.1-1.3 s, emoji 0.5 s; a 3 MB CJK document 0.1-2.9 s depending on the place; 10 MB of accents only 86 ms, 20 MB of ASCII 160 ms), the second one next to it 40 ms. Not fixed: fixing in slices does not warm it, and an idle pre-fix would be background work (invariant 2).
9. With autosave in place AppKit shows no edited dot; `MarkdownDocument.syncEditedDot` sets it. `NSDocument` also ignores `window.isDocumentEdited` on its own for these documents.
10. `textView.string =` does not clear undo; `NSTextView.accessibilityLine(for:)` is O(document) (VoiceOver on 20 MB); a single line of megabytes costs seconds in any engine (TextKit lays out the whole paragraph again after every edit inside it, ~0.23 us per character: a keystroke inside a 100 KB line costs ~40 ms, 300 KB ~110 ms, 1 MB ~355 ms, 5 MB ~2 s; elsewhere in the same document 3.5 ms. `limitsLayoutForSuspiciousContents = true` makes it 2.5-3.5x cheaper but changes where such a line wraps: not adopted); `window.displayIfNeeded()` draws nothing for a `.prohibited` process (use `cacheDisplay`).
11. Launch Services registers every bundle that is launched, even by executing the binary inside it, and `.mkd` has no system type, so it is declared BY EXTENSION in a document type (never as an exported UTI: that changes how every app sees the file and made luftig, then its self-test build, the default for `.mkd`); an unregistered-extension launch can block on an invisible error alert (so does a binary file, a folder, or any file type the plist does not declare: `.mdx`, `.rmd`, `.json` ...; the alert ignores a quit request until it is answered). Unregister test bundles (`lsregister -u`), use the rank-None self-test bundle (Alternate ranks for Markdown and plain text, and rank None for the extension-only type: with EQUAL ranks Launch Services picks the most recently run app, which made luftig the default for `.mkd`), give a test bundle its own bundle id (preferences, recents and saved windows are keyed by it: two copies with one id share them).
11b. `open -g -j` hides the app only until a document window is ordered front: a launch that opens a document puts its window on screen (behind the active app, not activated), and the window keeps coming back until the app is hidden again. A hidden launch with no document stays hidden. Window restoration also replays every window of the previous session, so a series of test launches under one bundle id accumulates windows unless `-ApplePersistenceIgnoreState YES` is passed (which also stops that run from saving its state).
12. AppKit treats loose command-line arguments as files to open (`NSTreatUnknownArgumentsAsOpen = NO` in the self-test runner).
13. **The executable is stamped `minos 14.0, sdk 27.0` on purpose** (`Package.swift`, `linkerSettings` of the luftig target: `-Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker 27.0`; `otool -l luftig | grep -A5 LC_BUILD_VERSION`, printed by `Scripts/build-app.sh`, asserted by the self-test scenario `look-stamp`). SwiftPM alone records the deployment target as the SDK version (`sdk 14.0`); `dyld_get_program_sdk_version()` then says 14.0 and macOS 26 / 27 give the app their LEGACY chrome: title bar 28 pt, scrollers 15 pt, bordered white buttons. With the SDK stamp the system draws the current design (title bar 32 pt, 17 pt scrollers, `NSScrollPocket` views in every scroll view - zero-sized and hidden here -, flat translucent buttons; `NSButton`, `NSPopUpButton`, `NSTextField`, `NSStepper`, `NSBox` are `_NSCoreHostingView`s inside, which is probably what costs the 7 / 10 / 33 ms of the first window / find bar / Settings window - not proven; `NSView.prefersCompactControlSizeMetrics` is now false: slider 28 -> 16 pt, pop-up 20 -> 24, text field 21 -> 24, stepper 19 x 28 -> 20 x 24). What the stamp does NOT touch (checked with a diff of ~2,400 lines of public primitive properties of the editor window, scroll / clip view, scroller, text view, banner and fresh controls, `look-defaults`): the text view and its TextKit 1 stack (a `render` is pixel-identical), the layout of the content (the window has no full-size content view, so nothing lies under the title bar; `contentLayoutRect` == the content view, no safe-area inset), the find bar (a 32 pt top inset of the clip view in both looks). What it changes in the editor: `NSClipView.contentInsets.bottom` is 6 pt (the document can scroll 6 pt further, the text view is 6 pt shorter than the clip view), the legacy scroller takes 17 pt instead of 15 from the content (the column controller reads the clip view's width, so the column stays centred: `look-editor`), `NSScrollView.maximumNumberOfTouchesForScrolling` is unlimited. The headless renders (`cacheDisplay` of the content view) show neither the title bar / window frame, nor the tab bar, nor the full-screen chrome, nor the new scrollers (a classic render draws the overlay knob at the right edge, the new one nothing: `docs/screenshots/classic-look/02-emphasis-links-light.png`), nor controls of a KEY window (accent-coloured sliders and checkboxes: the renders show the inactive look). The shipping executable is instruction for instruction the classic one (disassembly and data sections compared; only the SDK field and the UUID differ). To go back to the classic look delete the `linkerSettings:` argument; `look-stamp` fails then, on purpose, the rest passes under both stamps. Measured A/B (fresh process, interleaved, n = 12, load 2.5-5.5): first window 58.8 vs 51.9 ms, first find bar 40.0 vs 30.0 ms, first Settings window 134 vs 101 ms, +1 / +10 / +7 MB. Do not use `-Xlinker -platform_version` with an SDK number higher than the SDK you build with (`build-app.sh` warns). The Settings window with its fixed layout (invariant 24) under the new metrics: its height is computed from the controls, so the content is 690 pt tall instead of 679; every frame stays put through every control's range in light, dark, a dark scheme on a light system and a light scheme on a dark system, and is the same in all four (`look-settings-fixed`, 716 states); `NSSlider` and `NSStepper` hold an `_NSCoreHostingView<SliderWrapper>` / `<StepperView>`, but a click still hit-tests to the control itself.
14. A synchronous `NSDocument.save` in the same run-loop turn as a synchronous edit made by a test (`typeText` then `doc.save(nil)`) deadlocks the main thread in `_NSDocumentSerializationSemaphore wait` (sampled). Tests let one turn pass (`await t.sleep(30)`) between the two, as a user's key presses always do.
15. Every `--selftest` process of one bundle shares ONE preferences domain (`com.bernorieder.luftig.selftest`: font size, readable width, window frames). Runs that overlap (two terminals, two agents) can flip each other's settings: the `menu` check "Wrap to Readable Width checkmark follows the state" failed in 1 of 3 runs while another agent's run was toggling the same key. Run the suite alone. The runner resets every preference key of the Settings window at its start (font size, fonts, line spacing, column width, readable width, colour scheme), which covers a run that was killed, not one that is still running; a scenario that changes preferences puts them back (`preservingSettings`). (`Scripts/test-lifecycle.sh` is not affected: it runs a copy of the bundle with its own bundle id.)
16. **`NSString(bytes:length:encoding:)` leaks on macOS 27.0.1**: for a NON-ASCII text above ~1-2 MB it leaves ~2 bytes per character of freed memory resident for ever ("Malloc Large (empty)" in `vmmap`, nothing in `leaks`; reproduced in a 30-line program without any luftig code: +430 MB after 45 decodes of a 5 MB file). Every open AND every auto-reload paid it (a 20 MB document ~40 MB per open; a log of 5 MB rewritten every 5 s would have taken ~7 GB an hour). `BulkDecode` transcodes well-formed UTF-8 itself (20 MB in 6 ms instead of 33-50) and slices Foundation for the rest; ASCII and texts <= 1 MB still use Foundation. `perf-decode-leak` asserts a flat footprint over 12 decodes.
17. **AppKit keeps the `NSTextStorage` + `NSLayoutManager` of a closed TextKit 1 stack alive in a fraction of the cases** (8 % of the closed 1 MB documents, 40-50 % of 40 closed together; reproduced without any luftig code), with the whole text, its attributes and its glyph data. `EditorViewController.deinit` breaks the storage -> layout manager link (`removeLayoutManager`): 0 of 100 / 0 of 40 stay alive (`robust-regress` textkit-leak, `leaks`). A closed `MarkdownDocument` itself lives until its autosave timer (3 s) has fired, and a headless `NSApplication` drains its autorelease pools only when an event arrives: leak tests close like a user (pause, `canClose`, `close`) and wait.
18. The pixel tests depend on the display they run on: the built-in display can be switched to a 1x mode (a game, a display setting) while a suite runs, and the backing scale of the offscreen windows follows. Both 1x and 2x must pass (`visual-redraw` found the 1x hairline defect of invariant 18). A scenario must also leave nothing running behind it: the robust watchdog's 1 ms heartbeat cost 3 % of a core for the rest of the process and failed the idle measurement of every scenario after it (`Robust.scoped` stops it). A hung self-test that ignored SIGALRM (a main-thread exception) was only killed by SIGKILL: use the runner's `--timeout` and a hard kill in scripts.
19. `LazyStyler.styleVisible()` called while a `beginEditing` batch is open hangs layout (found by accident, not reachable from the app's code paths).
20. TextKit facts found with the hanging indent (a bare `NSLayoutManager` probe): the DEFAULT tab grid is 12 stops of 28 pt and the 13th tab jumps back to 28 pt (`defaultTabInterval` is 0), `tabStops = []` with an interval of 0 makes tabs zero-width, tab stops are absolute (from the container's left edge, not from `firstLineHeadIndent`), `headIndent` is measured from the same edge, and a `headIndent` at or beyond the container width gives every character its own line fragment (width 0, x = container width). `CTLineGetTypographicBounds` of the prefix equals the glyph position TextKit lays out to 0.0001 pt (trailing white space included); `NSAttributedString.size()` too.
21. **Kerning reaches across the prefix**: a glyph is laid out where the CoreText RUN positions say, and a kerning pair (space, T) moves the T although the T is not part of the prefix. `CTLineGetOffsetForStringIndex` is the CARET position (it gives the T half of the kerning), `CTRunGetPositions` the glyph position TextKit uses (Avenir Next 28 pt, `- [ ] ` then T: prefix width 46.76, caret 46.42, glyph 46.09). Measure glyph positions. The system fonts do not kern the space, so only a test with other families sees it (`matrix-indent`).
22. **A faked bold (the `.strokeWidth` of a family without a bold face) has an anti-aliased outer edge that a strip touching only that edge does not repaint** (4-10 levels in single pixel rows; with the stroke switched off the partial draw is pixel-identical). `matrix-visual` skips the partial-redraw equality for such a family and says so; nothing but glyph ink differs.
23. **`--workdir` and `--timeout` of the self-test runner take ONLY the `--option=value` form** (`--workdir DIR` is ignored and the default work directory under /var/folders is used). The `hostile` long-path case builds a path of ~1016 characters; /var/folders/... is a link to /private/var/..., which the system resolves before it opens the file (+8 characters: 1024 = PATH_MAX, refused). It failed on this machine, the baseline build included, until the case started from the real path of the work directory.
24. **A sync must not skip a text field that is being edited - and must not overwrite what the user is typing.** The size field was skipped while it was first responder
    (`if sizeField.currentEditor() == nil { ... }`, written so that a sync never clobbered typing); after one click in the field it STAYS first responder, so the stepper arrows,
    ⌘+ ⌘- ⌘0 and Restore Defaults changed the size while the number beside the stepper stayed (measured on the baseline: preference 15, 17, 16; the field editor showed "14", its text
    selected: the user's screenshot). AppKit itself is not the problem: `doubleValue =` on a field that is being edited does update its field editor (measured: '33', still editing).
    Now a CHANGE of the size goes into the editor (`showSize`: `editor.string = text`, selected), and text the user is typing while something else changes is left alone. Also: a `NumberFormatter` with `minimum` / `maximum` makes the field REFUSE a number outside the range: it stays in editing with the refused text (measured: after
    Return the editor still showed 100 and the preference was unchanged). The formatter has no limits now and `EditorPreferences.fontSize` clamps (100 -> 40, the field shows 40); a string the
    formatter cannot read goes to `control(_:didFailToFormatString:errorDescription:)`, which puts the size in use back. The decimal separator is the LOCALE's ("12,5" here).
25. **`NSGridView` gives spare width to a column**: a grid whose width is not pinned (here: `centerX` plus two inequalities) is stretched to the space it is offered, and which column takes the
    slack depends on which cells are in play (a hidden row, a wrapping label's preferred width). Give every column a fixed `width` and the grid a definite width; do not put a grid in a stack
    view with an alignment that also constrains it. `fittingSize` of an `NSButton` is its FRAME (shadow and focus ring included), the constraints place its alignment rect:
    `alignmentRect(forFrame:)` for sums of heights.
26. **A headless window cannot show phased scroll events or run the display cycle - but a layer can be told to display itself.** A `CGEvent` scroll with a scroll phase is taken ASYNCHRONOUSLY
    by AppKit's gesture machinery (the `began` event applied 20 ms later, the `changed` events dropped: measured with a probe scenario during the fixes round, not kept); phase-less pixel-delta events run the same synchronous
    `scrollWheel:` -> clip view -> `boundsDidChange` -> styling -> layout path. `window.displayIfNeeded()` draws nothing (pitfall 10), but with `contentView.wantsLayer = true`,
    `textView.layer?.displayIfNeeded()` runs AppKit's OWN display cycle for the text view and `LuftigEditorTextView.drawLog` sees every rect it draws: after a scroll step just the exposed
    strip; after the text view's FRAME HEIGHT changed the WHOLE visible rect (`layerContentsRedrawPolicy` is `.duringViewResize`). The layer's `contentsScale` is 1 without a screen:
    set the window's backing scale first (`fix-scroll-bench` does).
27. **Non-contiguous layout revises the text view's height as text is laid out** (about half of the steps of a FIRST pass over a document, by up to 500 - 900 pt; none on the second
    pass), and every revision is a full redraw of the visible rect in AppKit's own display cycle (pitfall 26): measured in a 1512 x 982 pt window at 2x, a step with a height change
    cost 2.1 - 3.0 ms against 0.4 - 0.5 ms without (1 / 5 MB documents; Fira Code is the most expensive). That is why the first pass over text costs 2 - 3 times the second (`fix-scroll-bench`
    cold vs warm: p99 4 - 7 ms vs 1.3 - 1.9 ms). Laying out the text just below the viewport between two frames (a bounded "look-ahead", tried in the fixes round) batches the revisions
    (3x fewer full redraws, cold p99 2.6 - 4.1 ms) but does not remove them; it was NOT adopted because the stall the user reported was not reproduced (section 7). Not tried either:
    `layerContentsRedrawPolicy = .onSetNeedsDisplay` would avoid the redraw, but it changes what AppKit invalidates and could not be checked on a real display.
28. **`NSLayoutManager.lineFragmentRect(forGlyphAt:effectiveRange:withoutAdditionalLayout: true)` answers an ESTIMATED fragment (width 0.001) for text that is not laid out** (never forces
    layout; `glyphIndexForCharacter(at:)` does not lay out either), and `numberOfGlyphs` counts the whole document in non-contiguous mode. "Is this laid out?" is `width > 1`.
29. **Thread CPU time tells a stall of the code from a stall of the machine.** A step of the scroll benchmark that took 16 - 22 ms wall time but 3 ms of `CLOCK_THREAD_CPUTIME_ID` was
    descheduled or waiting (the machine is shared: load 2 - 5), not computing; every run on this machine has a handful of them. `fix-scroll` asserts the p99 and that no step COMPUTED for
    more than 16.6 ms.
30. **A headless process cannot drive a control's mouse tracking.** AppKit's tracking loop (the slider's and the stepper's, in the classic and in the new look alike) finds no mouse button
    really pressed and returns at once: mouse events queued before `mouseDown` stay in the queue (all 41 of them, measured in both looks; drain them, or they are delivered later), and
    the knob goes where the real pointer happens to be. A synthetic mouse-down through `window.sendEvent` to a window that is not key does nothing, nor does `mouseDown(with:)` on the
    stepper; `accessibilityPerformIncrement()` answers false. Drive controls with `sendAction` / `performClick`; call `mouseDown` directly only to check what an override wraps around
    the tracking (invariant 25), and check with a real mouse whether the tracking BLOCKS. Related: after `NSApp.appearance` changes (`Palette.apply`), a window's `effectiveAppearance`
    follows one run-loop turn later (measured: right after switching from GitHub Dark to Solarized Light it still said Dark Aqua); let a turn pass before reading it.
31. **Responsive scrolling (the trackpad path) lays out screens of overdraw ahead of the viewport and redraws the whole layer whenever the height is revised.** AppKit opts an
    `NSScrollView` into concurrent ("responsive") scrolling when it, its clip view and its document view override none of a list of methods (`scrollWheel:` ...) and the document view's class
    answers `isCompatibleWithResponsiveScrolling` (NSTextView: yes). It only ever applies to trackpad and mouse-wheel gestures; the scroller's knob, `scrollRangeToVisible`, Page Down take the
    synchronous path. On the responsive path AppKit calls `prepareContent(in:)` with an OVERDRAW rect beyond the visible one (it starts at the visible rect and grows while idle) and NSTextView
    lays that rect out in full (`_ensureLayoutCompleteForRect:withExtensionFactor:minimumExtensionDistance:repetitions:preparedContentRect:`, in its method list), so that a scroll thread can move
    pre-rendered content while the main thread is busy. Over fresh text that is 2 - 11 ms per call in a 1512 x 982 pt window (1 MB, Fira Code 14 pt), and nearly every call revises the text view's
    height by 400 - 3900 pt (`fix-probe-overdraw`; pitfall 27: non-contiguous layout re-estimates), which under `.duringViewResize` redraws the layer - visible rect AND overdraw - and resyncs the
    scroll thread; text beyond the styler's 60-line margin is laid out with the base attributes first and again, styled, when it scrolls in. In daily use that was "choppy, then smooth for a second,
    then choppy again" with two fingers in a full-screen window while dragging the knob was smooth: the knob's path lays out and draws the exposed rows only (2 - 3 ms with a height revision,
    pitfall 27). `LuftigEditorTextView` therefore answers `isCompatibleWithResponsiveScrolling` with false; NSScrollView's own verdict (`_isConcurrentScrollingCompatible`, a private method read
    in the self-test only) then says NO for the editor and YES for a stock NSTextView (`fix-scroll-path`), and every scroll takes the synchronous path that `fix-scroll` measures (p99 under a 120 Hz
    frame in a full-screen-sized window). The scroll thread itself cannot run headless (pitfall 26): the diagnosis rests on the user's observation (trackpad choppy, knob smooth), on NSTextView's
    method list and on the measured costs, and the fix on a hand test with a real trackpad. Do not add a `scrollWheel:` override anywhere in the editor's hierarchy to get the same effect: it would
    opt out silently and nobody would know why.
32. **`NSTextView.shouldChangeText(in:replacementString:)` outside an event needs an open undo group.** NSTextView's change protocol (the way to make a programmatic
    edit undoable, dirty and restyled: `shouldChangeText` / `replaceCharacters` / `didChangeText`) registers the undo right there, and NSUndoManager raises
    "must begin a group before registering undo" when no group is open - which is the case for anything not called from inside an event (a self-test, a timer,
    a script); a real click has AppKit's per-event group. `EditorViewController.insert` opens one itself when `groupingLevel == 0` (the syntax bar).
33. **Full-screen scrolling stuttered because of the insertion point's view, and the cure is an override of `drawInsertionPoint(in:color:turnedOn:)` that
    only calls `super`.** Measured with `fix-scroll-screen` (ON SCREEN: a real full-screen window of 1512 x 949 pt on this 120 Hz display, the clip view
    scrolled one step per display frame through a CADisplayLink - what the trackpad path does once the editor opted out of concurrent scrolling - 480
    frames per pass, the gaps between frame callbacks, the main thread's busy stretches between run-loop waits, the rects AppKit asked the text view to
    draw, and `sample` of the process during a pass). The first pass over any text: 0 - 6 dropped frames in 480. A second pass over text shown before,
    in either direction, after a jump or not: 55 - 60 stalls of ~37 ms (five frames each, about ten a second), the main thread waiting in
    `CABackingStoreSynchronize` / `CA::Render::Context::wait_for_synchronize` for the render server at the Core Animation commit. Windowed: never.
    Not editable, or not first responder, or with the styler's edits in flight (they pause the caret's blink): never, which is why fresh text was
    always smooth and only revisited text stuttered - the user's "after a while it suddenly works fine". No difference from: redrawing the whole
    visible rect every frame, changing the view's height every frame, a fresh layer (`wantsLayer` off / on), the clip view drawing the text into its own
    layer, `copiesOnScroll`, `drawsAsynchronously`, the redraw policy, a non-opaque window, the scroller, the panes, the input context, accessibility,
    the caret's position, the indicator's display mode, hiding or removing the `NSTextInsertionIndicator` view, a timer instead of the display link,
    a wait after the jump, a look-ahead layout in idle time (that one made it worse: 205 dropped frames). With the override NSTextView draws the caret
    on the classic path (it uses its `NSTextInsertionIndicator` subview, macOS 14+, only for subclasses that do not override the method): 0 - 1 dropped
    frames in every pass, three runs and the reverse pass. The caret then is the classic bar in `insertionPointColor` (`Palette.caret`), blinking as
    before. The headless benchmarks (`fix-scroll-bench`, `fix-scroll`) could never see any of this: no window server, no render server.
34. **The container's width is set by hand.** `textContainerInset` is symmetric. A round of the padding work gave the text more air on its right than on
    its left (`trailingExtra`), for which `ReadableColumnController` switched `widthTracksTextView` off and set the container's width itself on every
    clip-frame change: `clip width - 2 * inset - extra`. NSTextView draws a container narrower than the view at the inset's origin and never centres it
    (measured with a bare NSTextView: origin (28, 20) whatever the container's width), so left = inset, right = inset + extra. The extra was dropped
    again (the window frame right of the scroller is the air there) but the mechanism stayed: the width is `clip width - 2 * inset`, spelled out.
    Everything that reads `textContainerOrigin` (the styler's viewport query, the anchor, the decorations) is unaffected; what reads
    `textContainer.size.width` sees the container's width, which is the point (the bands end there). The Settings preview uses the same controller. The override also sizes the caret: as tall as the font at the insertion point (ascent + descent, on the baseline) instead of the whole uniform line box, inside the rect AppKit invalidates for the blink (`caretRect(within:)`).

35. **Do not override `draw(_:)` on the NSTextView to paint over the text.** A (since removed) Focus Mode veiled everything but the paragraph at the caret;
    drawn from an override of `draw(_:)` that called super and filled the page colour over the rest, it was correct on screen, but `visual-redraw` then
    trapped: with `draw(_:)` overridden, NSTextView invalidates with `NSRect.infinite` (the whole view) on every edit, and the test's row arithmetic
    overflowed (the same whole-view invalidation also turned out to happen once per edit on the untouched tree on this macOS build - the test now reads an
    infinite rect as "every row"; it may be the system, not luftig). The way that worked, should anything like it come back: paint from
    `LuftigLayoutManager.drawGlyphs(forGlyphRange:at:)` after `super` has drawn the glyphs of the range, per line fragment, with no attribute changes (the
    styled text stays a fresh lex) and no invalidation changes; and leave the extra line fragment after a trailing line break alone until the last glyph is
    drawn (before the end is laid out its rect is a guess that covered the whole viewport).

36. **A jump to a heading lands on an ESTIMATED y.** `ensureLayout(forCharacterRange:)` around the target lays out that range only; with non-contiguous
    layout the y of its line fragments is estimated from the text above that was never laid out (a heading 80 lines down was placed at 192 pt instead of
    ~1900: `edit-links`), and `scrollRangeToVisible` has the same problem. The outline's and the anchors' jump styles and lays out everything from the
    start of the text up to the target when the target is within `EditorViewController.exactJumpLimit` (300 K units: a layout pass over the text above,
    styled first so that headings have their real height) and calls `sizeToFit()` so that the text view's frame follows the layout at once (AppKit does it
    at the end of a layout pass, which a jump cannot wait for). Beyond the limit the jump lands on the estimate and the display refines it. Typewriter Mode
    recentres over up to 4 passes for the same reason.

37. **`cacheDisplay(in:to:)` of the (flipped) text view gives a bitmap whose rows run bottom-up.** A test that samples pixels of a line at y (view
    coordinates) reads rows `(visible.maxY - lineRect.maxY) * scale ... (visible.maxY - lineRect.minY) * scale`, not `lineRect.minY * scale`; `edit-focus`
    reads whole 23 pt bands from the top instead of single lines, which does not depend on the mapping.
38. **AppKit scrolls the view from inside the text view's resize after an edit, and in a document of long paragraphs it scrolls wrong.** Every edit makes the
    layout manager revise the text view's height (the estimates for text it has not laid out change with the edit, by a few points to 100 pt), and from inside
    `-[NSLayoutManager _resizeTextViewForTextContainer:]` AppKit (a) scrolls by the height change as if it had happened above the viewport (`scrollPoint:`) and
    (b) asks `scrollRangeToVisible` for the whole invalidated paragraph. With paragraphs that are one physical line of 1,500 characters (a dozen visual lines), every
    Backspace moved the view by 34 - 100 pt while the caret's line stayed put, and after a few keys the view snapped back by the sum (reported while editing a proposal;
    typing letters did not do it, deletions did). Not reproducible in a headless window: the scrolls come from the layer geometry update of the display cycle
    (`_updateLayerGeometryFromView` -> `_ensureLayoutCompleteForVisibleRect`). `LuftigEditorTextView` captures a `ViewportAnchor` in `shouldChangeText` and
    restores it in `didChangeText` (a position check, so a correct compensation is left alone; invariant 12 is about deltas during styling, this is not one), and a
    `scrollRangeToVisible` that arrives while `setFrameSize` runs is reduced to "scroll the caret into view at the end of the frame change if it is out of view".
    The on-screen tool `scroll-probe` (`--input f.md [--typewriter] [--line-spacing X] [--padding N] [--at-text T] [--keys 'ab<bs><cr>'] [--trace]`) types in a
    real window and logs every movement of the view with the call stack of the first scroll after each key; `edit-scroll-stability` is the headless part.

39. **A table's alignment depends on every row, so a table is always styled whole.** Tables are aligned on screen by a `.kern` attribute on the last
    character before each closing pipe (TableAlignment.swift); the text is never touched. The width of a column is the widest cell of ALL rows, so styling
    one row needs the others: `MarkdownRunProvider.wholeTables` widens every region it styles (lazy slices and the re-lex after an edit) to the whole tables at
    its two ends, by asking the lexer about the lines above (up to the header row) and below (`TableExtent`, resuming from checkpoints), and lexes the widened
    range once more; the result is a fresh lex, so it may replace the first one. A keystroke in one cell therefore restyles the whole table (420 rows: ~12 ms
    per keystroke, `table-align-edit`). Bounded: a table over `TableAligner.maxTableUnits` (24 K units) is never aligned, whichever way it is reached (the
    search gives up after the same bound, so a lazy slice and an edit agree); a table cut by a region that cannot be widened is left unaligned in it. The
    decision also depends on the text container's width, which is not part of the Theme: in a table wider than the column only the leading columns whose
    pipes fit on the first line of every row are aligned, and its rows hang from their second cell (a paragraph style with `headIndent`, on the row's whole
    line as invariant 8 wants; not when that is past half the column, cf. invariant 21's cap). `ReadableColumnController.onContainerWidthChange` ->
    `TableAligner.setWidthLimit` answers whether one of the limits measured so far (a table's width, where each closing pipe ends, twice the widest hang)
    lies between the old and the new width, and only then the styled set is forgotten (`LazyStyler.forgetStyled`, the lexer keeps its checkpoints) and the visible text restyled after the layout pass. The
    oracle (`StyleOracle.expectedRuns`) aligns too, with the editor's limit, so every differential test checks the alignment as well. Measurement: one
    CoreText line per row in the row's fonts, with `fixFontAttribute` for the fallback AppKit gives CJK / emoji; the pipe positions are
    `CTLineGetOffsetForStringIndex`. The kern goes on the whole composed character before the pipe (an emoji with a skin tone is one glyph from four
    units, which takes its attributes from its first unit); a decomposed `e` + U+0301 was checked to come out right. Rows with a tab are not aligned (a tab's
    width depends on where it starts, and the kern before it would move the tab stop).
40. **Never replace text that is not on disk because NSDocument's change count says "saved".** The change count lags behind the text: it moves at
    the end of an event cycle, and NSTextView coalesces typing into ONE undo action, so typing that goes on after a save registered nothing new
    and the document said "not edited" (luftig 1.0.5, in a OneDrive folder: the File Provider writes the file after every upload with a coordinated
    write, NSDocument reverts by itself - relinquish, reacquire, `revert(toContentsOf:)` - and the revert of a "clean" document applied the saved
    text: the last letters vanished and the caret jumped back). Two guards: every save of the document's own file breaks the coalescing first
    (`EditorHost.documentWillSave`, as TextEdit does), and every path that would apply disk text silently (the automatic reload, the save gate,
    NSDocument's revert, `read(from:)` with an editor) first asks `editorHasUnsavedText()`: the editor text encoded with the file's format must
    be the bytes of `lastDisk`; if it is not, the document is marked edited and the change is merged (or the banner asks). The self-tests' key
    presses break the coalescing after every key, so they never saw it; `fix-typing-after-save` sets the change count wrong by hand. The shipping
    app logs every save / reload / merge / conflict decision to the system log (subsystem `com.bernorieder.luftig`, category `file`; counts and
    reasons, never the text or a file name).
41. **A table drawn as a grid is still its Markdown, laid out differently** (TableRender.swift). Its characters keep their place in the text storage;
    `.luftigTableRow` on every character of a row (line break included) makes LuftigLayoutManager (its own NSLayoutManagerDelegate) give them `.null`
    glyphs, so they take no room, and the row's paragraph style has the drawn row's height (min = max; the delimiter row 2 pt). The grid and the cell
    text are drawn with the decorations, per line fragment (invariant 18: a strip draws what the full draw does). What is drawn depends on the text, the
    theme, the column width AND THE SELECTION (`TableAligner.revealed`: a table that holds the caret or an END of a selected range shows its aligned
    Markdown; a selection that only passes over a table leaves it drawn and tints its rows, so Select All and a drag restyle nothing). The selection is
    an input of the styling like the width: `EditorViewController.tableSelectionChanged` forgets and restyles the tables at the ends of the old and the
    new selection, and since an edit is styled BEFORE the text view moves the selection, every decision is recorded (`TableAligner.decided`) and checked
    against the settled selection (`reconcileTables`, right after the selection notification or on the next turn). "The table at the caret" and
    `isRevealed` must agree on the line after a table (not in it: found by `audit-keys`, ⌥↓ out of a table). The oracle is handed the editor's aligner
    (`StyleOracle.expectedRuns(..., tables:)`). Glyphs: AppKit regenerates them when a FONT changes, not when only `.luftigTableRow` does, so once a
    table was hidden every attribute change regenerates the glyphs of its range (`LuftigLayoutManager.processEditing`). A hidden glyph at the start of a
    row may belong to the line fragment ABOVE (AppKit's choice depends on the layout's history): measure a drawn row through its line break, map a click
    through the fragment's line break, skip such fragments when comparing layouts. Not drawn: tables in quotes (the `>` prefix is part of every row),
    tables over the size bound or cut by the region.

## 5. Measured against the DESIGN.md budget (release build, Apple M5 Pro, merged tree with Settings, colour schemes and hanging indent)

Measured on the merged tree of the three features (Settings window with fonts / line spacing / column width, colour schemes, hanging list indent). Open / typing / idle / memory are three runs of `--selftest open-perf,typing,idle,memory`, EACH INTERLEAVED with the same run of the build without the three features (private bundle copies, load average 1.6-2.4: the machine is the user's and is never idle). The launch rows below are the earlier measurements of the build WITHOUT the three features, not repeated: this environment has no launch driver (a hidden launch through Launch Services that checks what is on screen), and the app's launch path changed by a menu item, `Palette.apply` (0.35 ms, cold) and a first `Theme(settings:)` (0.6 ms); the Settings window is built on the first Cmd-, only. Launch times are the SHIPPING bundle (a byte-identical copy with its own bundle id) launched through Launch Services, hidden (`open -g -j -n` equivalent, `-ApplePersistenceIgnoreState YES`), time from the launch call / from the kernel's process start to the first document window in `CGWindowListCopyWindowInfo`, at load average 2-5.

| Budget | Target | Measured |
|---|---|---|
| Cold launch to first window (untitled) | < 150 ms | (build before the three features, not re-timed) **NOT MET on this machine today: median 176-182 ms since process start (183-188 ms from the launch call), p90 190-200 ms** (3 x 12 launches, interleaved with the baseline build: 175-195 ms median, the same within noise; one pair 4 ms apart in the baseline's favour). The AppKit floor in the same interleaved runs: an app with an empty `NSWindow` 162-168 ms, with a scroll view + `NSTextView` 182 ms, so luftig is at the floor: AppKit and Launch Services dominate (phases, self-test variant: 16 ms to `main`, +38 ms to `applicationWillFinishLaunching`, +31 ms AppKit's untitled-document machinery, ours ~20 ms: menu 4 ms, window + editor stack 16 ms). Earlier runs on a differently loaded machine saw 133-195 ms with a 149-154 ms median; the figures move with whatever else the machine does, the relation to the floor does not |
| Cold launch with a file | - | 1 MB: 203 ms (baseline 201); 10 MB: 213 ms (baseline 229); 20 MB: 235 ms (baseline 258). Real Markdown corpora, median of 15 launches |
| Open 1 MB, first screen laid out + styled + drawn | < 100 ms | **16.6-16.8 ms** warm (median of 7 fresh documents; baseline in the same interleaved runs 16.9-17.0), 48.9-49.1 ms in a fresh process (baseline 47.9-49.0; first-window AppKit warm-up). With Georgia / Menlo 19 pt x 1.7: 15.1-15.3 ms |
| Open 10 MB | < 400 ms | **21.3-21.6 ms** warm (baseline 21.7-23.0), 54.7-55.4 ms in a fresh process (baseline 53.6-54.5) |
| Open 100 KB / 20 MB | - | 14.8-14.9 ms / 28.0-28.3 ms warm (baseline 15.1-15.2 / 28.1-28.5; of the 28 ms, 12.5 ms are reading and decoding the 20 MB file) |
| Typing, <= 200 KB: keystroke = insertText + restyle + layout + redraw of the dirty strip | < 8 ms | **2.0-2.7 ms** median (start 2.7, middle 2.0, end 2.5; baseline 2.68 / 2.00 / 2.47), p95 <= 2.9 ms; with a FULL redraw of everything visible (upper bound) 3.0-3.6 ms. With non-default fonts, 19 pt, spacing 1.7: 1.6 ms (p95 1.75) |
| Typing, 10 MB | < 16 ms | **2.1-3.0 ms** median (start 2.7-3.0, middle 2.5, end 2.1-2.2; baseline 2.68 / 2.47 / 2.15), p95 <= 2.9 ms in the middle / at the end, 5.9 ms at the start of the document in one of three runs (baseline <= 2.8); full redraw 3.0-3.8 ms |
| Typing in non-Latin text (3 MB of Chinese / Japanese / emoji) | < 16 ms | 6.9 ms median, p95 9.3 ms, max 16.2 ms (measured at load average 4.5; Latin text 1.4 ms; not re-measured: `audit-perf-cjk` passes in the full suite) |
| Lexer throughput | >= 50 MB/s | 232-237 MB/s (MarkdownKit `lexAll`, 1 and 10 MB) |
| Memory (RSS, fresh process) | < 600 MB | 10 MB document: 149 MB after open, 163 MB after scrolling to 5 places (baseline 149 / 162); 20 MB document: 208 / 230 MB (baseline 207 / 229); empty app 74 MB |
| Memory over time | no growth | 12 open + close cycles of a 20 MB file: 163 MB flat (baseline: 142 -> 578 MB, +40 MB per cycle). A 5 MB real Markdown file appended to ~60 times by another process: 75 -> 99 MB (baseline: 71 -> 655 MB, 3.7 s of CPU instead of 2.1 s), measured on the real app through Launch Services |
| Idle CPU, 20 MB document open | ~0 | 0.03-0.04 % of a core over 3 s (about 1 ms of CPU; baseline 0.03 %); file monitor: 0 checks, no polling |
| A setting or the colour scheme changed in an open 10 MB document (change + restyle + layout + repaint of the visible part) | no freeze | text font 70-72 ms, code font 69-71, size 22 67-74, line spacing 1.9 67-68, colour scheme 68-75, column width 9, Restore Defaults 90-92 ms (the repaint is 2-6 ms of it; ~50 ms is the base attribute pass over the whole text). 1 MB: 18-23 ms (Restore Defaults 34). Three runs, `settings-perf` |
| Settings window, Theme, scheme | - | first Cmd-, 95-97 ms (183 families; both font menus in their own typefaces +33 ms), `Theme(settings:)` 0.6 ms for the first one of a process, `Palette.apply` of a scheme never built 0.35 ms, a `Palette.x` read 22 ns |
| Scrolling in a full-screen-sized window (1512 x 982 pt at 2x, 120 Hz trackpad-style steps of 60 pt, AppKit's own display of the text view, release build, load 1 - 5) | p99 < 8.3 ms (120 Hz frame) | `fix-scroll-bench`, real Markdown, two runs each, per step p50 / p99 / max, FIRST pass over fresh text (cold), then the second pass (warm): 1 MB, default fonts 0.64 - 0.70 / 4.5 - 5.4 / 6.0 - 6.9 ms cold, p99 1.6 - 1.7 warm; Fira Code 14 pt x 1.1 (the user's setup) 0.96 - 1.08 / 5.7 - 7.2 / 7.2 - 10.3 cold, p99 1.3 - 1.6 warm; serif 0.60 - 0.62 / 4.1 - 4.4 / 5.2 - 5.6 cold; 5 MB Fira 0.77 / 6.1 - 7.0 / 8.1 - 10.8 cold (3000 steps); 2056 x 1329 pt Fira 0.89 - 0.96 / 6.9 - 7.4 / 8.3 - 9.8 cold. Steps over 8.3 ms: 0 - 11 per cold run of 1500 - 3000 steps (up to 0.4 %, all computing), none in a warm run; none over 16.6 ms. The cold pass costs 2 - 3 times the warm one because about half of its steps change the document height and each of those redraws the whole visible rect (pitfall 27). Unchanged by the fixes round (`fix-scroll` guards it) |
| A slider dragged in the Settings window over a 10 MB document (150 events at 120 Hz) | no freeze | broadcasts / restyles of the 10 MB editor 80 / 80 -> 31 / 31 (visible windows), 80 / 80 -> 31 / 1 (hidden windows); one restyle of that editor costs 10 - 12 ms on this machine, so neither build stalled (longest gap between two run-loop turns 13 - 23 ms); the preview follows every event, the last value always arrives (`fix-settings-drag`) |
| Hanging indent | - | restyle of a screenful of a 1 MB document 6.05 ms (lists only 6.1-6.2; without the feature 5.97-6.04), `styledRuns` of 300 bullet lines 0.157 ms (0.095 without), keystroke in a list 1.4 ms |
| Memory over many switches | no growth | 300 colour scheme switches, each with a new Theme and a restyle: RSS +1 MB (`schemes-apply`) |
| Shipping executable | - | 1,063,232 bytes after the fixes round (1,054,480 before it; 810 KB before the three features); no test code in it (`Scripts/build-app.sh` checks) |

**After merging the fixes round and the look round** (the build that ships: current system look, SDK 27.0 stamp). Three runs of
`--selftest open-perf,typing,idle,memory,settings-perf,fix-settings-drag`, each INTERLEAVED with the fixes build (classic stamp) and with the merged source built classic (`linkerSettings`
deleted), private bundle copies, load 1.0-4.6; ranges are the three runs, classic in brackets. The look is the only difference that shows: every new document window costs ~3.5 ms more.

| Budget | Target | Merged build, current look [same source, classic stamp] |
|---|---|---|
| Open 1 MB, first screen laid out + styled + drawn | < 100 ms | **19.9-20.2 ms** warm [16.5-16.6; fixes build 16.5-16.9], 56.2-60.2 ms in a fresh process [49.0-52.5]. The difference is the window: "window+text" 12.1 vs 9.5 ms |
| Open 10 MB | < 400 ms | **24.6-25.0 ms** warm [21.2-21.5], 61.8-65.1 ms in a fresh process [54.2-57.5]; 20 MB 31.7-31.9 ms [28.1-28.6] |
| Typing, 200 KB | < 8 ms | **2.08-2.09 ms** median in the middle (p95 2.19-2.20), 2.77-2.78 at the start [2.01-2.02 / 2.69-2.70] |
| Typing, 10 MB | < 16 ms | **2.52-2.61 ms** median in the middle (p95 2.64-2.81), start 2.73-2.79 (p95 2.80-2.89), end 2.24-2.33 [2.44-2.48 / 3.05 (p95 5.3-5.7) / 2.16-2.17] |
| Idle CPU, 20 MB document open | ~0 | 0.02-0.04 % of a core [0.02-0.04] |
| Memory (RSS, fresh process) | < 600 MB | 10 MB: 154-155 MB after open, 168 after scrolling; 20 MB: 213 / 234-235; empty app 76-77 MB [150 / 164; 209 / 230; 74] |
| A setting or the colour scheme changed in an open 10 MB document | no freeze | text font 70.7-71.8 ms, size 22 67.8-68.4, line spacing 1.9 65.5-66.9, Dracula 66.7-69.0 [69.8-71.1 / 66.3-69.0 / 65.3-66.5 / 66.3-67.9]; 1 MB 17-25 ms (Restore Defaults ~32), column width 7-9 ms |
| A slider dragged over a 10 MB document (150 events at 120 Hz) | no freeze | 29-30 broadcasts and 29 restyles (one restyle 11 ms), longest gap between two run-loop turns 16 ms; hidden windows 1 restyle, gap 12-24 ms [31 / 31, 16 ms; 1, 12-23 ms] |
| First Settings window (`settings-perf`, in-process) | - | 108.3-109.0 ms [80.7-81.6] |
| First use, fresh process (`look-cost`, n = 8, medians) | - | window 55.7 ms [49.2], find bar 36.5 ms and +19.8 MB [27.5, +8.1 MB], Settings window 124.0 ms [94.8], alert 17.5 ms [23.5], banner 7.0 ms [5.8] |
| Scrolling, full-screen-sized window (`fix-scroll-bench`, two rounds in opposite order, load 0.7-2.3) | p99 < 8.3 ms | 1 MB Fira Code 14 pt x 1.1 cold p50 / p99 / max 0.99 / 5.7-7.1 / 8.3-11.0 ms, warm p99 1.6-1.8 [classic 0.86-0.87 / 6.8-7.0 / 9.7-10.5; fixes build 0.90-0.91 / 6.9-7.1 / 9.9-10.1]; 1 MB system font 0.66-0.73 / 5.3-5.4 / 6.6-7.3 [0.57-0.67 / 4.5-5.5 / 6.7-8.1]; 5 MB Fira 0.85-0.87 / 7.2-7.3 / 10.0-10.3 [0.77-0.78 / 6.8-7.0 / 10.9-11.4]; 2056 x 1329 pt Fira 1.0 / 6.7-7.0 / 9.95-10.8 [0.77-0.81 / 6.1-7.0 / 8.7-9.9]. Steps over 8.3 ms 1-7 per cold run of 1500-3000 (all three builds alike), none over 16.6 ms, none over 8.3 ms warm. The new look's scroll-edge machinery (`NSScrollPocket`) is not drawn headless, so this says nothing about it |
| Shipping executable | - | 1,063,232 bytes |

Same-load A/B against the baseline (the machine busy, load 4.5): open 1 MB 27.8 ms vs 26.7 ms (baseline), 10 MB 37-39 ms vs 55 ms, keystroke in the middle of 200 KB 4.3-4.5 ms vs 4.5-4.8 ms. The numbers of a busy machine are 1.8x those of a quiet one, which is why the self-test asserts the real keystroke against the budget and the full-redraw upper bound against 2x the budget, and why `perf-guard` skips itself when the load average is above half the core count.

`luftig-SelfTest --selftest open-perf,typing,idle,memory` prints and asserts these; `perf-guard` is the regression guard for the whole family (open / typing / scroll / jump / find / copy / paste / replace-all / autosave on synthetic corpora and eight pathological shapes, with 3x the worst quiet measurement as budget). Launch times come from a launch driver outside the repository (it checks before every launch that a window in front covers the desktop, so that nothing ever flashes on the screen); the in-process variant is `open -g -j -n -a ... --args -LuftigLaunchProbe out.json`.
Navigation cost, not a keystroke cost: the first jump into the middle of a 10 MB document takes ~65 ms (TextKit), Cmd-Down ~13 ms; non-Latin text is worse (pitfall 8).

## 6. Deviations from the spikes' recommendations

* `LazyStyler`: the provider returns (and the styler applies and records) the lexer's whole region instead of a clipped range (invariant 5); `restyleRange` became `restyleAfterEdit` returning runs + `staleFrom`; an empty viewport styles the top of the document; stale tails and composition holes are recorded in `styled`; jumps are pre-styled from the text view (`scrollRangeToVisible`, document start / end) instead of only through `LazyStyler.scroll(toCharacter:)`.
* `ViewportAnchor.restore` always runs (also when all edits are after the anchor) and iterates; `restoreSameCharacter` was added for font size changes.
* There is no idle fill of the whole document (DESIGN.md mentioned one): it would cost ~1 s of CPU and +110 MB at 20 MB for no visible benefit, since everything on screen is styled on demand. The idle self-test asserts the absence of background work.
* The "Wrap Lines" / "Show Invisibles" items of the reference menu are replaced by "Wrap to Readable Width"; "Toggle Spell Checking" has its own action (AppKit renames items wired to `toggleContinuousSpellChecking:`).
* The edited dot is set by hand (autosave in place suppresses it).
* The three features were built in parallel against the baseline and merged afterwards. Existing code changed by the merge: `Theme.init` takes `ThemeSettings` (`Theme(baseSize:)` stays); `Theme.styledRuns` / `attributes` / `LineKey` carry the head indent next to the direction; `Palette` reads the current scheme; `EditorPreferences` holds every setting; `EditorViewController` rebuilds its Theme on a settings or scheme change; `LuftigLayoutManager.bandEdge` clamps the top edge (invariant 18); the main menu has Settings... (Cmd-,). Existing tests that were adapted: `audit-shell-menu` / `menu` (the Settings item), `audit-shell-runner` (more keys), `assertMatchesFreshLex` and `AuditEd.styledMismatches` (the oracle uses the editor's own settings), the `hostile` long-path case (real path), `visual-contrast` (also runs every scheme). None was weakened.
* The fixes round (Settings layout, size field, drag coalescing, scroll measurements) and the look round (SDK 27.0 stamp) were built in parallel against the same baseline and merged
  afterwards. The only textual conflict was the registration line in `SelfTestScenarios.swift`; no code of one round touched a file of the other. Tests adapted at the merge:
  `fix-settings-drag` step 5b now says what it can and cannot show (headless, AppKit's tracking loop returns at once and leaves the queued mouse events queued - they are drained
  now; its checks are unchanged) - pitfall 30. Added: `look-settings-fixed` (the two rounds together). The editor renders of `docs/screenshots/` are the look round's (pixel-identical
  between the rounds); the Settings renders (`17-*`, `classic-look/17-*`) were made again from the merged code.
* Self-test: `open-perf` replaces the spike's scenario of the same name (its measurements - read / window / layout split, concurrent reading, stall - are included, plus styled + drawn, budgets and cold processes); the `menu` scenario's "Wrap Lines" check became the "Wrap to Readable Width" check and "handled by NSTextView" became "handled by LuftigEditorTextView". No other check was changed, weakened or removed.

## 7. What is not verified

Added by the editing round (lists, Format menu, reload behaviour, links, Typewriter Mode, scheme import, HTML / RTF / PDF exports, reading time):
* **A real ⌘-click, a real Return / Tab** reach the same code as the synthesised events the scenarios send through `NSWindow.sendEvent` / the text view's
  `mouseDown`, but no real mouse or keyboard drove them. The Open panel of Import Scheme…, the Save panel of Export as HTML… and the Finder reveal are not
  exercised (`importScheme(from:)` / `exportHTML(to:)` are driven directly).
* **Rich text in another application**: the RTF is made by `NSAttributedString(html:)` and checked for a bold face in the right place; what Mail, Pages or a chat
  make of it was not looked at. The HTML renderer follows the lexer: what the lexer leaves as text (`[shortcut]` references, reference definitions for
  footnotes) stays text; lists inside quotes work, quotes inside list items close the list first.
* **Two scenarios fail on this machine on the untouched previous commit as well** (checked by building 3ecc8f7 in a worktree): `visual-redraw` traps on a
  whole-view invalidation per edit (now read as every row, pitfall 35) and `schemes-apply` reports a long-lived window 0.5 pt wider than a fresh one and
  46 MB of growth over 300 switches. Both passed in the full run of the morning on the same build; something in the environment changed. To be rerun.
* **The RTF and PDF exports in another application**: the RTF is read back by AppKit and checked for the heading, the words and a bold face; the PDF is
  checked to be a PDF with pages. What Pages, Word or Preview make of them (tables, code blocks, quotes from the HTML importer) was not looked at.

Added by the merge of the fixes round and the look round:
* **The new look in a real window**: the title bar, the tab bar, full screen and its toolbar / title bar area, the drawing of the new scrollers and of the scroll-edge effect
  (`NSScrollPocket`), the controls of a KEY window (accent-coloured slider tracks, checkboxes, the default button; the renders show the inactive look, in which a white slider knob sits
  on the white light-mode window background), menus, the About panel. In particular, whether real full-screen scrolling is smoother or rougher under the new look: the headless
  benchmark is equal within noise for both stamps, but it does not draw the scroll pockets.
* **A real drag of the hosted slider and stepper**: whether AppKit's tracking loop still blocks inside `mouseDown` (pitfall 30). Hit testing still delivers the click to the
  control (`look-settings-fixed`). If it does not block, dragging is simply not coalesced.

Added by the fixes round (the Settings layout, the size field, dragging, scrolling):
* **The reported scroll choppiness ("in full screen mode, scrolling is sometimes very choppy and then suddenly smooth again") was NOT reproduced headless, and nothing was changed for it in this round**
  (the second report, after the rename - two-finger scrolling choppy, the knob of the scroller smooth, anywhere in the document - named the path: responsive scrolling, pitfall 31; the editor
  now opts out of it, `fix-scroll-path`. The third report - "after a while of scrolling around it suddenly works fine" - was then reproduced ON SCREEN with `fix-scroll-screen` and traced
  to the insertion point's view, pitfall 33: one override in `LuftigEditorTextView`, 0 dropped frames in a full-screen window on this display. What a hand test still has to confirm:
  a real trackpad gesture, which the measurement replaces with one clip-view scroll per display frame.)
  `fix-scroll-bench` drives the real stack in a window of the full-screen size (1512 x 982 pt at 2x, also 2056 x 1329) with trackpad-style pixel-delta scroll events at 120 Hz and times
  every step including AppKit's own display of the text view, over 100 KB - 5 MB of real Markdown, with the system fonts, a serif font and the user's setup (Fira Code, a variable font
  with ligatures, 14 pt, spacing 1.1, GitHub Dark). What it found is the SHAPE of "choppy, then smooth" at a harmless size: the first pass over text costs 2 - 3 times the second (pitfall 27:
  layout of fresh text, and a full redraw whenever TextKit revises the document height), but the first pass stays inside a 120 Hz frame at p99 (4 - 7 ms; 0 - 11 steps of 1500 - 3000, at most
  0.4 %, over 8.3 ms, none over 16.6 ms; the second pass none over 8.3 ms). A `sample` of a cold pass: the main thread is busy ~12 % of the time, drawing ~60 % of that
  (glyphs, decorations), layout ~40 % (glyph generation - a third of it the format-12 `cmap` lookup of Fira Code - and font attribute fixing), styling ~0.3 %. Styling, fonts and the hanging-indent measurer cost ~0.01 - 0.05 ms per step (the `LazyStyler` probe), so they are ruled out. Not
  measurable headless: the window server, the compositor and the display (ProMotion), a real full-screen Space, phased trackpad events and momentum (pitfall 26). Possible causes
  that remain: continuous spell checking if it is on (View > Toggle Spell Checking; `fix-scroll-bench --spell` measures it), another process loading the machine or the GPU, the
  document's own content (a very long line, pitfall 10; lots of non-Latin text, pitfall 8), a document in a File Provider folder (OneDrive / iCloud: `checkForExternalChange` does a
  `stat(2)` on the main thread on kqueue / presenter / activation events). If it happens again: during a choppy phase run `sample luftig 5 -file ~/Desktop/luftig-sample.txt` in Terminal
  (or Activity Monitor > luftig > Sample Process) and note the document, its size and folder, the display and how it was scrolled.
* **Nothing was driven with a real window server**: the scroll events have no phase (pitfall 26), the display pass is AppKit's own for a layer-backed text view in a window that is never on screen
  (backing scale set by hand), the slider drag is `SettingsSlider.mouseDown` called directly: the override opens and closes the drag and the final flush happens, but AppKit's tracking
  loop returns at once headless (pitfall 30), so whether it BLOCKS for a real drag - which the coalescing relies on, in the classic and in the new look - is not verified (if it does not,
  every drag event is broadcast at once as before: un-coalesced, never stale), "invisible window" is `isVisible` / `occlusionState` (not exercised with a real minimized window, tab or Space: `EditorViewController.visibilityOverride` stands in).

Added by the Settings / colour schemes / hanging indent work (everything here ran headless):
* **Nothing was driven with a real mouse or keyboard**: real menu tracking and popups, dragging a slider (each broadcast restyles every visible editor: 20 ms at 1 MB, 70 ms at 10 MB; since the fixes round at most one per ~40 ms during a drag, invariant 25), a real Cmd-, in a key window, the position restore of the Settings window across real launches, the real font panel (not used).
* **The caret, arrow keys and Home / End across hanging wrapped lines, live resize and trackpad scrolling in a real key window**; IME composition inside a list item; VoiceOver on the new controls and on wrapped list items.
* **The look in a real key window** (active selection and caret blink are simulated in the offscreen renders); a live toggle of Increase contrast (the self-test overrides the flag); the Settings window with Increase contrast; the macOS 26+ chrome that is outside the content view (title bar, tab bar, full screen, the drawing of the new scrollers, the controls of a key window, menus, the About panel: pitfall 13); a 1x display for the new renders (the `visual-*` pixel scenarios passed at 1x before).
* **Machines with other fonts**: this one has 183 families (6 monospaced); the Settings window and the font menus scale with the count (95 ms and +33 ms here); a saved family that exists on another machine; families whose names cannot spell themselves.
* **Launch time of the merged build** (no launch driver here; see section 5) and the first launch of the SHIPPING binary with a saved colour scheme (`settings-launch` runs the real `applicationWillFinishLaunching` in-process).

Everything the headless runs cannot see: a real input method (the IME guard is verified with `setMarkedText` / `insertText`), VoiceOver, spell checking engaging, the caret and the *active* selection colour in a key window (the active selection is simulated, `LuftigLayoutManager.simulateActiveSelection`), live resize and trackpad scrolling at 120 Hz, visible sheets / alerts / Save panels (trapped in the tests), a real Dock click while every window is minimised (`open -a` sends the same reopen event: AppKit then reports `hasVisibleWindows == true`, the delegate declines, nothing visible happens - what the Dock does on a real click was not observed), dragging to the Dock icon, Finder double-click default-handler behaviour, the Gatekeeper dialog, native Intel hardware (a `swift build --arch x86_64` build compiles and passes 9 functional scenarios under Rosetta; `build-app.sh` does not produce it), macOS versions other than 27.0.1. Quit with a dirty untitled draft and the restoration of that draft ARE covered, by `Scripts/test-lifecycle.sh`.

Added by the review round (reported, not verified, not fixed):
* **Quit (Cmd-Q) with a conflicted or deleted document that has unsaved text**: every choice of the close sheet works through `closeAllDocuments`, but AppKit's own quit review (`reviewUnsavedDocuments`) skipped invisible windows without calling `canClose`, so whether it asks with visible windows was not seen. Test by hand: edit, change the file elsewhere, press Cmd-Q. If it does not ask, `applicationShouldTerminate` should run `canClose` on documents with `syncState != .inSync && isDocumentEdited` and answer `.terminateLater`.
* **OneDrive / iCloud / Dropbox File Provider**, dataless files, `~/Library/CloudStorage`: coordinated writers are emulated with `NSFileCoordinator` from another thread (`auditdoc-coordinated`); the real providers were never touched. The 2 s poll of non-local volumes was exercised only by the forced-polling test.
* **The Open panel with a symlink**: Launch Services (`open -a`) resolves it, `NSDocumentController.openDocument(withContentsOf:)` refuses the unresolved link ("symbolic link format"); what the panel hands over is unknown. A symlink that replaces an OPEN document's file makes every save fail (NSDocument's safe save; Save As works).
* **A live toggle of "Increase contrast"** (the palette variant is chosen through a test override, the system flag is read once at start), printing / PDF, 1x displays for everything except the `visual-*` scenarios (they passed at 1x and at 2x; the rest of the suite ran at 2x), multi-colour accent beyond the seven measured values.
* **Special files** (named pipes, devices, sockets) at a document's path were never created (they hurt the machine once: a FIFO swapped for an open document wedged the file-coordination daemon): `DiskReader` opens with `O_NONBLOCK` and refuses anything that is not a regular file; `ExternalChangeMonitor.arm` still opens the path with `O_EVTONLY` without that check, which would block on a pipe.
* **Memory under a storm in the test process**: `--selftest storm` still shows `RSS +437 MB` for 45 reloads of a 5 MB file (probably the harness - a headless `NSApplication` drains its autorelease pools only when events arrive - but not proven); the real app through Launch Services grows by 24 MB under the same load.
