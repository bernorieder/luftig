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
        .init(name: "edit-format-menu", summary: "the Format menu: one item per syntax bar element with a unique shortcut, the same edit as a click on the bar, tooltips name the shortcut, disabled without an editor", run: { t in try await editFormatMenu(t) }),
        .init(name: "edit-links", summary: "⌘-click / Edit > Open Link: the link under a character (inline, image, autolink, bare URL, reference), web / file / anchor targets, a real ⌘-click, a Markdown file opens in luftig at its anchor", run: { t in try await editLinks(t) }),
        .init(name: "edit-focus", summary: "View > Focus Mode (the paragraph at the caret keeps its colours, the rest is veiled: on pixels, attributes untouched) and Typewriter Mode (the caret's line in the middle, the inset makes room), remembered, every window follows", run: { t in try await editFocus(t) }),
    ]

    // MARK: edit-focus

    @MainActor static func editFocus(_ t: SelfTest.T) async throws {
        try await preservingSettings {
            t.check(!EditorPreferences.focusMode && !EditorPreferences.typewriterMode, "both modes off by default")
            let view = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu
            t.check(view?.items.contains { $0.title == "Focus Mode" && $0.keyEquivalent == "f" && $0.keyEquivalentModifierMask == [.command, .shift] } == true, "View > Focus Mode (⇧⌘F)")
            t.check(view?.items.contains { $0.title == "Typewriter Mode" && $0.keyEquivalent == "t" && $0.keyEquivalentModifierMask == [.command, .shift] } == true, "View > Typewriter Mode (⇧⌘T)")
            let paras = (1...30).map { "Paragraph \($0) has a first line\nand a second line of the same paragraph \($0).\n" }.joined(separator: "\n")
            let text = "# Title\n\n" + paras
            let (doc, host, _) = try await openEditor(t, text: text, name: "focus.md", size: NSSize(width: 700, height: 500))
            defer { t.close(doc) }
            let tv = host.textView, etv = host.editorTextView
            let ns = text as NSString
            // the paragraph of a selection
            let p5 = ns.range(of: "Paragraph 5")
            let block5 = host.focusParagraph(for: NSRange(location: p5.location + 3, length: 0))
            t.check(ns.substring(with: block5).hasPrefix("Paragraph 5 has") && ns.substring(with: block5).hasSuffix("paragraph 5.\n"), "the paragraph at the caret: both lines of it, up to the blank line: \(ns.substring(with: block5).debugDescription)")
            t.equal(host.focusParagraph(for: NSRange(location: 0, length: 0)), NSRange(location: 0, length: 8), "the heading alone (a blank line follows)")
            let blank = ns.range(of: "\n\nParagraph 2").location + 1
            t.equal(host.focusParagraph(for: NSRange(location: blank, length: 0)), NSRange(location: blank, length: 1), "a blank line: only itself")
            let p6 = ns.range(of: "Paragraph 6")
            let two = host.focusParagraph(for: NSRange(location: p5.location, length: p6.location + 5 - p5.location))
            t.check(two.location == block5.location && NSMaxRange(two) > p6.location, "a selection over two paragraphs keeps both")
            // Focus Mode on: the text view's focus range follows the caret, nothing is restyled
            tv.setSelectedRange(NSRange(location: p5.location + 3, length: 0))
            let runsBefore = host.styler.appliedRunCount
            host.luftigToggleFocusMode(nil)
            t.check(EditorPreferences.focusMode, "View > Focus Mode switches the preference on")
            t.equal(etv.focusRange, block5, "the text view focuses the caret's paragraph")
            let item = NSMenuItem(title: "Focus Mode", action: #selector(LuftigEditorActions.luftigToggleFocusMode(_:)), keyEquivalent: "")
            _ = host.validateMenuItem(item)
            t.check(item.state == .on, "the menu item is checked")
            tv.setSelectedRange(NSRange(location: p6.location + 2, length: 0))
            t.check(etv.focusRange?.location == p6.location, "the caret in the next paragraph: the focus moves")
            t.equal(host.styler.appliedRunCount, runsBefore, "no attributes were touched (the veil is drawn over the text)")
            assertMatchesFreshLex(t, host, "Focus Mode: the styled text still equals a fresh lex")
            // on pixels: the focused paragraph is darker (light appearance) than a veiled one
            host.view.window?.appearance = NSAppearance(named: .aqua)
            host.styler.styleVisible()
            func darkest(in r: NSRect) -> Double {
                guard let rep = tv.bitmapImageRepForCachingDisplay(in: tv.visibleRect) else { return 1 }
                tv.cacheDisplay(in: tv.visibleRect, to: rep)
                var min = 1.0
                let scale = CGFloat(rep.pixelsWide) / tv.visibleRect.width
                let x0 = Int((r.minX - tv.visibleRect.minX) * scale), x1 = Int((r.maxX - tv.visibleRect.minX) * scale)
                // the rep's rows run bottom-up (measured: the text view is flipped, the cached bitmap is not)
                let y0 = Int((tv.visibleRect.maxY - r.maxY) * scale), y1 = Int((tv.visibleRect.maxY - r.minY) * scale)
                var y = max(0, y0)
                while y < Swift.min(rep.pixelsHigh, y1) {
                    var x = max(0, x0)
                    while x < Swift.min(rep.pixelsWide, x1) {
                        if let c = rep.colorAt(x: x, y: y) { let l = Double(c.usingColorSpace(.sRGB)?.brightnessComponent ?? 1); if l < min { min = l } }
                        x += 2
                    }
                    y += 2
                }
                return min
            }
            /// The darkest pixel of every 23 pt band of the viewport (one body line each), top to bottom.
            func bands() -> [Double] {
                var out: [Double] = []
                var y: CGFloat = 0
                while y + 23 <= tv.visibleRect.height { out.append(darkest(in: NSRect(x: 20, y: y, width: 200, height: 23))); y += 23 }
                return out
            }
            let p3 = ns.range(of: "Paragraph 3").location
            tv.setSelectedRange(NSRange(location: p3 + 2, length: 0))                         // (paragraph 3 is in the viewport of a 500 pt window)
            var kept = 0, veiled = 0, draws = 0
            LuftigLayoutManager.veilLog = { _, _, k in if k { kept += 1 } else { veiled += 1 } }
            LuftigLayoutManager.drawLog = { _, _, _ in draws += 1 }
            let focused = bands()
            LuftigLayoutManager.veilLog = nil; LuftigLayoutManager.drawLog = nil
            t.check(draws > 0 && kept == 2 * draws && veiled > 10, "every glyph draw kept the two lines of the focused paragraph and veiled the others (\(draws) draws, \(kept) kept, \(veiled) veiled)")
            let dark = focused.filter { $0 < 0.4 }.count, faded = focused.filter { $0 > 0.55 && $0 < 0.9 }.count
            t.check(dark == 2 && faded >= 8, "pixels: exactly the two lines of the focused paragraph are dark, the other text lines are faded towards the page (\(dark) dark, \(faded) faded of \(focused.count) bands: \(focused.map { String(format: "%.2f", $0) }))")
            host.luftigToggleFocusMode(nil)
            t.check(!EditorPreferences.focusMode && etv.focusRange == nil, "off again: no focus range")
            let plain = bands()
            t.check(plain.filter { $0 < 0.4 }.count >= 10 && plain.filter { $0 > 0.55 && $0 < 0.9 }.isEmpty, "... and every text line is drawn in full colour again (\(plain.filter { $0 < 0.4 }.count) dark bands)")
            // Typewriter Mode: the inset makes room, the caret's line sits in the middle
            let clip = host.scrollView.contentView
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            host.luftigToggleTypewriterMode(nil)
            t.check(EditorPreferences.typewriterMode, "View > Typewriter Mode switches the preference on")
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
            host.luftigToggleTypewriterMode(nil)
            t.check(!EditorPreferences.typewriterMode && tv.textContainerInset.height == 0, "off again: no inset")
            // a second window follows both switches
            let (doc2, host2, _) = try await openEditor(t, text: "a\n\nb\n", name: "focus2.md")
            host.luftigToggleFocusMode(nil); host.luftigToggleTypewriterMode(nil)
            t.check(host2.editorTextView.focusRange != nil && host2.textView.textContainerInset.height > 0, "a second window follows both switches")
            host.luftigToggleFocusMode(nil); host.luftigToggleTypewriterMode(nil)
            t.check(host2.editorTextView.focusRange == nil && host2.textView.textContainerInset.height == 0, "... and back")
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
