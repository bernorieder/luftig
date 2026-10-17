#if LUFTIG_SELFTEST
// SelfTestVisualRedraw.swift - `visual-redraw`: after an edit AppKit repaints only the rows it invalidated. A decoration whose SHAPE depends on its
// neighbours (the rounded end of a band, the padding below the last line, a bar) must therefore not change anywhere outside those rows.
// The check: render the window before and after an edit, and ask the text view which rows it marked as needing display (NSView.needsToDraw);
// every row that differs between the two renders but was NOT marked is a stale row (it would keep showing the old pixels on screen).

import AppKit

extension SelfTestScenarios {
    static let visualRedrawScenarios: [SelfTest.Scenario] = [
        .init(name: "visual-redraw", summary: "after an edit every pixel row that changed was invalidated; a partial redraw of any strip equals the full redraw", run: { t in try await visualRedraw(t); try await visualPartial(t) }),
    ]

    /// Rows (device pixel rows of the bitmap) in which `a` and `b` differ.
    @MainActor private static func differingRows(_ a: ViewPixels, _ b: ViewPixels) -> [Int] {
        guard let da = a.rep.bitmapData, let db = b.rep.bitmapData, a.rep.pixelsHigh == b.rep.pixelsHigh, a.rep.pixelsWide == b.rep.pixelsWide else { return [] }
        let bytes = a.rep.pixelsWide * a.rep.samplesPerPixel
        var rows: [Int] = []
        for y in 0..<a.rep.pixelsHigh {
            if memcmp(da + y * a.rep.bytesPerRow, db + y * b.rep.bytesPerRow, bytes) != 0 { rows.append(y) }
        }
        return rows
    }

    /// Records the rectangles a view is told to repaint. Test-only: swaps the implementation of `-[NSView setNeedsDisplayInRect:]` (which NSTextView's
    /// own variant with avoidAdditionalLayout ends in) for the duration of the recording.
    @MainActor final class InvalidationRecorder {
        let view: NSView
        var rects: [NSRect] = []
        private var method: Method?
        nonisolated(unsafe) fileprivate static var original: IMP?
        nonisolated(unsafe) fileprivate static var current: InvalidationRecorder?
        init(view: NSView) { self.view = view }
        func start() {
            let sel = NSSelectorFromString("setNeedsDisplayInRect:")
            guard let m = class_getInstanceMethod(NSView.self, sel) else { return }
            method = m
            InvalidationRecorder.original = method_getImplementation(m)
            InvalidationRecorder.current = self
            let block: @convention(block) (AnyObject, NSRect) -> Void = { obj, rect in
                if let r = InvalidationRecorder.current, obj === r.view { r.rects.append(rect) }
                typealias Fn = @convention(c) (AnyObject, Selector, NSRect) -> Void
                if let orig = InvalidationRecorder.original { unsafeBitCast(orig, to: Fn.self)(obj, sel, rect) }
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        func stop() {
            if let m = method, let orig = InvalidationRecorder.original { method_setImplementation(m, orig) }
            method = nil
            InvalidationRecorder.current = nil
        }
    }

    /// A rectangle of the view drawn ON ITS OWN (what AppKit does after a small edit, while scrolling - only the exposed strip - and when the caret blinks)
    /// must equal the same rectangle of a full draw: nothing in the decorations may depend on what else is in the dirty rect (block ends, bars, panels,
    /// pills, rules, the selection). Strips of 1...47 pt at every 5 pt and caret-sized rects at several x, light + dark (+ Increase contrast), with a selection.
    @MainActor static func visualPartial(_ t: SelfTest.T) async throws {
        let text = """
        ---
        title: front matter
        ---

        # Heading `code`

        Paragraph with `inline code` and a pill that wraps around the end of the line because it is long: `a very long inline code span that has to wrap over the end of the line`, then more.

        > quote one
        > > nested two
        > > > nested three
        >
        > # heading in a quote
        > ---
        > ```swift
        > let x = 1
        > ```
        > - item

        ```
        code
        ```
        > quote right after code

        | a | b |
        |---|---|
        | 1 | 2 |

        ---

            indented code
            more

        > one
        > > two
        > three

        - [ ] task
        Last.
        """
        for (label, appearance, contrast, selection) in [("light", NSAppearance.Name.aqua, false, false), ("dark", .darkAqua, false, true), ("light + Increase contrast", .aqua, true, true)] {
            ContrastWatcher.shared.override = contrast
            defer { ContrastWatcher.shared.override = nil }
            let (doc, host, _) = try await openEditor(t, text: text, name: "partial.md", size: NSSize(width: 700, height: 1000))
            setAppearance(doc, appearance)
            host.styler.styleEverything()
            let tv = host.textView
            if selection { tv.setSelectedRange(NSRange(location: 60, length: 330)); LuftigLayoutManager.simulateActiveSelection = true }
            defer { LuftigLayoutManager.simulateActiveSelection = false }
            settle(host)
            let vis = tv.visibleRect
            guard let full = tv.bitmapImageRepForCachingDisplay(in: vis) else { t.check(false, "no bitmap"); return }
            tv.cacheDisplay(in: vis, to: full)
            guard let fd = full.bitmapData else { return }
            let scale = CGFloat(full.pixelsWide) / vis.width
            let o = tv.textContainerOrigin
            var bad = 0, rects = 0
            var firstBad = ""
            /// draws `r` alone and compares it with the same pixels of the full draw
            func compare(_ r: NSRect, _ what: String) {
                guard let rep = tv.bitmapImageRepForCachingDisplay(in: r), let sd = rep.bitmapData else { return }
                tv.cacheDisplay(in: r, to: rep)
                let x0 = Int(((r.minX - vis.minX) * scale).rounded()), y0 = Int(((r.minY - vis.minY) * scale).rounded())
                let spp = rep.samplesPerPixel
                rects += 1
                for row in 0..<rep.pixelsHigh {
                    for col in 0..<rep.pixelsWide where {
                        // the edge pixels of a shape can differ by one level between a clipped and an unclipped draw (anti-aliasing): not a difference
                        let a = sd + row * rep.bytesPerRow + col * spp, b = fd + (y0 + row) * full.bytesPerRow + (x0 + col) * full.samplesPerPixel
                        return abs(Int(a[0]) - Int(b[0])) > 2 || abs(Int(a[1]) - Int(b[1])) > 2 || abs(Int(a[2]) - Int(b[2])) > 2
                    }() {
                        bad += 1
                        let pa = sd + row * rep.bytesPerRow + col * spp, pb = fd + (y0 + row) * full.bytesPerRow + (x0 + col) * full.samplesPerPixel
                        let detail = "pixel \(x0 + col),\(y0 + row): alone (\(pa[0]),\(pa[1]),\(pa[2])), full draw (\(pb[0]),\(pb[1]),\(pb[2]))"
                        if firstBad.isEmpty { firstBad = "\(what) at x = \(Int(r.minX)), y = \(Int(r.minY - vis.minY)) pt, \(detail)" }
                        if SelfTest.flag("debug-strips") { t.info("\(label): \(what) x \(Int(r.minX)) y \(Int(r.minY - vis.minY)): \(detail)") }
                        return
                    }
                }
            }
            for height: CGFloat in [1, 3, 9, 24, 47] {
                var y = vis.minY
                while y + height <= vis.maxY { compare(NSRect(x: vis.minX, y: y, width: vis.width, height: height), "strip \(Int(height)) pt high"); y += 5 }
            }
            // what a blinking caret repaints: 2 x 23 pt at the start of the text, inside quote indents, in the middle
            for x in [o.x - 8, o.x, o.x + 14, o.x + 40, o.x + 200] {
                var y = vis.minY
                while y + 23 <= vis.maxY { compare(NSRect(x: x, y: y, width: 2, height: 23), "caret rect"); y += 5 }
            }
            t.check(bad == 0, "\(label): \(rects) rects (full-width strips of 1...47 pt, caret-sized) drawn on their own equal the full draw (\(bad) differ\(firstBad.isEmpty ? "" : ", first: " + firstBad))")
            t.close(doc)
        }
    }

    @MainActor static func visualRedraw(_ t: SelfTest.T) async throws {
        struct Case { let name: String; let text: String; let edit: (NSTextView, MarkdownDocument, SelfTest.T) -> Void }
        func at(_ s: String, _ needle: String) -> Int { (s as NSString).range(of: needle).location }
        let cases: [Case] = [
            Case(name: "a new line at the end of a quote", text: "Intro.\n\n> one\n> two\n\nTail.\n") { tv, doc, t in
                t.typeText("\n> three", into: doc, at: NSRange(location: at(tv.string, "two") + 3, length: 0)) },
            Case(name: "the marker removed from the last quote line", text: "Intro.\n\n> one\n> two\n\nTail.\n") { tv, doc, t in
                t.typeText("", into: doc, at: NSRange(location: at(tv.string, "> two"), length: 2)) },
            Case(name: "a quote marker typed in front of the paragraph below a quote", text: "> one\n> two\nTail.\n\nEnd.\n") { tv, doc, t in
                t.typeText("> ", into: doc, at: NSRange(location: at(tv.string, "Tail"), length: 0)) },
            Case(name: "a line added at the end of a code block", text: "Intro.\n\n```\ncode one\n```\n\nTail.\n") { tv, doc, t in
                t.typeText("code two\n", into: doc, at: NSRange(location: at(tv.string, "```\n\nTail"), length: 0)) },
            Case(name: "the last code line deleted", text: "Intro.\n\n```\ncode one\ncode two\n```\n\nTail.\n") { tv, doc, t in
                t.typeText("", into: doc, at: NSRange(location: at(tv.string, "code two\n"), length: 9)) },
            Case(name: "an indented line added below an indented code block", text: "Intro.\n\n    one\n    two\n\nTail.\n") { tv, doc, t in
                t.typeText("\n    three", into: doc, at: NSRange(location: at(tv.string, "two") + 3, length: 0)) },
            Case(name: "a table row added", text: "Intro.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nTail.\n") { tv, doc, t in
                t.typeText("\n| 3 | 4 |", into: doc, at: NSRange(location: at(tv.string, "| 1 | 2 |") + 9, length: 0)) },
            Case(name: "a heading typed (bigger line, the text below moves)", text: "Intro.\n\nText one.\n\n> quote\n") { tv, doc, t in
                t.typeText("# ", into: doc, at: NSRange(location: at(tv.string, "Text one"), length: 0)) },
        ]
        for c in cases {
            let (doc, host, _) = try await openEditor(t, text: c.text, name: "redraw.md", size: NSSize(width: 860, height: 500))
            setAppearance(doc, .aqua)
            host.styler.styleEverything()
            settle(host)
            let tv = host.textView
            guard let before = ViewPixels(tv) else { t.check(false, "no pixels"); return }
            // record every rectangle the text view is told to repaint while the edit happens (NSView.setNeedsDisplay(_:) and NSTextView's
            // variant with avoidAdditionalLayout, swizzled for the duration of the test)
            let recorder = InvalidationRecorder(view: tv)
            recorder.start()
            c.edit(tv, doc, t)
            settle(host)
            try await Task.sleep(nanoseconds: 60_000_000)                  // the styler's deferred work
            recorder.stop()
            let scale = before.scale
            var marked = [Bool](repeating: false, count: before.rep.pixelsHigh)
            for r in recorder.rects {
                let lo = max(0, Int(((r.minY - before.rect.minY) * scale).rounded(.down))), hi = min(marked.count, Int(((r.maxY - before.rect.minY) * scale).rounded(.up)))
                if lo < hi { for y in lo..<hi { marked[y] = true } }
            }
            let anyMarked = !recorder.rects.isEmpty
            guard let after = ViewPixels(tv) else { t.check(false, "no pixels"); return }
            let rows = differingRows(before, after)
            let stale = rows.filter { !marked[$0] }
            func span(_ r: [Int]) -> String { r.isEmpty ? "none" : String(format: "%.1f ... %.1f pt", Double(r.first!) / Double(scale), Double(r.last! + 1) / Double(scale)) }
            let markedRows = marked.indices.filter { marked[$0] }
            t.info("\(c.name): \(rows.count) pixel rows changed (\(span(rows))); marked for display: \(span(markedRows)) in \(recorder.rects.count) rects (any: \(anyMarked)); changed but NOT marked: \(stale.count) (\(span(stale)))")
            t.check(stale.isEmpty, "\(c.name): every changed pixel row was invalidated (stale rows: \(span(stale)))")
            t.close(doc)
        }
    }
}
#endif
