#if LUFTIG_SELFTEST
// SelfTestChrome.swift - the three elements around the text: outline, word count, syntax bar (EditorChrome.swift, EditorChromeViews.swift).
//   chrome-outline   the heading scanner: ATX / setext, closing #, fences, front matter, indentation, chunked == whole
//   chrome-words     the word counter: punctuation-only tokens, CJK, numbers, chunked == whole, selection
//   chrome-syntax    the syntax bar's edits: wrap / unwrap, link / image, line prefixes (toggle, numbering), rule, fence, table
//   chrome-editor    the real editor: visibility from the preferences and the View menu, outline + count of an opened document, a click on the outline,
//                    a click on the syntax bar (undoable, dirty), recomputation after typing (coalesced), a 6 MB document in steps, colours / fonts

import AppKit

extension SelfTestScenarios {
    static let chromeScenarios: [SelfTest.Scenario] = [
        .init(name: "chrome-outline", summary: "the outline scanner: ATX and setext headings, closing #, fences, front matter, indentation, chunked == whole", run: { t in try await chromeOutline(t) }),
        .init(name: "chrome-words", summary: "the word counter: punctuation-only tokens do not count, CJK per character, chunked == whole, ranges", run: { t in try await chromeWords(t) }),
        .init(name: "chrome-syntax", summary: "the syntax bar's edits: wrap / unwrap, link / image, line prefixes toggle, numbering, rule, code block, table", run: { t in try await chromeSyntax(t) }),
        .init(name: "chrome-editor", summary: "outline, word count and syntax bar in the real editor: preferences and View menu, data of an opened document, clicks, coalesced recomputation, 6 MB in steps, fonts / colours", run: { t in try await chromeEditor(t) }),
    ]

    // MARK: chrome-outline

    @MainActor static func chromeOutline(_ t: SelfTest.T) async throws {
        func h(_ text: String) -> [(Int, String, Int)] { OutlineScanner.headings(in: text as NSString).map { ($0.level, $0.title, $0.location) } }
        func eq(_ a: [(Int, String, Int)], _ b: [(Int, String, Int)], _ msg: String) {
            t.check(a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 }, "\(msg): \(a) == \(b)")
        }
        eq(h("# One\n\ntext\n\n## Two\n### Three\n#### Four\n##### Five\n###### Six\n####### not a heading\n"),
           [(1, "One", 0), (2, "Two", 13), (3, "Three", 20), (4, "Four", 30), (5, "Five", 40), (6, "Six", 51)], "ATX levels 1-6, seven # is not a heading")
        eq(h("#NoSpace\n#\n# \n   # indented three\n    # indented four\n"), [(1, "", 9), (1, "", 11), (1, "indented three", 14)], "a # needs a space; an empty heading is one; 3 spaces allowed, 4 are code")
        eq(h("# Title ##\n# Title#\n## Two ##   \n# # #\n"), [(1, "Title", 0), (1, "Title#", 11), (2, "Two", 20), (1, "#", 33)], "closing # sequences are removed only after a space")
        eq(h("Setext one\n===\n\nSetext two\n---\n\n- list\n---\n\n> quote\n---\n\n\n---\n"), [(1, "Setext one", 0), (2, "Setext two", 16)], "setext under a paragraph line only: not under a list item, a quote or a blank line")
        eq(h("para\n  ==  \nx\n=\ny\n=-\n"), [(1, "para", 0), (1, "x", 12)], "an underline may be indented and have trailing spaces, must be one character kind")
        eq(h("```\n# in fence\n```\n# out\n~~~md\n# in tilde\n~~~\n## two\n````\n```\n# still in\n````\n# three\n"), [(1, "out", 19), (2, "two", 46), (1, "three", 78)], "no headings inside ``` / ~~~ fences; a longer fence closes only with as many characters")
        eq(h("---\ntitle: x\n---\n# After\n"), [(1, "After", 17)], "front matter at the top is skipped (its closing --- is no setext underline)")
        eq(h("x\n---\ntitle: y\n---\n"), [(2, "x", 0), (2, "title: y", 6)], "a --- that is not on the first line is an ordinary underline (CommonMark: every paragraph line above one is a heading)")
        eq(h(""), [], "empty text")
        eq(h("# only\n"), [(1, "only", 0)], "one heading")
        eq(h("# crlf\r\n\r\n## two\r\n"), [(1, "crlf", 0), (2, "two", 10)], "CRLF line endings")
        eq(h("# Größe – 日本語 😀\n"), [(1, "Größe – 日本語 😀", 0)], "non-ASCII titles")
        // chunked == whole, on a corpus
        let corpus = SelfTestCorpus.markdown(bytes: 600_000, seed: 3) as NSString
        var s = OutlineScanner()
        var steps = 0
        while !s.scan(corpus, budget: 50_000) { steps += 1 }
        let whole = OutlineScanner.headings(in: corpus)
        t.check(steps >= 10, "a 600 KB corpus is scanned in steps of 50 K units (\(steps) steps)")
        t.equal(s.entries, whole, "chunked scan == whole scan (\(whole.count) headings)")
        t.check(whole.count > 50, "the corpus has headings (\(whole.count))")
        for e in whole.prefix(200) {
            let line = corpus.lineRange(for: NSRange(location: e.location, length: 0))
            t.check(line.location == e.location, "entry starts at a line start: \(e)")
        }
        // the cap
        let many = String(repeating: "# h\n", count: 6000) as NSString
        t.equal(OutlineScanner.headings(in: many).count, OutlineScanner.maxEntries, "at most \(OutlineScanner.maxEntries) entries")
        // the title length cap
        let long = ("# " + String(repeating: "x", count: 1000) + "\n") as NSString
        t.equal(OutlineScanner.headings(in: long).first?.title.utf16.count, OutlineScanner.maxTitleLength, "titles are capped at \(OutlineScanner.maxTitleLength) units")
        // speed: a 6 MB corpus
        let big = SelfTestCorpus.markdown(bytes: 6_000_000, seed: 4) as NSString
        let ms = perfMs { _ = OutlineScanner.headings(in: big) }
        t.check(ms < 400, String(format: "6 MB scanned in %.0f ms (< 400)", ms))
        var step = OutlineScanner()
        let one = perfMs { _ = step.scan(big, budget: 1_000_000) }
        t.check(one < 60, String(format: "one step of 1 M units takes %.1f ms (< 60)", one))
    }

    // MARK: chrome-words

    @MainActor static func chromeWords(_ t: SelfTest.T) async throws {
        func w(_ s: String) -> Int { WordCounter.words(in: s as NSString) }
        t.equal(w(""), 0, "empty")
        t.equal(w("one"), 1, "one")
        t.equal(w("one two  three\n\nfour\tfive"), 5, "spaces, newlines, tabs")
        t.equal(w("# Heading\n\n**bold** and _it_ and `code`\n"), 6, "markers glued to words do not add words; a lone # is not a word")
        t.equal(w("--- \n* \n- \n| | |\n```\n"), 0, "punctuation-only tokens are not words")
        t.equal(w("1. first\n2. second\n"), 4, "numbers are words")
        t.equal(w("[link](http://example.com) ![img](a.png)"), 2, "a link / image is one token each")
        t.equal(w("日本語のテキスト"), 8, "CJK: one word per character")
        t.equal(w("中文 and English 混合"), 6, "mixed CJK and Latin")
        t.equal(w("한국어 텍스트"), 6, "Hangul syllables count each")
        t.equal(w("Größe – café naïve"), 3, "accented words; a dash is not a word")
        t.equal(w("😀 👍🏽"), 2, "emoji count as words")
        t.equal(w("a\u{00A0}b\u{3000}c"), 3, "no-break and ideographic spaces separate")
        t.equal(w("don't re-use e.g."), 3, "apostrophes, hyphens and dots inside tokens")
        t.equal(WordCounter.words(in: "one two three four" as NSString, range: NSRange(location: 4, length: 9)), 2, "a range: 'two three'")
        t.equal(WordCounter.words(in: "one two three" as NSString, range: NSRange(location: 1, length: 5)), 2, "a range cutting words: 'ne tw' = 2 tokens")
        let corpus = SelfTestCorpus.markdown(bytes: 600_000, seed: 3) as NSString
        var c = WordCounter()
        var steps = 0
        while !c.scan(corpus, budget: 70_000) { steps += 1 }
        t.check(steps >= 8, "chunked in \(steps) steps")
        t.equal(c.count, WordCounter.words(in: corpus), "chunked == whole (\(c.count) words)")
        let big = SelfTestCorpus.markdown(bytes: 6_000_000, seed: 4) as NSString
        let ms = perfMs { _ = WordCounter.words(in: big) }
        t.check(ms < 300, String(format: "6 MB counted in %.0f ms (< 300)", ms))
        t.equal(WordCountView.label(total: 0, selected: nil), "0 words", "label 0")
        t.equal(WordCountView.label(total: 1, selected: nil), "1 word", "label 1")
        t.equal(WordCountView.label(total: 1234567, selected: nil).filter { $0.isNumber }, "1234567", "label grouped (locale separators)")
        t.check(WordCountView.label(total: 1234, selected: 12).hasPrefix("12 of "), "selection label: '12 of 1,234 words'")
    }

    // MARK: chrome-syntax

    @MainActor static func chromeSyntax(_ t: SelfTest.T) async throws {
        /// Apply the change to the text and return (new text, selected text, selection).
        func run(_ e: SyntaxElement, _ text: String, _ sel: NSRange) -> (String, String, NSRange) {
            let ns = text as NSString
            let c = SyntaxInsertion.change(for: e, in: ns, selection: sel)
            let out = ns.replacingCharacters(in: c.range, with: c.replacement) as NSString
            let s = NSIntersectionRange(c.selection, NSRange(location: 0, length: out.length))
            return (out as String, s.length > 0 ? out.substring(with: s) : "", c.selection)
        }
        func caret(_ text: String, _ marker: String = "|") -> (String, NSRange) {
            let ns = text as NSString
            let r = ns.range(of: marker)
            return (ns.replacingCharacters(in: r, with: ""), NSRange(location: r.location, length: 0))
        }
        func selection(_ text: String) -> (String, NSRange) {                 // [ ... ] marks the selection
            let ns = text as NSString
            let a = ns.range(of: "⟦"), b = ns.range(of: "⟧")
            let s = ns.replacingCharacters(in: b, with: "") as NSString
            return (s.replacingCharacters(in: a, with: ""), NSRange(location: a.location, length: b.location - a.location - 1))
        }
        // inline wrap
        do {
            let (txt, sel) = selection("say ⟦hello⟧ world")
            let r = run(.bold, txt, sel); t.equal(r.0, "say **hello** world", "bold wraps the selection"); t.equal(r.1, "hello", "the word stays selected")
            let r2 = run(.bold, r.0, r.2); t.equal(r2.0, "say hello world", "bold again unwraps (markers outside the selection)"); t.equal(r2.1, "hello", "still selected")
            let (t3, s3) = selection("say ⟦**hello**⟧ world")
            let r3 = run(.bold, t3, s3); t.equal(r3.0, "say hello world", "a selection that includes the markers is unwrapped")
            let (t4, s4) = caret("say | world")
            let r4 = run(.italic, t4, s4); t.equal(r4.0, "say _italic_ world", "italic at a caret inserts a placeholder"); t.equal(r4.1, "italic", "the placeholder is selected")
            let r5 = run(.code, txt, sel); t.equal(r5.0, "say `hello` world", "inline code")
            let (t6, s6) = caret("|")
            let r6 = run(.bold, t6, s6); t.equal(r6.0, "**bold**", "empty document")
        }
        // links
        do {
            let (txt, sel) = selection("see ⟦the docs⟧ now")
            let r = run(.link, txt, sel); t.equal(r.0, "see [the docs](url) now", "link around a selection"); t.equal(r.1, "url", "the url placeholder is selected")
            let (t2, s2) = selection("go ⟦https://example.com⟧")
            let r2 = run(.link, t2, s2); t.equal(r2.0, "go [text](https://example.com)", "a selected URL becomes the destination"); t.equal(r2.1, "text", "the text placeholder is selected")
            let (t3, s3) = caret("x | y")
            let r3 = run(.link, t3, s3); t.equal(r3.0, "x [text](url) y", "link at a caret"); t.equal(r3.1, "text", "text selected")
            let r4 = run(.image, txt, sel); t.equal(r4.0, "see ![the docs](url) now", "image around a selection")
            let r5 = run(.image, t3, s3); t.equal(r5.0, "x ![alt](url) y", "image at a caret"); t.equal(r5.1, "alt", "alt selected")
        }
        // line prefixes
        do {
            let (txt, sel) = caret("line one|\nline two\n")
            let r = run(.heading1, txt, sel); t.equal(r.0, "# line one\nline two\n", "H1 on the caret's line"); t.equal(r.2, NSRange(location: 10, length: 0), "the caret moved with the text")
            let r2 = run(.heading2, r.0, r.2); t.equal(r2.0, "## line one\nline two\n", "H2 replaces the level")
            let r3 = run(.heading3, r2.0, r2.2); t.equal(r3.0, "### line one\nline two\n", "H3")
            let r3b = run(.heading3, r3.0, r3.2); t.equal(r3b.0, "line one\nline two\n", "the same level again: plain")
            let (tp, sp) = selection("⟦## head\n> - [x] quoted task\n1. numbered⟧\n")
            let rp = run(.paragraph, tp, sp); t.equal(rp.0, "head\nquoted task\nnumbered\n", "¶ strips heading, quote and list markers from the selected lines")
            let (ts, ss) = selection("a ⟦gone⟧ b")
            let rs = run(.strike, ts, ss); t.equal(rs.0, "a ~~gone~~ b", "strikethrough wraps"); t.equal(run(.strike, rs.0, rs.2).0, "a gone b", "and unwraps")
            let (t4, s4) = selection("⟦a\nb⟧\nc\n")
            let r4 = run(.quote, t4, s4); t.equal(r4.0, "> a\n> b\nc\n", "quote every selected line"); t.equal(r4.1, "> a\n> b", "the lines stay selected")
            let r5 = run(.quote, r4.0, r4.2); t.equal(r5.0, "a\nb\nc\n", "quote again removes it")
            let r6 = run(.bulletList, t4, s4); t.equal(r6.0, "- a\n- b\nc\n", "bullets")
            let r7 = run(.numberedList, r6.0, r6.2); t.equal(r7.0, "1. a\n2. b\nc\n", "bullets to numbers, counted")
            let r8 = run(.task, r7.0, r7.2); t.equal(r8.0, "- [ ] a\n- [ ] b\nc\n", "numbers to tasks")
            let r9 = run(.task, r8.0, r8.2); t.equal(r9.0, "a\nb\nc\n", "tasks again: plain lines")
            let (t10, s10) = caret("- [x] done|\n")
            let r10 = run(.task, t10, s10); t.equal(r10.0, "done\n", "a checked task is a task: removed")
            let (t11, s11) = caret("  * item|\n")
            let r11 = run(.bulletList, t11, s11); t.equal(r11.0, "item\n", "an indented * item is a bullet: removed with its indent")
            let (t12, s12) = caret("|")
            let r12 = run(.bulletList, t12, s12); t.equal(r12.0, "- ", "a bullet in an empty document"); t.equal(r12.2, NSRange(location: 2, length: 0), "caret after the marker")
            let (t13, s13) = caret("1) one|\n")
            let r13 = run(.numberedList, t13, s13); t.equal(r13.0, "one\n", "1) is a number marker too")
            t.equal(SyntaxInsertion.listPrefix("- [ ]").kind, "task", "a bare task marker at the end of the line")
            t.equal(SyntaxInsertion.headingPrefix("#x").0, 0, "#x is no heading")
        }
        // blocks
        do {
            let (txt, sel) = caret("abc|def\n")
            let r = run(.rule, txt, sel); t.equal(r.0, "abc\n---\n\ndef\n", "a rule in the middle of a line gets its own line and a blank line after"); t.equal(r.2, NSRange(location: 8, length: 0), "caret after the rule")
            let (t2, s2) = caret("abc\n|def\n")
            let r2 = run(.rule, t2, s2); t.equal(r2.0, "abc\n---\n\ndef\n", "at a line start: no extra newline before")
            let (t3, s3) = caret("abc\n|")
            let r3 = run(.rule, t3, s3); t.equal(r3.0, "abc\n---\n", "at the end of the text")
            let (t4, s4) = caret("abc\n|")
            let r4 = run(.fence, t4, s4); t.equal(r4.0, "abc\n```\n\n```\n", "an empty code block"); t.equal(r4.2, NSRange(location: 8, length: 0), "caret on the empty line inside")
            let (t5, s5) = selection("x\n⟦let a = 1\nlet b = 2⟧\ny\n")
            let r5 = run(.fence, t5, s5); t.equal(r5.0, "x\n```\nlet a = 1\nlet b = 2\n```\ny\n", "selected lines become a code block"); t.equal(r5.1, "let a = 1\nlet b = 2", "the code stays selected")
            let (t6, s6) = caret("p\n|")
            let r6 = run(.table, t6, s6); t.equal(r6.0, "p\n| Column | Column |\n| --- | --- |\n|  |  |\n", "a table skeleton"); t.equal(r6.1, "Column", "the first header cell is selected")
        }
        // nothing crashes for any element on odd selections
        for e in SyntaxElement.allCases {
            for (text, sel) in [("", NSRange(location: 0, length: 0)), ("x", NSRange(location: 5, length: 0)), ("abc", NSRange(location: 1, length: 9)), ("a\r\nb\r\n", NSRange(location: 0, length: 6)), ("日本語", NSRange(location: 1, length: 1))] {
                let c = SyntaxInsertion.change(for: e, in: text as NSString, selection: sel)
                t.check(NSMaxRange(c.range) <= (text as NSString).length, "\(e) on \(text.debugDescription) \(NSStringFromRange(sel)): the range is inside the text")
            }
        }
    }

    // MARK: chrome-editor

    @MainActor static func chromeEditor(_ t: SelfTest.T) async throws {
        try await preservingSettings {
            let ud = UserDefaults.standard
            for k in [EditorPreferences.showOutlineKey, EditorPreferences.showWordCountKey, EditorPreferences.showSyntaxBarKey] { ud.removeObject(forKey: k) }
            t.check(EditorPreferences.showOutline && EditorPreferences.showWordCount && EditorPreferences.showSyntaxBar, "all three on by default")
            ud.set("yes", forKey: EditorPreferences.showOutlineKey)
            t.check(EditorPreferences.showOutline, "a string in the defaults reads as the default")
            ud.removeObject(forKey: EditorPreferences.showOutlineKey)

            let filler = String(repeating: "filler line of prose that goes on\n\n", count: 30)
            let text = "# Alpha\n\nfirst paragraph with five words\n\n" + filler + "## Beta\n\n- one\n- two\n\n```\n# not a heading\n```\n\n" + filler + "### Gamma\n\nlast words here\n" + filler
            let (doc, host, _) = try await openEditor(t, text: text, name: "chrome.md", size: NSSize(width: 900, height: 600))
            defer { t.close(doc) }
            let tv = host.textView
            t.check(!host.outline.isHidden && !host.wordCount.isHidden && !host.syntaxBar.isHidden, "the three elements are shown")
            t.check(host.view is EditorRootView, "the root view paints the page colour")
            host.view.layoutSubtreeIfNeeded()
            func inRoot(_ v: NSView) -> NSRect { host.view.convert(v.bounds, from: v) }       // (the views sit in nested stacks; the window's coordinates are not flipped)
            let textFrame = inRoot(host.scrollView)
            t.check(inRoot(host.outline).width == OutlineView.width && inRoot(host.outline).minX == 0, "the outline is on the left, \(OutlineView.width) pt wide: \(NSStringFromRect(inRoot(host.outline)))")
            t.check(textFrame.minX >= OutlineView.width - 0.5, "the text starts right of the outline: \(NSStringFromRect(textFrame))")
            t.check(inRoot(host.wordCount).minY >= textFrame.maxY - 0.5 && inRoot(host.wordCount).height == WordCountView.height, "the word count row is above the text: \(NSStringFromRect(inRoot(host.wordCount))) vs \(NSStringFromRect(textFrame))")
            t.check(inRoot(host.syntaxBar).maxY <= textFrame.minY + 0.5 && inRoot(host.syntaxBar).height == SyntaxBarView.height, "the syntax bar is below the text: \(NSStringFromRect(inRoot(host.syntaxBar)))")
            // a small document: the data is there at open (no wait); a big one computes after the first screen (below)
            t.check(!host.chromeRefreshPending && host.outline.entries.count == 3, "a small document's outline and count are computed at open, synchronously")
            var waited = 0.0
            while host.chromeRefreshPending && waited < 3000 { await t.spin(20); waited += 20 }
            t.check(!host.chromeRefreshPending, "outline and count computed after the open (\(waited) ms)")
            t.equal(host.outline.entries.map { "\($0.level):\($0.title)" }, ["1:Alpha", "2:Beta", "3:Gamma"], "the outline lists the three headings (not the one in the fence)")
            t.equal(host.wordCount.text, "\(WordCounter.words(in: text as NSString)) words", "the word count shows the document's words")
            t.equal(host.outline.currentIndex, 0, "the window is at the top: the first section is current")
            t.equal(host.outline.table.numberOfRows, 3, "the table shows three rows")
            // colours and fonts
            let cell = host.outline.table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTextField
            let app = host.view.effectiveAppearance
            t.check(cell?.textColor == ChromeStyle.dim(for: app), "an outline entry is drawn in the dim marker colour")
            let current = host.outline.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField
            t.check(current?.textColor == ChromeStyle.strong(for: app), "the current section in the text colour")
            t.check(host.wordCount.field.textColor == ChromeStyle.dim(for: app), "the word count in the dim colour")
            t.check(host.syntaxBar.labels[.bold]?.field.textColor == ChromeStyle.dim(for: app) && host.syntaxBar.labels[.link]?.imageView.contentTintColor == ChromeStyle.dim(for: app), "the syntax bar in the dim colour (text faces and symbols)")
            t.check(host.syntaxBar.labels.count == SyntaxElement.allCases.count && host.syntaxBar.stack.arrangedSubviews.count == SyntaxElement.groups.count, "every element has a label, in \(SyntaxElement.groups.count) groups")
            t.check(host.syntaxBar.labels.values.allSatisfy { !($0.field.toolTip ?? $0.toolTip ?? "").isEmpty || !($0.toolTip ?? "").isEmpty }, "every label has a tooltip")
            t.equal(cell?.font?.pointSize, ChromeStyle.fontSize, "12 pt")
            EditorPreferences.bodyFontFamily = anyFamily()
            await t.spin(10)
            t.equal((host.outline.table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTextField)?.font?.familyName, host.theme.bodyFamily ?? NSFont.systemFont(ofSize: 12).familyName, "the outline follows the text font of the Settings")
            EditorPreferences.bodyFontFamily = nil
            // a dark scheme: the colours follow
            EditorPreferences.colorSchemeID = "dracula"
            await t.spin(10)
            t.check(host.wordCount.field.textColor == ChromeStyle.dim(for: host.view.effectiveAppearance), "after a scheme change the word count uses the scheme's marker colour")
            EditorPreferences.colorSchemeID = ColorSchemes.defaultID
            await t.spin(10)

            // a click on the outline: the heading at the top of the window, the caret on it
            host.outline.click(row: 2)
            let gamma = (text as NSString).range(of: "### Gamma").location
            t.equal(tv.selectedRange().location, gamma, "the caret is on the clicked heading")
            let vis = host.styler.visibleCharacterRange(tv)
            t.check(vis.location <= gamma && NSMaxRange(vis) > gamma, "the heading is visible: \(NSStringFromRange(vis))")
            t.check(abs(tv.visibleRect.minY - (tv.layoutManager!.lineFragmentRect(forGlyphAt: tv.layoutManager!.glyphIndexForCharacter(at: gamma), effectiveRange: nil).minY + tv.textContainerOrigin.y - 20)) < 1 || tv.visibleRect.minY >= tv.frame.height - tv.visibleRect.height - 1, "the heading line is at the top of the window (or the document end is reached)")
            await t.spin(10)
            t.equal(host.outline.currentIndex, 2, "the clicked section is current")

            // the syntax bar: an undoable edit that marks the document dirty and is restyled
            tv.setSelectedRange(NSRange(location: (text as NSString).range(of: "five").location, length: 4))
            host.syntaxBar.click(.bold)
            t.check((tv.string as NSString).contains("with **five** words"), "bold around the selection: \(tv.string.prefix(60).debugDescription)")
            t.equal(tv.selectedRange(), NSRange(location: (tv.string as NSString).range(of: "five").location, length: 4), "the word stays selected")
            await t.spin(5)                                                         // (NSDocument learns of the change from the undo manager's notifications)
            t.check(doc.isDocumentEdited, "the document is dirty")
            tv.undoManager?.undo()
            t.check(tv.string == text, "undo removes the bold")
            tv.undoManager?.redo()
            t.check((tv.string as NSString).contains("**five**"), "redo")
            await t.spin(5)
            assertMatchesFreshLex(t, host, "after the syntax bar edit the styling is a fresh lex")
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            host.syntaxBar.click(.heading2)
            t.check(tv.string.hasPrefix("## Alpha"), "H2 on the first line: level 2 now")
            tv.undoManager?.undo(); tv.undoManager?.undo()
            t.check(tv.string == text, "two undos: back to the start")
            // the panes' own settings: font family, size, opacity reach the three elements
            EditorPreferences.paneFontSize = 16
            await t.spin(10)
            t.equal((host.outline.table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTextField)?.font?.pointSize, 16, "panes size 16: the outline follows")
            t.equal(host.wordCount.field.font?.pointSize, 16, "... the word count too")
            t.equal(host.syntaxBar.labels[.bold]?.field.font?.pointSize, 16, "... and the syntax bar's text faces")
            t.check(host.syntaxBar.labels[.link]?.imageView.image != nil && host.syntaxBar.labels[.bold]?.field.attributedStringValue.string == "B", "the bar shows results: a link symbol, a bold B")
            EditorPreferences.paneFontFamily = anyFamily()
            await t.spin(10)
            t.equal(host.wordCount.field.font?.familyName, FontFactory.resolve(EditorPreferences.paneFontFamily) ?? NSFont.systemFont(ofSize: 12).familyName, "panes font: the word count uses the chosen family")
            EditorPreferences.paneOpacity = 0.5
            await t.spin(10)
            t.check(abs((host.wordCount.field.textColor?.alphaComponent ?? 1) - 0.5) < 0.01, "panes opacity 50 %: the colour's alpha follows (\(host.wordCount.field.textColor?.alphaComponent ?? -1))")
            EditorPreferences.paneOpacity = 1; EditorPreferences.paneFontFamily = nil; EditorPreferences.paneFontSize = 12
            await t.spin(10)
            t.check(abs((host.wordCount.field.textColor?.alphaComponent ?? 0) - 1) < 0.01 && host.wordCount.field.font?.pointSize == 12, "back to the defaults")
            // Settings > Panes > Outline: wrap long headings
            let longTitle = "A heading that is far too long to fit into the outline column in one line of text"
            t.typeText("\n\n## " + longTitle + "\n", into: doc, at: NSRange(location: (tv.string as NSString).length, length: 0))
            waited = 0
            while host.chromeRefreshPending && waited < 3000 { await t.spin(20); waited += 20 }
            let lastRow = host.outline.entries.count - 1
            t.equal(host.outline.entries.last?.title, longTitle, "the long heading is in the outline")
            let single = host.outline.table.rowHeight
            t.check(host.outline.table.rect(ofRow: lastRow).height == single, "without wrapping the long heading has the single-line row height (\(single) pt)")
            t.check((host.outline.table.view(atColumn: 0, row: lastRow, makeIfNecessary: true) as? NSTextField)?.lineBreakMode == .byTruncatingTail, "... and is truncated")
            EditorPreferences.outlineWraps = true
            await t.spin(10)
            let wrapped = host.outline.table.rect(ofRow: lastRow).height
            t.check(wrapped >= single * 2 - 2, "Wrap long headings: the row grows to hold the lines (\(wrapped) pt vs \(single))")
            t.check((host.outline.table.view(atColumn: 0, row: lastRow, makeIfNecessary: true) as? NSTextField)?.lineBreakMode == .byWordWrapping, "... and the cell wraps by words")
            t.check(host.outline.table.rect(ofRow: 0).height == single, "a short heading keeps the single-line height")
            EditorPreferences.outlineWraps = false
            await t.spin(10)
            t.check(host.outline.table.rect(ofRow: lastRow).height == single, "off again: single-line rows")
            // Settings > General > Padding: one factor for the text's insets and the panes' margins and heights
            t.equal(Padding(factor: 1).textInsetHorizontal, 28, "padding 1: the text's horizontal inset is the 28 pt it always was")
            t.equal(Padding(factor: 1).textInsetVertical, 20, "padding 1: vertical inset 20 pt")
            t.equal(Padding(factor: 1).barHeight, 40, "padding 1: the bar is 40 pt")
            t.check(Padding(factor: 0.5).textInsetHorizontal >= DecorationMetrics.bandOutset + 4, "padding 0.5: the horizontal inset keeps room for the bands")
            let rowBefore = host.outline.table.rect(ofRow: 0).height
            let containerBefore = tv.textContainer!.size.width
            EditorPreferences.padding = 2
            await t.spin(10)
            host.view.layoutSubtreeIfNeeded()
            t.equal(tv.textContainerInset.height, 40, "padding 2: the text's vertical inset doubles")
            t.equal(host.outline.table.rect(ofRow: 0).height, rowBefore, "padding 2: the outline's row height does NOT change (it has a slider of its own)")
            t.check(tv.textContainer!.size.width < containerBefore, "padding 2: the text container is narrower (left inset and the right extra both grew: \(Int(containerBefore)) -> \(Int(tv.textContainer!.size.width)) pt)")
            t.check(abs(Double(tv.textContainerInset.width + tv.textContainer!.size.width + host.padding.textTrailingExtra + tv.textContainerInset.width) - Double(tv.frame.width)) < 1.5, "padding 2: inset + container + inset + extra = the text view's width (the extra air is on the right)")
            t.equal(inRoot(host.syntaxBar).height, 80, "padding 2: the syntax bar is 80 pt tall")
            t.equal(inRoot(host.wordCount).height, 44, "padding 2: the word count row is 44 pt")
            t.equal(host.outline.scroll.contentInsets.top, 40, "padding 2: the outline's top inset is 40 pt")
            EditorPreferences.padding = 0.5
            await t.spin(10)
            host.view.layoutSubtreeIfNeeded()
            t.equal(tv.textContainerInset.height, 10, "padding 0.5: vertical inset 10 pt")
            t.equal(inRoot(host.syntaxBar).height, 24, "padding 0.5: the bar keeps its minimum of 24 pt")
            EditorPreferences.padding = 1
            await t.spin(10)
            host.view.layoutSubtreeIfNeeded()
            t.equal(tv.textContainerInset.height, 20, "padding 1 again: 20 pt")
            t.equal(EditorPreferences.padding, 1, "the factor reads back as 1")
            EditorPreferences.padding = 1.337
            t.equal(EditorPreferences.padding, 1.35, "the factor is stored in steps of 0.05")
            EditorPreferences.padding = 1
            // Settings > Layout > Outline spacing: the row height as a multiple of the font's height
            let fontH = (host.outline.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)?.font.map { $0.ascender - $0.descender } ?? 14
            t.equal(host.outline.table.rect(ofRow: 0).height, ceil(fontH * 1.4), "outline spacing 1.4 (default): row height = 1.4 x the font's height")
            EditorPreferences.outlineLineHeight = 2
            await t.spin(10)
            t.equal(host.outline.table.rect(ofRow: 0).height, ceil(fontH * 2), "outline spacing 2: twice the font's height")
            EditorPreferences.outlineLineHeight = 1
            await t.spin(10)
            t.equal(host.outline.table.rect(ofRow: 0).height, ceil(fontH), "outline spacing 1: the font's height, no air")
            EditorPreferences.outlineLineHeight = EditorPreferences.defaultOutlineLineHeight
            await t.spin(10)
            t.equal(host.outline.table.rect(ofRow: 0).height, rowBefore, "back to the default")
            // Settings > General > Open files in tabs: the windows' tabbing mode follows, never the system's "Prefer tabs" (.automatic)
            t.check(!EditorPreferences.openInTabs && doc.windowControllers.first?.window?.tabbingMode == .disallowed, "default: windows of their own (tabbing disallowed)")
            EditorPreferences.openInTabs = true
            t.check(doc.windowControllers.first?.window?.tabbingMode == .preferred, "Open files in tabs: the open window prefers tabs")
            let (doc4, _, _) = try await openEditor(t, text: "# t\n", name: "tabs.md")
            t.check(doc4.windowControllers.first?.window?.tabbingMode == .preferred, "... and a new one too")
            t.close(doc4)
            EditorPreferences.openInTabs = false
            t.check(doc.windowControllers.first?.window?.tabbingMode == .disallowed, "off again: disallowed")

            // typing: recomputed once, after the pause
            let before = host.chromeRefreshCount
            t.typeText("\n\n#### Delta\n", into: doc, at: NSRange(location: (tv.string as NSString).length, length: 0))
            t.check(host.chromeRefreshCount == before, "nothing is recomputed on the keystrokes themselves")
            waited = 0
            while host.chromeRefreshPending && waited < 3000 { await t.spin(20); waited += 20 }
            t.equal(host.chromeRefreshCount, before + 1, "recomputed once after the pause (\(waited) ms)")
            t.equal(host.outline.entries.last?.title, "Delta", "the new heading is in the outline")
            t.check(host.wordCount.text.hasPrefix("\(WordCounter.words(in: tv.string as NSString)) "), "the count follows: \(host.wordCount.text)")
            // a selection shows its own count
            tv.setSelectedRange(NSRange(location: 0, length: 7))
            t.check(host.wordCount.text.hasPrefix("1 of "), "a selection: '1 of N words': \(host.wordCount.text)")
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            t.check(!host.wordCount.text.contains(" of "), "no selection: the total again")

            // the View menu: three toggles, titles flip, every window follows
            let item = NSMenuItem(title: "Show Outline", action: #selector(LuftigEditorActions.luftigToggleOutline(_:)), keyEquivalent: "")
            _ = host.validateMenuItem(item)
            t.equal(item.title, "Hide Outline", "the menu says Hide while the outline is shown")
            host.luftigToggleOutline(nil)
            t.check(host.outline.isHidden && !EditorPreferences.showOutline, "View > Hide Outline hides it and stores it")
            host.view.layoutSubtreeIfNeeded()
            t.check(inRoot(host.scrollView).minX < 1, "the text takes the outline's place")
            _ = host.validateMenuItem(item)
            t.equal(item.title, "Show Outline", "the title flips back")
            host.luftigToggleWordCount(nil); host.luftigToggleSyntaxBar(nil)
            host.view.layoutSubtreeIfNeeded()
            t.check(host.wordCount.isHidden && host.syntaxBar.isHidden, "word count and syntax bar hidden")
            t.check(abs(inRoot(host.scrollView).height - host.view.bounds.height) < 1, "with everything hidden the text fills the window")
            let (doc2, host2, _) = try await openEditor(t, text: "# x\n", name: "chrome2.md")
            t.check(host2.outline.isHidden && host2.wordCount.isHidden && host2.syntaxBar.isHidden, "a window opened later follows the stored switches")
            host.luftigToggleOutline(nil)
            t.check(!host2.outline.isHidden, "a toggle in one window reaches the other")
            waited = 0
            while host2.chromeRefreshPending && waited < 3000 { await t.spin(20); waited += 20 }
            t.equal(host2.outline.entries.count, 1, "an outline that was hidden at open is computed when shown")
            host.luftigToggleWordCount(nil); host.luftigToggleSyntaxBar(nil)
            t.close(doc2)

            // a big document: computed in steps, never a long stall
            let big = t.corpusFile(bytes: 6_000_000, seed: 4)
            let doc3 = try await t.open(big, size: NSSize(width: 900, height: 700))
            guard let host3 = doc3.host as? EditorViewController else { return }
            var longest = 0.0, turns = 0
            waited = 0
            while host3.chromeRefreshPending && waited < 15000 {
                let a = SelfTest.nowMs()
                await t.spin(1)
                let d = SelfTest.nowMs() - a
                longest = max(longest, d); turns += 1; waited += d
            }
            t.check(!host3.chromeRefreshPending, "6 MB: outline and count computed (\(Int(waited)) ms, \(turns) turns)")
            t.check(longest < 120, String(format: "6 MB: the longest wait of the run loop while computing was %.0f ms (< 120: the work comes in steps)", longest))
            let expected = OutlineScanner.headings(in: host3.textView.string as NSString)
            t.equal(host3.outline.entries.count, expected.count, "6 MB: \(expected.count) headings")
            t.check(host3.wordCount.text.hasPrefix("\(WordCounter.words(in: host3.textView.string as NSString)) ".replacingOccurrences(of: " ", with: "")) || host3.wordCount.text.filter { $0.isNumber } == "\(WordCounter.words(in: host3.textView.string as NSString))", "6 MB: the count is right: \(host3.wordCount.text)")
            // a keystroke in the big document while a scan runs: the scan restarts, the keystroke is not slowed
            host3.textView.setSelectedRange(NSRange(location: 0, length: 0))
            let k = perfMs { t.typeText("x", into: doc3, at: NSRange(location: 0, length: 0)) }
            t.check(k < 50, String(format: "a keystroke in 6 MB with the chrome: %.1f ms", k))
            t.close(doc3)
        }
    }
}
#endif
