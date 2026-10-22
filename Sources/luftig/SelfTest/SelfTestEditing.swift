#if LUFTIG_SELFTEST
// SelfTestEditing.swift - editing helpers: list continuation (ListEditing.swift) and the Format menu's shortcuts.
//   edit-lists         the pure logic: Return continues bullets, numbers (renumbering the sequence below), tasks and quotes; an empty item is
//                      outdented or loses its marker; Tab / Shift-Tab nest and un-nest items and renumber the moved item; nothing else changes
//   edit-lists-editor  the real editor: Return / Tab / Shift-Tab key events, undo as one step, the switch in Settings > General, no effect in a code block
//                      or during an IME composition

import AppKit
import MarkdownKit

extension SelfTestScenarios {
    static let editingScenarios: [SelfTest.Scenario] = [
        .init(name: "edit-lists", summary: "list continuation (pure): Return on bullets / numbers / tasks / quotes, empty items, Tab and Shift-Tab, renumbering", run: { t in try await editLists(t) }),
        .init(name: "edit-lists-editor", summary: "list continuation in the real editor: Return / Tab / Shift-Tab key events, one undo step, the Settings switch, code blocks and IME untouched", run: { t in try await editListsEditor(t) }),
        .init(name: "edit-caret", summary: "the insertion point is as tall as the font at the caret (ascent + descent, on the baseline), not the line box: body, heading and the extra line after a final line break", run: { t in try await editCaret(t) }),
        .init(name: "edit-scroll-stability", summary: "typing and Backspace in the middle of a long document keep the caret's line where it is on screen (no drift, no jump): characters, Backspace, a joined and a split paragraph, a long line", run: { t in try await editScrollStability(t) }),
        .init(name: "edit-format-menu", summary: "the Format menu: one item per syntax bar element with a unique shortcut, the same edit as a click on the bar, tooltips name the shortcut, disabled without an editor", run: { t in try await editFormatMenu(t) }),
        .init(name: "edit-links", summary: "⌘-click / Edit > Open Link: the link under a character (inline, image, autolink, bare URL, reference), web / file / anchor targets, a real ⌘-click, a Markdown file opens in luftig at its anchor", run: { t in try await editLinks(t) }),
        .init(name: "edit-typewriter", summary: "View > Typewriter Mode: the caret's line in the middle, the inset makes room, remembered, every window follows", run: { t in try await editTypewriter(t) }),
        .init(name: "edit-html", summary: "Markdown -> HTML from the lexer's runs: headings, emphasis, code, links / images / autolinks / references, lists (nested, numbered, tasks), quotes, tables, rules, breaks; Copy as HTML / Rich Text on a private pasteboard; Export as HTML", run: { t in try await editHTML(t) }),
        .init(name: "html-probe", summary: "(probe) prints the HTML of --input f.md (or a built-in sample)", run: { t in try await htmlProbe(t) }, inAll: false),
    ]

    // MARK: html

    static let htmlSample = """
    ---
    title: front matter
    ---
    # Title with *emphasis*

    A paragraph with **bold**, _italic_, ~~struck~~, `code`, a [link](https://example.org "T") and an ![image](pic.png "alt title").
    Autolinks: <https://auto.link>, www.bare.com, mail me@example.org, and a \\* escape &amp; entity.
    Two spaces at the end
    make a break, a backslash\\
    too.

    Setext heading
    --------------

    - one
    - two **bold**
      - nested
        1. deep
        2. deeper
    - [ ] task
    - [x] done

    1. first
    2. second

       a second paragraph in the item

    > quoted *text*
    > > deeper
    > back

    ```swift
    let x = 1 < 2
    ```

        indented code

    | a | b |
    |:--|--:|
    | 1 | **2** |

    ---

    [ref]: https://ref.example
    A [reference][ref] and a [shortcut] and a footnote[^1].

    [shortcut]: https://short.example
    <div class="raw">html block</div>
    Inline <em>html</em> stays.
    """

    @MainActor static func htmlProbe(_ t: SelfTest.T) async throws {
        var text = htmlSample
        if let input = SelfTest.argument("input"), let s = try? String(contentsOfFile: input, encoding: .utf8) { text = s }
        let ns = text as NSString
        let html = MarkdownHTML.html(ns, runs: MarkdownStyler().lexAll(ns))
        out(html)
        t.check(true, "\(html.utf8.count) bytes of HTML")
    }

    @MainActor static func editHTML(_ t: SelfTest.T) async throws {
        let styler = MarkdownStyler()
        func h(_ md: String) -> String { let ns = md as NSString; return MarkdownHTML.html(ns, runs: styler.lexAll(ns)) }
        t.equal(h("# Title\n"), "<h1>Title</h1>\n", "an ATX heading")
        t.equal(h("Setext\n======\n"), "<h1>Setext</h1>\n", "a setext heading (the underline shows nothing)")
        t.equal(h("## With *em* and `code` ##\n"), "<h2>With <em>em</em> and <code>code</code></h2>\n", "inline markup in a heading, closing hashes gone")
        t.equal(h("plain words\nsecond line\n\nnext para\n"), "<p>plain words\nsecond line</p>\n<p>next para</p>\n", "paragraphs: lines joined, blank lines separate")
        t.equal(h("**bold** _it_ ~~del~~ `a<b`\n"), "<p><strong>bold</strong> <em>it</em> <del>del</del> <code>a&lt;b</code></p>\n", "bold, italic, strikethrough, code (escaped)")
        t.equal(h("**bold _both_ bold**\n"), "<p><strong>bold <em>both</em> bold</strong></p>\n", "nested emphasis nests its tags")
        t.equal(h("[text](https://x.org \"T\") and ![alt](pic.png \"t\")\n"), "<p><a href=\"https://x.org\">text</a> and <img src=\"pic.png\" alt=\"alt\" title=\"t\"></p>\n", "a link and an image")
        t.equal(h("<https://a.b> www.c.d <me@e.f>\n"), "<p><a href=\"https://a.b\">https://a.b</a> <a href=\"https://www.c.d\">www.c.d</a> <a href=\"mailto:me@e.f\">me@e.f</a></p>\n", "autolinks: angle brackets, www, mail")
        t.equal(h("[r][ref]\n\n[ref]: https://r.e\n"), "<p><a href=\"https://r.e\">r</a></p>\n", "a reference link through its definition; the definition line shows nothing")
        t.equal(h("a \\* star &amp; entity\n"), "<p>a * star &amp; entity</p>\n", "a backslash escape loses its backslash, an entity stays")
        t.equal(h("two  \nlines\\\nthree\n"), "<p>two<br>\nlines<br>\nthree</p>\n", "hard breaks: two spaces, a backslash")
        t.equal(h("- one\n- two\n"), "<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n", "a bulleted list")
        t.equal(h("1. one\n2. two\n"), "<ol>\n<li>one</li>\n<li>two</li>\n</ol>\n", "a numbered list")
        t.equal(h("3. three\n4. four\n"), "<ol start=\"3\">\n<li>three</li>\n<li>four</li>\n</ol>\n", "a list that starts at 3")
        t.equal(h("- one\n  - nested\n  - again\n- two\n"), "<ul>\n<li>one\n<ul>\n<li>nested</li>\n<li>again</li>\n</ul>\n</li>\n<li>two</li>\n</ul>\n", "a nested list closes before the next outer item")
        t.equal(h("- [ ] open\n- [x] done\n"), "<ul class=\"task\">\n<li class=\"task\"><input type=\"checkbox\" disabled> open</li>\n<li class=\"task\"><input type=\"checkbox\" disabled checked> done</li>\n</ul>\n", "tasks")
        t.equal(h("- item\n  continued\n- next\n"), "<ul>\n<li>item\ncontinued</li>\n<li>next</li>\n</ul>\n", "an indented continuation line belongs to the item")
        t.equal(h("1. item\n\n   second paragraph\n2. next\n"), "<ol>\n<li>item\n<p>second paragraph</p>\n</li>\n<li>next</li>\n</ol>\n", "a second paragraph inside an item")
        t.equal(h("- item\n\nparagraph\n"), "<ul>\n<li>item</li>\n</ul>\n<p>paragraph</p>\n", "a blank line and an unindented line end the list")
        t.equal(h("> quote *em*\n> more\n"), "<blockquote>\n<p>quote <em>em</em>\nmore</p>\n</blockquote>\n", "a block quote")
        t.equal(h("> one\n> > two\n> one again\n"), "<blockquote>\n<p>one</p>\n<blockquote>\n<p>two\none again</p>\n</blockquote>\n</blockquote>\n", "nested quotes (the last line continues the inner paragraph lazily, as CommonMark says)")
        t.equal(h("> one\n> > two\n>\n> back\n"), "<blockquote>\n<p>one</p>\n<blockquote>\n<p>two</p>\n</blockquote>\n<p>back</p>\n</blockquote>\n", "... a blank quote line ends the inner quote")
        t.equal(h("> - a\n> - b\n"), "<blockquote>\n<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n</blockquote>\n", "a list inside a quote")
        t.equal(h("```swift\nlet x = 1 < 2\n```\n"), "<pre><code class=\"language-swift\">let x = 1 &lt; 2\n</code></pre>\n", "a fenced code block with its language, escaped")
        t.equal(h("~~~\n# not a heading\n~~~\n"), "<pre><code># not a heading\n</code></pre>\n", "a tilde fence")
        t.equal(h("    indented\n    code\n\nafter\n"), "<pre><code>indented\ncode\n</code></pre>\n<p>after</p>\n", "indented code")
        t.equal(h("| a | b |\n|:--|--:|\n| 1 | **2** |\n"), "<table>\n<thead>\n<tr><th align=\"left\">a</th><th align=\"right\">b</th></tr>\n</thead>\n<tbody>\n<tr><td align=\"left\">1</td><td align=\"right\"><strong>2</strong></td></tr>\n</tbody>\n</table>\n", "a table with alignments")
        t.equal(h("a\n\n---\n\nb\n"), "<p>a</p>\n<hr>\n<p>b</p>\n", "a rule")
        t.equal(h("---\ntitle: x\n---\n# After\n"), "<h1>After</h1>\n", "front matter shows nothing")
        t.equal(h("<div class=\"raw\">html</div>\n"), "<div class=\"raw\">html</div>\n", "an HTML block is passed through")
        t.equal(h("Inline <em>html</em> stays <br/> & more\n"), "<p>Inline <em>html</em> stays <br/> &amp; more</p>\n", "inline HTML passes, a bare ampersand is escaped")
        t.equal(h("a footnote[^1] here\n\n[^1]: the note\n"), "<p>a footnote<sup>1</sup> here</p>\n<p><sup>1</sup> the note</p>\n", "footnote references and definitions as superscripts")
        t.equal(h("\"quotes\" & 1 < 2 > 0\n"), "<p>&quot;quotes&quot; &amp; 1 &lt; 2 &gt; 0</p>\n", "text is escaped (a real tag such as <tags> is inline HTML and passes)")
        t.equal(h(""), "", "empty text")
        t.equal(h("CRLF\r\nlines\r\n"), "<p>CRLF\nlines</p>\n", "CRLF text")
        // a range: whole lines around it
        let doc = "# T\n\npara one\n\n- a\n- b\n\nlast\n" as NSString
        let runs = styler.lexAll(doc)
        t.equal(MarkdownHTML.html(doc, runs: runs, range: doc.range(of: "a\n- b")), "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n", "a selection renders its whole lines")
        // the page
        let page = MarkdownHTML.document(body: "<p>x</p>\n", title: "A <b> title", bodyFont: "Georgia", codeFont: nil)
        t.check(page.hasPrefix("<!DOCTYPE html>") && page.contains("<title>A &lt;b&gt; title</title>") && page.contains("\"Georgia\", -apple-system") && page.contains("ui-monospace") && page.contains("<p>x</p>") && page.contains("prefers-color-scheme: dark"), "the page: a doctype, the escaped title, the fonts, the body, a dark stylesheet")
        // the sample as a whole: well-formed enough to parse as XML-ish (every opened tag closed): count a few pairs
        let sample = h(htmlSample)
        for tag in ["ul", "ol", "li", "blockquote", "p", "strong", "em", "table", "pre", "code", "a", "h1", "h2"] {
            let opened = sample.components(separatedBy: "<\(tag)>").count - 1 + sample.components(separatedBy: "<\(tag) ").count - 1
            t.check(opened == sample.components(separatedBy: "</\(tag)>").count - 1, "the sample: every <\(tag)> is closed (\(opened))")
        }
        // the editor: Copy as HTML / Copy as Rich Text on a private pasteboard, Export as HTML
        let (document, host, _) = try await openEditor(t, text: "# Head\n\nsome **bold** text\n\n- a\n", name: "html.md")
        defer { t.close(document) }
        let tv = host.textView
        let pb = AuditEd.privatePasteboard()
        host.copyAsHTML(to: pb)
        t.equal(pb.string(forType: .html), "<h1>Head</h1>\n<p>some <strong>bold</strong> text</p>\n<ul>\n<li>a</li>\n</ul>\n", "Copy as HTML without a selection: the whole document as HTML")
        t.equal(pb.string(forType: .string), pb.string(forType: .html), "... also as plain text (so a text editor gets the source)")
        tv.setSelectedRange((tv.string as NSString).range(of: "bold"))
        host.copyAsHTML(to: pb)
        t.equal(pb.string(forType: .html), "<p>some <strong>bold</strong> text</p>\n", "with a selection: its whole lines")
        host.copyAsRichText(to: pb)
        t.check(pb.data(forType: .rtf) != nil && pb.string(forType: .html) == "<p>some <strong>bold</strong> text</p>\n", "Copy as Rich Text: RTF and HTML on the pasteboard")
        t.check(pb.string(forType: .string)?.contains("some bold text") == true, "... and the words as plain text: \(pb.string(forType: .string) ?? "")")
        if let rtf = pb.data(forType: .rtf), let a = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            var boldFound = false
            a.enumerateAttribute(.font, in: NSRange(location: 0, length: a.length)) { v, r, _ in if let f = v as? NSFont, f.fontDescriptor.symbolicTraits.contains(.bold), (a.string as NSString).substring(with: r).contains("bold") { boldFound = true } }
            t.check(boldFound, "the RTF has the bold word in a bold face")
        }
        let item = NSMenuItem(title: "", action: #selector(LuftigEditorActions.luftigCopyAsHTML(_:)), keyEquivalent: "")
        t.check(host.validateMenuItem(item) && item.title == "Copy as HTML", "the menu item says Copy as HTML with a selection")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        _ = host.validateMenuItem(item)
        t.equal(item.title, "Copy All as HTML", "... and Copy All as HTML without one")
        let exported = t.url("export.html")
        try document.exportHTML(to: exported)
        let page2 = t.read(exported)
        t.check(page2.hasPrefix("<!DOCTYPE html>") && page2.contains("<title>html</title>") && page2.contains("<h1>Head</h1>"), "Export as HTML writes a page named after the document with its content")
        t.check(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu?.items.contains { $0.title == "Export as HTML…" } == true, "File > Export as HTML… exists")
        // Export as Rich Text / as PDF: from the same HTML, without the web page's column
        let rtfURL = t.url("export.rtf")
        try document.exportRTF(to: rtfURL)
        if let a = NSAttributedString(rtf: t.readData(rtfURL), documentAttributes: nil) {
            var boldFound = false
            a.enumerateAttribute(.font, in: NSRange(location: 0, length: a.length)) { v, r, _ in if let f = v as? NSFont, f.fontDescriptor.symbolicTraits.contains(.bold), (a.string as NSString).substring(with: r).contains("bold") { boldFound = true } }
            t.check(boldFound && a.string.contains("Head") && a.string.contains("some bold text"), "Export as Rich Text writes an RTF with the heading, the words and the bold face: \(a.string.prefix(40).debugDescription)")
        } else { t.check(false, "Export as Rich Text writes an RTF that AppKit reads back") }
        let pdfURL = t.url("export.pdf")
        try document.exportPDF(to: pdfURL)
        let pdf = t.readData(pdfURL)
        t.check(pdf.count > 1000 && String(decoding: pdf.prefix(5), as: UTF8.self) == "%PDF-", "Export as PDF writes a PDF (\(pdf.count) bytes)")
        if let provider = CGDataProvider(data: pdf as CFData), let cg = CGPDFDocument(provider) { t.check(cg.numberOfPages >= 1, "... with \(cg.numberOfPages) page(s)") }
        for title in ["Export as Rich Text…", "Export as PDF…"] { t.check(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu?.items.contains { $0.title == title } == true, "File > \(title) exists") }
        t.check(richTextParagraphsNoWebMargins(document), "the rich text has no web-page column (no 3 em margins or max width in its stylesheet)")
        t.check(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu?.items.contains { $0.title.hasSuffix("as Rich Text") } == true, "Edit > Copy (All) as Rich Text exists (the title follows the selection once validated)")
    }

    // MARK: edit-typewriter

    @MainActor static func editScrollStability(_ t: SelfTest.T) async throws {
        try await preservingSettings {
            let text = SelfTestCorpus.markdown(bytes: 300_000, seed: 3)
            let (doc, host, _) = try await openEditor(t, text: text, name: "scroll-stability.md", size: NSSize(width: 860, height: 700))
            defer { t.close(doc) }
            let tv = host.textView, clip = host.scrollView.contentView
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { t.check(false, "layout"); return }
            let ns = tv.string as NSString
            @MainActor func caretScreenY() -> CGFloat {
                guard let line = host.caretLineRect(at: tv.selectedRange().location) else { return -1 }
                return line.minY + tv.textContainerOrigin.y - clip.bounds.origin.y
            }
            @MainActor func topCharacter() -> Int {
                let p = NSPoint(x: 0, y: clip.bounds.origin.y + 1 - tv.textContainerOrigin.y)
                return lm.characterIndexForGlyph(at: lm.glyphIndex(for: p, in: tc))
            }
            /// `n` key presses; after each one the window must not have scrolled (the line at its top is the same line, the caret's line moved on screen by at most
            /// the lines the edit itself added or removed: a Return or a wrap moves the caret down a line, un-wrapping up), and the caret stays in view.
            @MainActor func run(_ what: String, _ n: Int, allowedLines: Int, _ key: @MainActor () -> Void) async {
                var worst: CGFloat = 0, topMoved = 0, caretOut = 0
                let y0 = caretScreenY(), top0 = topCharacter()
                let topY0 = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: top0), effectiveRange: nil).minY + tv.textContainerOrigin.y - clip.bounds.origin.y
                for _ in 0..<n {
                    key()
                    await AuditEd.settle(t, host, ms: 5)
                    let y = caretScreenY()
                    worst = max(worst, abs(y - y0))
                    if y < 0 || y > clip.bounds.height { caretOut += 1 }
                    let topY = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: top0), effectiveRange: nil).minY + tv.textContainerOrigin.y - clip.bounds.origin.y
                    if abs(topY - topY0) > 1 { topMoved += 1 }
                }
                let limit = CGFloat(allowedLines) * host.theme.bodyLineHeight + 2
                t.check(worst <= limit && topMoved == 0 && caretOut == 0, String(format: "%@: the window did not scroll and the caret stayed in view (caret moved %.0f pt at most, allowed %.0f; the top line moved %d times of %d; caret out of view %d times)", what, worst, limit, topMoved, n, caretOut))
            }
            for (label, fraction) in [("near the start", 0.05), ("in the middle", 0.5), ("near the end", 0.9)] {
                // scroll there, settle, put the caret on the line in the middle of the window
                let target = Int(Double(ns.length) * fraction)
                tv.scrollRangeToVisible(NSRange(location: target, length: 0))
                await AuditEd.settle(t, host, ms: 50)
                let midPoint = NSPoint(x: 40, y: clip.bounds.origin.y + clip.bounds.height / 2 - tv.textContainerOrigin.y)
                var loc = lm.characterIndexForGlyph(at: lm.glyphIndex(for: midPoint, in: tc))
                // the start of a paragraph of prose (not a code fence or a blank line): a place where Backspace joins paragraphs
                while loc > 0 && ns.character(at: loc - 1) != 0x0A { loc -= 1 }
                tv.setSelectedRange(NSRange(location: loc + 3, length: 0))
                await AuditEd.settle(t, host, ms: 20)
                t.note("\(label): caret at \(tv.selectedRange().location) of \(ns.length), window top at character \(topCharacter()), clip y \(Int(clip.bounds.origin.y))")
                await run("\(label): 20 characters", 20, allowedLines: 0) { AuditEd.press(host, "a", code: 0) }
                await run("\(label): 20 Backspaces", 20, allowedLines: 0) { AuditEd.pressKey(host, AuditEd.Key.delete) }
                await run("\(label): Backspace into the previous paragraph (3 x)", 3, allowedLines: 3) { AuditEd.pressKey(host, AuditEd.Key.delete) }
                await run("\(label): Return (3 x)", 3, allowedLines: 3) { AuditEd.pressKey(host, AuditEd.Key.returnKey) }
                await run("\(label): a long line of 120 characters", 120, allowedLines: 2) { AuditEd.press(host, "b", code: 0) }
                await run("\(label): 120 Backspaces", 120, allowedLines: 2) { AuditEd.pressKey(host, AuditEd.Key.delete) }
                // the pause after typing: the outline and the word count are recomputed (300 ms); that must not move the text either
                let yPause = caretScreenY(), topPause = topCharacter()
                await t.spin(700)
                host.styler.styleVisible()
                t.check(abs(caretScreenY() - yPause) <= 1 && topCharacter() == topPause, String(format: "%@: the pause after typing (outline recomputed) moves nothing (caret %.0f -> %.0f)", label, yPause, caretScreenY()))
            }
            // long paragraphs (one physical line of 1,500 characters, a dozen visual lines each; the document of the report, pitfall 38): the same keys
            let sentence = "Agentic systems are built on language models but change the setup in which these models operate, and the layers involved belong to different actors. "
            let longParas = (1...40).map { n in "Paragraph \(n). " + String(repeating: sentence, count: 10) }.joined(separator: "\n\n")
            let (doc2, host2, _) = try await openEditor(t, text: "# Long paragraphs\n\n" + longParas + "\n", name: "scroll-stability-long.md", size: NSSize(width: 860, height: 700))
            defer { t.close(doc2) }
            EditorPreferences.lineHeightFactor = 2
            EditorPreferences.padding = 30
            await AuditEd.settle(t, host2, ms: 100)
            let tv2 = host2.textView, clip2 = host2.scrollView.contentView, ns2 = tv2.string as NSString, lm2 = tv2.layoutManager!
            let p20 = ns2.range(of: "Paragraph 20. ").location + 14 + sentence.utf16.count * 4
            tv2.scrollRangeToVisible(NSRange(location: p20, length: 0))
            await AuditEd.settle(t, host2, ms: 50)
            tv2.setSelectedRange(NSRange(location: p20, length: 0))
            await AuditEd.settle(t, host2, ms: 20)
            @MainActor func caretY2() -> CGFloat { (host2.caretLineRect(at: tv2.selectedRange().location)?.minY ?? -1) + tv2.textContainerOrigin.y - clip2.bounds.origin.y }
            @MainActor func run2(_ what: String, _ n: Int, allowedLines: Int, _ key: @MainActor () -> Void) async {
                let top0 = lm2.characterIndexForGlyph(at: lm2.glyphIndex(for: NSPoint(x: 0, y: clip2.bounds.origin.y + 1 - tv2.textContainerOrigin.y), in: tv2.textContainer!))
                let topY0 = lm2.lineFragmentRect(forGlyphAt: lm2.glyphIndexForCharacter(at: top0), effectiveRange: nil).minY + tv2.textContainerOrigin.y - clip2.bounds.origin.y
                var worst: CGFloat = 0, topMoved = 0
                let y0 = caretY2()
                for _ in 0..<n {
                    key()
                    await AuditEd.settle(t, host2, ms: 5)
                    worst = max(worst, abs(caretY2() - y0))
                    let topY = lm2.lineFragmentRect(forGlyphAt: lm2.glyphIndexForCharacter(at: top0), effectiveRange: nil).minY + tv2.textContainerOrigin.y - clip2.bounds.origin.y
                    if abs(topY - topY0) > 1 { topMoved += 1 }
                }
                let limit = CGFloat(allowedLines) * host2.theme.bodyLineHeight + 2
                t.check(worst <= limit && topMoved == 0, String(format: "long paragraphs, %@: the window did not scroll (caret moved %.0f pt at most, allowed %.0f; the top line moved %d times of %d)", what, worst, limit, topMoved, n))
            }
            await run2("8 characters", 8, allowedLines: 1) { AuditEd.press(host2, "a", code: 0) }
            await run2("16 Backspaces", 16, allowedLines: 1) { AuditEd.pressKey(host2, AuditEd.Key.delete) }
            await run2("Return", 1, allowedLines: 1) { AuditEd.pressKey(host2, AuditEd.Key.returnKey) }
            await run2("Backspace over it", 1, allowedLines: 1) { AuditEd.pressKey(host2, AuditEd.Key.delete) }
            EditorPreferences.lineHeightFactor = nil
            EditorPreferences.padding = EditorPreferences.defaultPadding

            // Typewriter Mode: the caret's line stays in the middle through the same edits, and the view never moves when the caret's line does not change
            // (with the settings the report came with: line spacing 2.0, padding 30)
            EditorPreferences.typewriterMode = true
            EditorPreferences.lineHeightFactor = 2
            EditorPreferences.padding = 30
            await AuditEd.settle(t, host, ms: 100)
            let mid = Int(Double(ns.length) * 0.5)
            tv.setSelectedRange(NSRange(location: mid, length: 0))
            var loc = mid
            while loc > 0 && ns.character(at: loc - 1) != 0x0A { loc -= 1 }
            tv.setSelectedRange(NSRange(location: loc + 3, length: 0))
            await AuditEd.settle(t, host, ms: 50)
            @MainActor func caretMid() -> CGFloat {
                guard let line = host.caretLineRect(at: tv.selectedRange().location) else { return -1 }
                return line.midY + tv.textContainerOrigin.y - clip.bounds.origin.y
            }
            @MainActor func typewriterRun(_ what: String, _ n: Int, _ key: @MainActor () -> Void) async {
                var worst: CGFloat = 0, scrolls = 0, biggest: CGFloat = 0
                for _ in 0..<n {
                    let y = clip.bounds.origin.y, line = tv.selectedRange().location
                    key()
                    await AuditEd.settle(t, host, ms: 5)
                    worst = max(worst, abs(caretMid() - clip.bounds.height / 2))
                    let sameLine = host.caretLineRect(at: tv.selectedRange().location)?.minY == host.caretLineRect(at: min(line, (tv.string as NSString).length))?.minY
                    if sameLine && abs(clip.bounds.origin.y - y) > 1 { scrolls += 1; biggest = max(biggest, abs(clip.bounds.origin.y - y)) }
                }
                t.check(worst <= 3 && scrolls == 0, String(format: "Typewriter Mode, %@: the caret's line stays in the middle (worst %.1f pt off), no scroll while the line does not change (%d, biggest %.0f pt)", what, worst, scrolls, biggest))
            }
            t.check(abs(caretMid() - clip.bounds.height / 2) < 3, String(format: "Typewriter Mode: the caret's line is in the middle (%.1f of %.1f)", caretMid(), clip.bounds.height))
            await typewriterRun("20 characters", 20) { AuditEd.press(host, "a", code: 0) }
            await typewriterRun("20 Backspaces", 20) { AuditEd.pressKey(host, AuditEd.Key.delete) }
            await typewriterRun("Backspace into the previous paragraph (3 x)", 3) { AuditEd.pressKey(host, AuditEd.Key.delete) }
            await typewriterRun("Return (3 x)", 3) { AuditEd.pressKey(host, AuditEd.Key.returnKey) }
            await typewriterRun("a long line of 120 characters", 120) { AuditEd.press(host, "b", code: 0) }
            await typewriterRun("120 Backspaces", 120) { AuditEd.pressKey(host, AuditEd.Key.delete) }
            EditorPreferences.typewriterMode = false
        }
    }

    @MainActor static func editCaret(_ t: SelfTest.T) async throws {
        try await preservingSettings {
            let text = "# Title\n\nBody text of a paragraph.\n"
            let (doc, host, _) = try await openEditor(t, text: text, name: "caret.md", size: NSSize(width: 700, height: 500))
            defer { t.close(doc) }
            let tv = host.textView as! LuftigEditorTextView
            guard let lm = tv.layoutManager, let storage = tv.textStorage else { t.check(false, "layout manager"); return }
            lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: storage.length))
            @MainActor func check(_ location: Int, _ what: String) {
                tv.setSelectedRange(NSRange(location: location, length: 0))
                let charIndex = min(location, storage.length - 1)
                let glyph = lm.glyphIndexForCharacter(at: charIndex)
                let fragment = location >= storage.length ? lm.extraLineFragmentRect : lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let box = NSRect(x: fragment.minX + tv.textContainerOrigin.x, y: fragment.minY + tv.textContainerOrigin.y, width: 1, height: fragment.height)      // what NSTextView hands in: the line box
                let font = storage.attribute(.font, at: charIndex, effectiveRange: nil) as! NSFont
                let r = tv.caretRect(within: box)
                let fontHeight = font.ascender - font.descender
                t.check(abs(r.height - fontHeight) < 0.01 && fontHeight < box.height - 2, "\(what): the caret is the font's height \(Int(fontHeight.rounded())) pt, not the line box \(Int(box.height)) pt")
                t.check(r.minY >= box.minY - 0.01 && r.maxY <= box.maxY + 0.01, "\(what): inside the line box (invalidated for the blink)")
                let baseline = fragment.minY + tv.textContainerOrigin.y + lm.location(forGlyphAt: glyph).y
                // on the baseline - or moved up by the fraction of a point the rounded baseline lets the descent overshoot the box
                let bottom = min(baseline - font.descender, box.maxY)
                t.check(abs(r.maxY - bottom) < 0.01 && bottom > baseline - font.descender - 1, "\(what): standing on the baseline (overshoot \(String(format: "%.2f", baseline - font.descender - bottom)) pt)")
            }
            check(3, "heading")
            check(12, "body")
            check(storage.length, "the extra line after the final line break")
            let plain = NSTextView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            t.check(plain.textStorage?.length == 0, "set-up")
            let empty = tv.caretRect(within: NSRect(x: 0, y: 0, width: 1, height: 30))
            t.check(empty.height > 0, "an unexpected geometry falls back to the given rect: \(empty)")
        }
    }

    @MainActor static func editTypewriter(_ t: SelfTest.T) async throws {
        try await preservingSettings {
            t.check(!EditorPreferences.typewriterMode, "off by default")
            let view = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu
            t.check(view?.items.contains { $0.title == "Typewriter Mode" && $0.keyEquivalent == "t" && $0.keyEquivalentModifierMask == [.command, .shift] } == true, "View > Typewriter Mode (⇧⌘T)")
            t.check(view?.items.contains { $0.title.contains("Focus") } != true, "no Focus Mode any more")
            let paras = (1...30).map { "Paragraph \($0) has a first line\nand a second line of the same paragraph \($0).\n" }.joined(separator: "\n")
            let text = "# Title\n\n" + paras
            let (doc, host, _) = try await openEditor(t, text: text, name: "typewriter.md", size: NSSize(width: 700, height: 500))
            defer { t.close(doc) }
            let tv = host.textView
            let ns = text as NSString
            // Typewriter Mode: the inset makes room, the caret's line sits in the middle
            let clip = host.scrollView.contentView
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            host.luftigToggleTypewriterMode(nil)
            t.check(EditorPreferences.typewriterMode, "View > Typewriter Mode switches the preference on")
            let item = NSMenuItem(title: "Typewriter Mode", action: #selector(LuftigEditorActions.luftigToggleTypewriterMode(_:)), keyEquivalent: "")
            _ = host.validateMenuItem(item)
            t.check(item.state == .on, "the menu item is checked")
            let expectedInset = ((clip.bounds.height - host.theme.bodyLineHeight) / 2).rounded(.down)
            t.equal(tv.textContainerInset.height, expectedInset, "the vertical inset is half the viewport less half a line (\(expectedInset) pt)")
            func caretLineMid() -> CGFloat {
                guard let line = host.caretLineRect(at: tv.selectedRange().location) else { return -1 }
                return line.midY + tv.textContainerOrigin.y - clip.bounds.origin.y
            }
            t.check(abs(caretLineMid() - clip.bounds.height / 2) < 2, String(format: "the first line is in the middle of the viewport (%.1f of %.1f)", caretLineMid(), clip.bounds.height))
            let p20 = ns.range(of: "Paragraph 20").location
            tv.setSelectedRange(NSRange(location: p20, length: 0))
            t.check(abs(caretLineMid() - clip.bounds.height / 2) < 2, String(format: "the caret moved to paragraph 20: its line is in the middle (%.1f of %.1f)", caretLineMid(), clip.bounds.height))
            let yBefore = clip.bounds.origin.y
            t.typeText("x", into: doc)
            t.check(abs(clip.bounds.origin.y - yBefore) < 1, "typing on the line does not move the view")
            AuditEd.undo(host)
            let end = (tv.string as NSString).length
            tv.setSelectedRange(NSRange(location: end, length: 0))
            t.check(abs(caretLineMid() - clip.bounds.height / 2) < 2, String(format: "the last line can be in the middle too (%.1f of %.1f)", caretLineMid(), clip.bounds.height))
            assertMatchesFreshLex(t, host, "Typewriter Mode: the styled text still equals a fresh lex")
            host.luftigToggleTypewriterMode(nil)
            t.check(!EditorPreferences.typewriterMode && tv.textContainerInset.height == 0, "off again: no inset")
            // a second window follows the switch
            let (doc2, host2, _) = try await openEditor(t, text: "a\n\nb\n", name: "typewriter2.md")
            host.luftigToggleTypewriterMode(nil)
            t.check(host2.textView.textContainerInset.height > 0, "a second window follows the switch")
            host.luftigToggleTypewriterMode(nil)
            t.check(host2.textView.textContainerInset.height == 0, "... and back")
            t.close(doc2)
        }
    }

    // MARK: edit-links

    @MainActor static func editLinks(_ t: SelfTest.T) async throws {
        // the pure resolver
        let styler = MarkdownStyler()
        func dest(_ marked: String) -> String? {
            let ns = marked as NSString
            let r = ns.range(of: "|")
            let text = ns.replacingCharacters(in: r, with: "") as NSString
            return LinkFollowing.destination(at: r.location, in: text, runs: styler.lexAll(text))
        }
        t.equal(dest("see [the |docs](https://example.org/d \"t\") now"), "https://example.org/d", "the destination of an inline link, from its text")
        t.equal(dest("see [the docs](https://exa|mple.org/d) now"), "https://example.org/d", "... from inside the destination")
        t.equal(dest("see |[the docs](https://example.org/d) now"), "https://example.org/d", "... from the opening bracket")
        t.equal(dest("see [the docs](https://example.org/d|) now"), "https://example.org/d", "... from the closing paren")
        t.equal(dest("[x](<has space.md>|)"), "has space.md", "angle brackets around a destination are removed")
        t.equal(dest("[x]( sp|aced )"), "spaced", "spaces around a destination are trimmed")
        t.equal(dest("![al|t](pic.png)"), "pic.png", "an image's source")
        t.equal(dest("<https://au|to.link>"), "https://auto.link", "an autolink")
        t.equal(dest("|<https://auto.link>"), "https://auto.link", "... from its bracket")
        t.equal(dest("go www.ba|re.com now"), "www.bare.com", "a bare www address")
        t.equal(dest("go https://bare.example/p|ath?a=1. end"), "https://bare.example/path?a=1", "a bare URL (the trailing period is not part of it)")
        t.equal(dest("[e|][ref]\n\n[REF]: https://ref.example"), "https://ref.example", "a reference link: the definition, case-insensitively")
        t.equal(dest("[e][r|ef]\n\n[ref]: <https://ref.example>"), "https://ref.example", "... from the label, angle brackets removed")
        t.equal(dest("[sho|rtcut]\n\n[shortcut]: /abs/file.md"), "/abs/file.md", "a shortcut reference [label]")
        t.check(dest("plain |text") == nil && dest("[no|def][gone]") == nil && dest("|") == nil, "no link: nil")
        t.check(dest("`[not](a-link)|`") == nil, "inside a code span: nil")
        // targets
        let base = URL(fileURLWithPath: "/tmp/notes/")
        t.equal(LinkFollowing.target(for: "https://example.org/x", base: base), .web(URL(string: "https://example.org/x")!), "a web URL")
        t.equal(LinkFollowing.target(for: "mailto:a@b.c", base: base), .web(URL(string: "mailto:a@b.c")!), "mailto is opened by the system too")
        t.equal(LinkFollowing.target(for: "www.example.org", base: base), .web(URL(string: "https://www.example.org")!), "www. gets https")
        t.equal(LinkFollowing.target(for: "#Some-Heading", base: base), .anchor("Some-Heading"), "an anchor in this document")
        t.equal(LinkFollowing.target(for: "other.md", base: base), .file(URL(fileURLWithPath: "/tmp/notes/other.md"), anchor: nil), "a relative file")
        t.equal(LinkFollowing.target(for: "../up/o%20k.md#sec", base: base), .file(URL(fileURLWithPath: "/tmp/up/o k.md"), anchor: "sec"), "..: percent-decoded, the anchor split off")
        t.equal(LinkFollowing.target(for: "/abs/p.txt", base: nil), .file(URL(fileURLWithPath: "/abs/p.txt"), anchor: nil), "an absolute path needs no base")
        t.check(LinkFollowing.target(for: "rel.md", base: nil) == nil, "a relative path without a base (untitled document): nowhere")
        t.check(LinkFollowing.target(for: "", base: base) == nil && LinkFollowing.target(for: "#", base: base) == nil, "empty: nowhere")
        t.equal(LinkFollowing.target(for: "C:\\x", base: base), .file(URL(fileURLWithPath: "/tmp/notes/C:\\x"), anchor: nil), "a one-letter scheme is a path")
        t.equal(LinkFollowing.slug("Hello, World! Größe & 2.0"), "hello-world-größe--20", "GitHub slugs")
        let entries = OutlineScanner.headings(in: "# Intro\n\n## Second Part\n\n### Third: one, two\n" as NSString)
        t.equal(LinkFollowing.entry(for: "second-part", in: entries)?.title, "Second Part", "an anchor finds its heading by slug")
        t.equal(LinkFollowing.entry(for: "Third:%20one,%20two", in: entries)?.title, "Third: one, two", "... or by its title, percent-decoded")
        t.check(LinkFollowing.entry(for: "nothing", in: entries) == nil, "no heading: nil")
        t.check(LinkFollowing.opensAsDocument(URL(fileURLWithPath: "/a/b.md")) && LinkFollowing.opensAsDocument(URL(fileURLWithPath: "/a/README")) && !LinkFollowing.opensAsDocument(URL(fileURLWithPath: "/a/p.png")), "Markdown, text and extension-less files open in luftig, images elsewhere")

        // the editor: ⌘-click and Edit > Open Link, with the openers replaced
        var opened: [URL] = []
        var openedDocs: [(URL, String?)] = []
        let savedExternal = EditorViewController.openExternally, savedDocument = EditorViewController.openDocument
        EditorViewController.openExternally = { opened.append($0) }
        EditorViewController.openDocument = { openedDocs.append(($0, $1)) }
        defer { EditorViewController.openExternally = savedExternal; EditorViewController.openDocument = savedDocument }
        let other = t.write("# Other\n\n## Target Section\n\ntext\n", to: "links/other.md")
        _ = t.write("png", to: "links/pic.png")
        let text = "# Intro\n\nsee [the docs](https://example.org/d) and [other](other.md#target-section) and ![pic](pic.png) and [here](#later) and [gone](missing.md)\n\n" + String(repeating: "filler\n\n", count: 40) + "## Later\n\nend\n"
        let (doc, host, _) = try await openEditor(t, text: text, name: "links/main.md")
        defer { t.close(doc) }
        let tv = host.textView
        let ns = text as NSString
        t.equal(host.linkDestination(at: ns.range(of: "the docs").location + 2), "https://example.org/d", "the editor resolves the link under a character")
        t.check(host.linkDestination(at: 3) == nil, "... and finds none on the heading")
        host.followLink(at: ns.range(of: "the docs").location)
        t.equal(opened, [URL(string: "https://example.org/d")!], "a web link is handed to the system")
        host.followLink(at: ns.range(of: "other").location + 1)
        t.check(openedDocs.count == 1 && openedDocs.first?.0.standardizedFileURL == other.standardizedFileURL && openedDocs.first?.1 == "target-section", "a Markdown file next to the document opens in luftig, with its anchor: \(openedDocs)")
        host.followLink(at: ns.range(of: "pic").location + 1)
        t.equal(opened.last?.lastPathComponent, "pic.png", "an image opens in its own application")
        let before = tv.visibleRect.minY
        host.followLink(at: ns.range(of: "here").location + 1)
        t.check(tv.selectedRange().location == ns.range(of: "## Later").location && tv.visibleRect.minY > before, "an anchor scrolls to the heading in this document and puts the caret on it (caret \(tv.selectedRange().location) vs \(ns.range(of: "## Later").location), scrolled \(before) -> \(tv.visibleRect.minY))")
        t.check(opened.count == 2 && openedDocs.count == 1, "... without opening anything")
        t.check(host.followLink(at: ns.range(of: "gone").location + 1) && opened.count == 2 && openedDocs.count == 1, "a missing file: the click is taken (a beep), nothing opens")
        t.check(!host.followLink(at: 3), "no link: false (the click is an ordinary click)")
        // Edit > Open Link: enabled on a link, disabled elsewhere
        let item = NSMenuItem(title: "Open Link", action: #selector(LuftigEditorActions.luftigOpenLink(_:)), keyEquivalent: "")
        tv.setSelectedRange(NSRange(location: ns.range(of: "the docs").location, length: 0))
        t.check(host.validateMenuItem(item), "Edit > Open Link is enabled with the caret on a link")
        t.check(AuditEd.perform(host, #selector(LuftigEditorActions.luftigOpenLink(_:)), grouped: false) && opened.count == 3, "... and opens it")
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        t.check(!host.validateMenuItem(item), "... disabled elsewhere")
        t.check(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu?.items.contains { $0.title == "Open Link" && $0.keyEquivalent == "l" } == true, "the Edit menu has Open Link (⌥⌘L)")
        // a real ⌘-click on the link's glyphs, through the text view's mouseDown
        host.styler.styleVisible()
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        let lm = tv.layoutManager!, tc = tv.textContainer!
        let glyph = lm.glyphIndexForCharacter(at: ns.range(of: "the docs").location + 3)
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        let inView = NSPoint(x: rect.midX + tv.textContainerOrigin.x, y: rect.midY + tv.textContainerOrigin.y)
        let inWindow = tv.convert(inView, to: nil)
        guard let window = tv.window else { t.check(false, "a window"); return }
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: inWindow, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        t.equal(host.editorTextView.characterIndex(under: inView), ns.range(of: "the docs").location + 3, "the character under the point")
        tv.mouseDown(with: click)
        t.equal(opened.count, 4, "⌘-click on the link opens it")
        t.equal(tv.selectedRange(), NSRange(location: 0, length: 0), "... without moving the selection")
        let beyond = NSPoint(x: tv.bounds.maxX - 2, y: inView.y)
        t.check(host.editorTextView.characterIndex(under: beyond) == nil, "right of the line's end: no character")
        let plainClick = NSEvent.mouseEvent(with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1)!
        NSApp.postEvent(up, atStart: false)                                     // (NSTextView's mouseDown tracks until the mouse goes up)
        tv.mouseDown(with: plainClick)
        t.check(opened.count == 4 && tv.selectedRange().location > 0, "a plain click only moves the caret (\(NSStringFromRange(tv.selectedRange())))")
    }

    // MARK: edit-format-menu

    @MainActor static func editFormatMenu(_ t: SelfTest.T) async throws {
        guard let main = NSApp.mainMenu, let format = main.items.first(where: { $0.title == "Format" })?.submenu else { t.check(false, "a Format menu exists"); return }
        let items = format.items.filter { !$0.isSeparatorItem }
        t.equal(items.count, SyntaxElement.allCases.count, "one item per element of the syntax bar")
        t.equal(format.items.filter { $0.isSeparatorItem }.count, SyntaxElement.groups.count - 1, "a separator between the bar's groups")
        t.check(items.allSatisfy { $0.action == #selector(LuftigEditorActions.luftigInsertSyntax(_:)) && $0.target == nil && SyntaxElement.element(menuTag: $0.tag) != nil }, "every item: the insert action through the responder chain, a tag that names its element")
        let keys = items.map { $0.keyEquivalent + "/" + String($0.keyEquivalentModifierMask.rawValue) }
        t.check(Set(keys).count == keys.count && items.allSatisfy { !$0.keyEquivalent.isEmpty }, "every item has a shortcut, all different: \(items.map { SyntaxElement.element(menuTag: $0.tag)!.shortcut.label })")
        t.check(items.contains { $0.title == "Bold" && $0.keyEquivalent == "b" && $0.keyEquivalentModifierMask == [.command] }, "Bold is ⌘B")
        t.check(items.contains { $0.title == "Italic" && $0.keyEquivalent == "i" && $0.keyEquivalentModifierMask == [.command] }, "Italic is ⌘I")
        t.check(items.contains { $0.title == "Link" && $0.keyEquivalent == "k" && $0.keyEquivalentModifierMask == [.command] }, "Link is ⌘K")
        t.check(items.contains { $0.title == "Heading 1" && $0.keyEquivalent == "1" && $0.keyEquivalentModifierMask == [.command, .shift] }, "Heading 1 is ⇧⌘1")
        t.equal(SyntaxElement.bold.shortcut.label, "⌘B", "the shortcut's label")
        t.equal(SyntaxElement.image.shortcut.label, "⇧⌘K", "... with shift")
        t.equal(SyntaxElement.quote.shortcut.label, "⌥⌘Q", "... with option")
        let (doc, host, _) = try await openEditor(t, text: "say hello world\n", name: "format.md")
        defer { t.close(doc) }
        let tv = host.textView
        t.check(host.syntaxBar.labels[.bold]?.toolTip?.contains("⌘B") == true, "the bar's tooltip names the shortcut: \(host.syntaxBar.labels[.bold]?.toolTip ?? "")")
        tv.setSelectedRange(NSRange(location: 4, length: 5))
        t.check(AuditEd.perform(host, #selector(LuftigEditorActions.luftigInsertSyntax(_:)), tag: SyntaxElement.bold.menuTag), "Format > Bold reaches the editor through the responder chain")
        t.equal(tv.string, "say **hello** world\n", "... and wraps the selection")
        t.equal(tv.selectedRange(), NSRange(location: 6, length: 5), "the word stays selected")
        t.check(AuditEd.perform(host, #selector(LuftigEditorActions.luftigInsertSyntax(_:)), tag: SyntaxElement.heading2.menuTag), "Format > Heading 2")
        t.check(tv.string.hasPrefix("## say **hello**"), "... the line is a heading")
        AuditEd.undo(host); AuditEd.undo(host)
        t.equal(tv.string, "say hello world\n", "two undo steps bring the text back")
        let bold = NSMenuItem(title: "Bold", action: #selector(LuftigEditorActions.luftigInsertSyntax(_:)), keyEquivalent: "")
        bold.tag = SyntaxElement.bold.menuTag
        t.check(host.validateMenuItem(bold), "the item is enabled for an editable editor")
        tv.isEditable = false
        t.check(!host.validateMenuItem(bold), "... and disabled for a read-only one")
        tv.isEditable = true
        let bad = NSMenuItem(title: "x", action: #selector(LuftigEditorActions.luftigInsertSyntax(_:)), keyEquivalent: "")
        bad.tag = 999
        t.check(!host.validateMenuItem(bad), "a tag that names no element is disabled")
        host.luftigInsertSyntax(bad)
        t.equal(tv.string, "say hello world\n", "... and does nothing")
        t.check(!SettingsWindowController.shared.responds(to: #selector(LuftigEditorActions.luftigInsertSyntax(_:))), "the Settings window does not answer the Format menu (its items are disabled while it is key)")
    }

    // MARK: edit-lists

    @MainActor static func editLists(_ t: SelfTest.T) async throws {
        /// `|` marks the caret; returns (text after Return, caret as `|` in it), or nil when Return is left to the text view.
        func ret(_ marked: String) -> String? {
            let ns = marked as NSString
            let r = ns.range(of: "|")
            let text = ns.replacingCharacters(in: r, with: "") as NSString
            guard let c = ListContinuation.returnChange(in: text, selection: NSRange(location: r.location, length: 0)) else { return nil }
            let out = text.replacingCharacters(in: c.range, with: c.replacement) as NSString
            return out.replacingCharacters(in: NSRange(location: c.selection.location, length: 0), with: "|")
        }
        func tab(_ marked: String, outdent: Bool = false) -> String? {
            let ns = marked as NSString
            let a = ns.range(of: "⟦"), b = ns.range(of: "⟧")
            var text = ns, sel: NSRange
            if a.location != NSNotFound {
                let s = ns.replacingCharacters(in: b, with: "") as NSString
                text = s.replacingCharacters(in: a, with: "") as NSString
                sel = NSRange(location: a.location, length: b.location - a.location - 1)
            } else {
                let r = ns.range(of: "|")
                text = ns.replacingCharacters(in: r, with: "") as NSString
                sel = NSRange(location: r.location, length: 0)
            }
            guard let c = ListContinuation.indentChange(in: text, selection: sel, outdent: outdent) else { return nil }
            let out = text.replacingCharacters(in: c.range, with: c.replacement) as NSString
            if c.selection.length == 0 { return out.replacingCharacters(in: NSRange(location: c.selection.location, length: 0), with: "|") }
            return (out.replacingCharacters(in: NSRange(location: NSMaxRange(c.selection), length: 0), with: "⟧") as NSString).replacingCharacters(in: NSRange(location: c.selection.location, length: 0), with: "⟦")
        }
        // prefixes
        let p = ListContinuation.prefix(of: "  > - [x] done")
        t.check(p.indent == "  " && p.quotes == "> " && p.marker == "- " && p.task == "[x] " && p.number == nil, "prefix of '  > - [x] done': indent, quote, marker, task: \(p)")
        let n = ListContinuation.prefix(of: "10)   ten")
        t.check(n.number == 10 && n.delimiter == ")" && n.marker == "10)   " && n.markerWidth == 6, "a numbered marker keeps its white space: \(n)")
        t.check(ListContinuation.prefix(of: "-item").isEmpty && ListContinuation.prefix(of: "1.5 things").isEmpty && ListContinuation.prefix(of: "plain").isEmpty, "'-item', '1.5 things', 'plain' are no list lines")
        t.check(ListContinuation.prefix(of: "-").hasList && ListContinuation.prefix(of: "1.").hasList, "a bare marker at the end of a line is a (empty) list item")
        t.equal(ListContinuation.width(of: "\t  "), 6, "a tab is 4 columns")

        // Return continues
        t.equal(ret("- one|"), "- one\n- |", "a bullet continues")
        t.equal(ret("* one|\n"), "* one\n* |\n", "a star bullet keeps its character")
        t.equal(ret("- one| two"), "- one\n- | two", "the text after the caret moves to the new item")
        t.equal(ret("  - nested|"), "  - nested\n  - |", "the indentation is kept")
        t.equal(ret("1. one|"), "1. one\n2. |", "a number counts up")
        t.equal(ret("3) three|"), "3) three\n4) |", "the ) delimiter is kept")
        t.equal(ret("- [ ] task|"), "- [ ] task\n- [ ] |", "a task gets an unchecked box")
        t.equal(ret("- [x] done|"), "- [x] done\n- [ ] |", "a checked task continues unchecked")
        t.equal(ret("> quoted|"), "> quoted\n> |", "a quote continues")
        t.equal(ret("> > deep|"), "> > deep\n> > |", "a nested quote continues at its depth")
        t.equal(ret("> - in quote|"), "> - in quote\n> - |", "a list in a quote: both prefixes")
        t.equal(ret("1. one|\n2. two\n3. three\n\n1. other"), "1. one\n2. |\n3. two\n4. three\n\n1. other", "the items in sequence below are renumbered; another list is not")
        t.equal(ret("1. one|\n1. two\n1. three"), "1. one\n2. |\n1. two\n1. three", "all-ones lists are left alone")
        t.equal(ret("1. one|\n   - sub\n2. two"), "1. one\n2. |\n   - sub\n2. two", "a nested line breaks the sequence (nothing below it is renumbered)")
        // Return on an empty item
        t.equal(ret("- one\n- |"), "- one\n|", "an empty top-level item: the marker goes")
        t.equal(ret("1. one\n2. |"), "1. one\n|", "an empty numbered item too")
        t.equal(ret("- one\n  - |"), "- one\n- |", "an empty nested item is outdented first")
        t.equal(ret("> - |"), "> |", "an empty item in a quote: the marker goes, the quote stays")
        t.equal(ret("> |"), "|", "an empty quote line: the quote goes")
        t.equal(ret("> > |"), "> |", "a nested empty quote line: one level less")
        t.equal(ret("- [ ] |"), "|", "an empty task: gone")
        // left to the text view
        t.check(ret("plain|") == nil, "a plain line: nil")
        t.check(ret("-| one") == nil, "the caret inside the prefix: nil")
        t.equal(ret("- |one"), "- \n- |one", "the caret at the start of the text: an empty item above, the text in the new one")
        t.check(ret("|- one") == nil, "the caret at the line start: nil")
        t.check(ListContinuation.returnChange(in: "- one\n- two" as NSString, selection: NSRange(location: 0, length: 5)) == nil, "a selection: nil")
        t.check(ret("|") == nil && ListContinuation.returnChange(in: "", selection: NSRange(location: 0, length: 0)) == nil, "empty text")
        t.check(ret("- one |") != nil, "a caret after trailing spaces continues")

        // Tab / Shift-Tab
        t.equal(tab("- one\n- two|"), "- one\n  - two|", "Tab nests under the item above by the width of its marker")
        t.equal(tab("1. one\n2. two|"), "1. one\n   1. two|", "a numbered item nests by 3 and starts at 1")
        t.equal(tab("1. one\n   1. a\n   2. b\n2. two|"), "1. one\n   1. a\n   2. b\n   3. two|", "a nested numbered item follows the sibling above")
        t.equal(tab("- one|"), "  - one|", "the first item nests by its own marker's width")
        t.equal(tab("- |one"), "  - |one", "the caret keeps its character")
        t.equal(tab("|- one"), "  - |one", "a caret before the marker lands after it")
        t.equal(tab("- one\n  - two|", outdent: true), "- one\n- two|", "Shift-Tab goes back to the parent's indentation")
        t.equal(tab("- one\n   - two\n      - three|", outdent: true), "- one\n   - two\n   - three|", "... whatever the parent's indentation is")
        t.equal(tab("  - two|", outdent: true), "- two|", "no parent: back to the margin")
        t.equal(tab("- two|", outdent: true) == nil, true, "already at the margin: nil")
        t.equal(tab("1. one\n   1. two|", outdent: true), "1. one\n2. two|", "an outdented numbered item follows the item above at that depth")
        t.equal(tab("- one\n⟦- two\n- three⟧"), "- one\n⟦  - two\n  - three⟧", "a selection: every item of it")
        t.equal(tab("⟦- a\ntext\n- b⟧"), "⟦  - a\ntext\n  - b⟧", "a plain line in the selection is left alone")
        t.check(tab("plain|") == nil && tab("⟦plain\nlines⟧") == nil, "no list line: nil (the ordinary tab)")
        t.check(tab("> - quoted|") == nil, "an item inside a quote: nil")
        t.equal(tab("\t- tabbed|", outdent: true), "- tabbed|", "a tab indentation is removed too")
        // robustness
        for s in ["", "-", "- ", "1.", "\n\n", "- a\r\n- b\r\n", "日本語", "- ", "   ", "> ", "1. one\n2. two\n3. three"] {
            for loc in stride(from: 0, through: (s as NSString).length, by: 1) {
                _ = ListContinuation.returnChange(in: s as NSString, selection: NSRange(location: loc, length: 0))
                _ = ListContinuation.indentChange(in: s as NSString, selection: NSRange(location: loc, length: 0), outdent: false)
                _ = ListContinuation.indentChange(in: s as NSString, selection: NSRange(location: loc, length: 0), outdent: true)
            }
        }
        t.check(true, "every caret position of the odd inputs survives")
        t.equal(ret("- a\r\n- b|\r\n"), "- a\r\n- b\n- |\r\n", "CRLF text: the new line is LF (what the editor shows)")
    }

    // MARK: edit-lists-editor

    @MainActor static func editListsEditor(_ t: SelfTest.T) async throws {
        try await preservingSettings {
            let text = "# Title\n\n- one\n- two\n\n1. first\n2. second\n\n```\n- not a list\n```\n"
            let (doc, host, _) = try await openEditor(t, text: text, name: "lists.md")
            defer { t.close(doc) }
            let tv = host.textView
            func str() -> String { tv.string }
            // Return at the end of "- two"
            let twoEnd = (text as NSString).range(of: "- two").upperBound
            tv.setSelectedRange(NSRange(location: twoEnd, length: 0))
            AuditEd.pressKey(host, AuditEd.Key.returnKey)
            t.check(str().hasPrefix("# Title\n\n- one\n- two\n- \n"), "Return continues the bullet list: \(str().prefix(30).debugDescription)")
            t.equal(tv.selectedRange(), NSRange(location: twoEnd + 3, length: 0), "the caret is after the new marker")
            AuditEd.type(host, "three")
            t.check(str().contains("- two\n- three\n"), "typed into the new item")
            AuditEd.pressKey(host, AuditEd.Key.tab)
            t.check(str().contains("- two\n  - three\n"), "Tab nests the item")
            AuditEd.pressKey(host, AuditEd.Key.tab, mods: [.shift])
            t.check(str().contains("- two\n- three\n"), "Shift-Tab un-nests it")
            AuditEd.pressKey(host, AuditEd.Key.returnKey)
            AuditEd.pressKey(host, AuditEd.Key.returnKey)
            t.check(str().contains("- three\n\n\n1. first"), "Return on the empty item removes the marker (an empty line is left, before the blank line the text had): \(str().debugDescription)")
            await t.spin(5)
            t.check(doc.isDocumentEdited, "the document is dirty")
            assertMatchesFreshLex(t, host, "after the list edits the styling is a fresh lex")
            // undo: the key presses are steps of their own (the test wraps every press in a group)
            var undos = 0
            while tv.string != text, undos < 20 { AuditEd.undo(host); undos += 1 }
            t.check(tv.string == text, "undo brings the original text back (\(undos) steps)")
            // numbered: Return in the middle of "first", the sequence below is renumbered
            let mid = (tv.string as NSString).range(of: "1. first").location + 6
            tv.setSelectedRange(NSRange(location: mid, length: 0))
            AuditEd.pressKey(host, AuditEd.Key.returnKey)
            t.check(str().contains("1. fir\n2. st\n3. second\n"), "Return inside a numbered item: the rest moves to a new item, the item below is renumbered: \(str().debugDescription)")
            AuditEd.undo(host)
            t.check(tv.string == text, "one undo step for the whole renumbering")
            // inside the code block nothing happens
            let code = (tv.string as NSString).range(of: "- not a list").upperBound
            host.styler.styleEverything()
            tv.setSelectedRange(NSRange(location: code, length: 0))
            AuditEd.pressKey(host, AuditEd.Key.returnKey)
            t.check(str().contains("- not a list\n\n```"), "Return in a code block inserts a plain line break: \(str().suffix(20).debugDescription)")
            AuditEd.undo(host)
            // a plain line: an ordinary tab
            tv.setSelectedRange(NSRange(location: 7, length: 0))
            AuditEd.pressKey(host, AuditEd.Key.tab)
            t.check(str().hasPrefix("# Title\t\n"), "Tab on a plain line inserts a tab")
            AuditEd.undo(host)
            // the switch
            EditorPreferences.continueLists = false
            tv.setSelectedRange(NSRange(location: twoEnd, length: 0))
            AuditEd.pressKey(host, AuditEd.Key.returnKey)
            t.check(str().hasPrefix("# Title\n\n- one\n- two\n\n\n1. first"), "Continue lists off: Return is a plain line break: \(str().prefix(30).debugDescription)")
            AuditEd.undo(host)
            EditorPreferences.continueLists = true
            t.check(tv.string == text, "back to the start")
            // an IME composition: the text view's own Return (the marked text is committed)
            tv.setSelectedRange(NSRange(location: twoEnd, length: 0))
            let um = tv.undoManager
            um?.beginUndoGrouping()
            tv.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            t.check(tv.hasMarkedText(), "marked text in place")
            t.check(!host.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))), "Return during a composition is left to the text view (the composition decides)")
            tv.unmarkText()
            um?.endUndoGrouping()
            AuditEd.undo(host)
            t.check(tv.string == text, "the composition undone: the original text")
            // the Settings window shows the switch on General
            let c = SettingsWindowController.shared
            c.showScreen(.general)
            t.check(c.continueListsCheckbox.state == .on && !c.generalScreen.isHidden, "Settings > General: 'Continue lists on Return' is on")
            c.continueListsCheckbox.state = .off
            c.continueListsChanged(c.continueListsCheckbox)
            t.check(!EditorPreferences.continueLists, "the checkbox drives the preference")
            EditorPreferences.continueLists = true
            t.check(c.continueListsCheckbox.state == .on, "... and follows it")
        }
    }
}
#endif

#if LUFTIG_SELFTEST
extension SelfTestScenarios {
    /// The HTML behind the rich text has no `max-width` / `margin: 3em auto` (the page is the paper there).
    @MainActor static func richTextParagraphsNoWebMargins(_ doc: MarkdownDocument) -> Bool {
        let html = MarkdownHTML.document(body: "<p>x</p>", title: "t", bodyFont: nil, codeFont: nil, pageLayout: false)
        return !html.contains("max-width: 44em") && !html.contains("margin: 3em") && doc.richText() != nil
    }
}
#endif
