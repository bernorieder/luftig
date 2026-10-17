import AppKit

let sampleMarkdown = #"""
# Scribe: a visual Markdown editor

Plain paragraph with **bold**, *italic*, ~~strike~~, `inline code`, and a [link](https://example.com/path). Another sentence follows with `code_span()` and enough text to wrap onto a second line in a narrow window.

## Block quotes

> A block quote with **strong** text and some `inline code` inside it.
> The second line of the same quote is long enough that it wraps onto another visual line when the window is narrow.

Back to normal text between two quotes.

> A second quote, separated by a blank line.

### Fenced code

```swift
func greet(_ name: String) -> String {
    let message = "Hello, \(name)!"   // trailing comment

    return message
}
```
Text directly after a code block.

---

## Lists and a table

- list item one with `code`
- [ ] open task
- [x] done task
1. numbered item

| Name | Value |
|------|:-----:|
| a    | 1     |

#### Heading right before code
```sh
$ echo "done"
```

> quote after code

Final paragraph with a `last` pill and more text so that the paragraph is a bit longer than one line when the window is narrow.
"""#

let snapshotDir = "/Users/rieder/Developer/Scribe/docs/spike-textkit-code/snapshots"
nonisolated(unsafe) var snapshotSuffix = ""

extension Harness {
    /// y (view coordinates) of the line containing character `idx` (engine independent; 1-char range avoids boundary ambiguity).
    func yOfChar(_ idx: Int) -> CGFloat {
        let len = max(0, min(1, storage.length - idx))
        let sr = textView.firstRect(forCharacterRange: NSRange(location: idx, length: len), actualRange: nil)
        let wr = window.convertFromScreen(sr)
        return textView.convert(wr, from: nil).minY
    }
    func heightOfChar(_ idx: Int) -> CGFloat {
        let len = max(0, min(1, storage.length - idx))
        let sr = textView.firstRect(forCharacterRange: NSRange(location: idx, length: len), actualRange: nil)
        let wr = window.convertFromScreen(sr)
        return textView.convert(wr, from: nil).height
    }
}

/// Re-lex and re-style the whole (small) document in the storage.
func restyleAll(_ h: Harness, theme: Theme) {
    let doc = Doc(h.storage.string)
    Styler.style(doc: doc, range: NSRange(location: 0, length: doc.length), storage: h.storage, theme: theme)
}

func makeSampleView(engine: Engine, appearance: NSAppearance.Name, width: CGFloat = 720, height: CGFloat = 640, theme: Theme, text: String = sampleMarkdown, inset: NSSize = NSSize(width: 28, height: 16)) -> Harness {
    var o = HarnessOptions()
    o.width = width; o.height = height; o.appearance = appearance; o.inset = inset
    let h = Harness(engine: engine, options: o)
    h.textView.font = theme.bodyFont
    h.textView.textColor = Palette.text
    h.textView.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
    h.textView.string = text
    restyleAll(h, theme: theme)
    h.layoutVisible()
    return h
}

struct Pixels {
    let rep: NSBitmapImageRep
    var w: Int { rep.pixelsWide }
    var hgt: Int { rep.pixelsHigh }
    func rgba(_ x: Int, _ y: Int) -> [UInt8] {
        guard x >= 0, y >= 0, x < w, y < hgt, let d = rep.bitmapData else { return [0, 0, 0, 0] }
        let bpp = rep.bitsPerPixel / 8
        let o = y * rep.bytesPerRow + x * bpp
        return Array(UnsafeBufferPointer(start: d + o, count: min(4, bpp)))
    }
    func same(_ a: [UInt8], _ b: [UInt8], tol: Int = 2) -> Bool {
        zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= tol }
    }
}

func snapshot(_ h: Harness) -> NSBitmapImageRep {
    let rep = h.scroll.bitmapImageRepForCachingDisplay(in: h.scroll.bounds)!
    h.scroll.cacheDisplay(in: h.scroll.bounds, to: rep)
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, _ name: String) {
    try? FileManager.default.createDirectory(atPath: snapshotDir, withIntermediateDirectories: true)
    if let d = rep.representation(using: .png, properties: [:]) {
        try? d.write(to: URL(fileURLWithPath: "\(snapshotDir)/\(name)\(snapshotSuffix).png"))
    }
}

/// Pixel difference between two snapshots: (number of differing pixels, max channel delta).
func pixelDiff(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (Int, Int) {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, let da = a.bitmapData, let db = b.bitmapData else { return (-1, -1) }
    var n = 0, mx = 0
    let bpp = a.bitsPerPixel / 8
    for y in 0..<a.pixelsHigh {
        for x in 0..<a.pixelsWide {
            let oa = y * a.bytesPerRow + x * bpp, ob = y * b.bytesPerRow + x * bpp
            var d = 0
            for c in 0..<min(3, bpp) { d = max(d, abs(Int(da[oa + c]) - Int(db[ob + c]))) }
            if d > 0 { n += 1; mx = max(mx, d) }
        }
    }
    return (n, mx)
}

/// Programmatic band checks on a snapshot: left / right band edge (points, in view space) and vertical uniformity in the margin column.
struct BandProbe {
    var leftEdgePt = -1.0, rightEdgePt = -1.0
    var gapRows = 0            // rows inside the band where the margin pixel differs from the band colour
    var rows = 0
}

func probeBand(_ rep: NSBitmapImageRep, h: Harness, codeCharRange: NSRange, scale: CGFloat = 2) -> BandProbe {
    var r = BandProbe()
    let px = Pixels(rep: rep)
    let clipY = h.visibleRect.minY
    let yTop = h.yOfChar(codeCharRange.location) - clipY
    let lastIdx = NSMaxRange(codeCharRange) - 1
    let yBot = h.yOfChar(lastIdx) + h.heightOfChar(lastIdx) - clipY
    guard yBot > yTop else { return r }
    // background colour: far left column pixel outside any band, at the first text line
    let bg = px.rgba(2, Int((yTop + yBot) / 2 * scale))
    // left edge: scan from x=0 at mid-height, first pixel that differs from bg
    let midY = Int((yTop + yBot) / 2 * scale)
    var x = 0
    while x < px.w, px.same(px.rgba(x, midY), bg) { x += 1 }
    r.leftEdgePt = Double(x) / Double(scale)
    var xr = px.w - 1
    while xr > 0, px.same(px.rgba(xr, midY), bg) { xr -= 1 }
    r.rightEdgePt = Double(xr + 1) / Double(scale)
    // margin column: 4pt inside the left edge. Every row strictly inside the band (excluding rounded corners) must have the same colour.
    let colX = x + Int(4 * scale)
    let ref = px.rgba(colX, midY)
    var y = Int((yTop + 8) * scale)
    let yEnd = Int((yBot - 8) * scale)
    while y < yEnd {
        r.rows += 1
        if !px.same(px.rgba(colX, y), ref) { r.gapRows += 1 }
        y += 1
    }
    return r
}

func runDraw(_ rest: [String]) {
    func arg(_ n: String, _ d: String) -> String { if let i = rest.firstIndex(of: "--" + n), i + 1 < rest.count { return rest[i + 1] }; return d }
    let engines = Engine.parse(arg("engine", "tk1n,tk2"))
    let uniform = rest.contains("--uniform")
    let theme = uniform ? Theme(uniformLineHeight: 21, uniformHeadings: true) : Theme()
    if uniform { snapshotSuffix = "-uniform" }
    let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
    let ns = sampleMarkdown as NSString
    let fenceStart = ns.range(of: "```swift").location
    let fenceEnd = NSMaxRange(ns.range(of: "}\n```\n")) // after closing fence line
    let codeRange1 = NSRange(location: fenceStart, length: fenceEnd - fenceStart)

    log("### visual marking: snapshots in \(snapshotDir)")
    log("| engine | appearance | case | band left edge pt | band right edge pt | margin-column rows / rows differing (gaps) |")
    log("|---|---|---|---|---|---|")
    for engine in engines {
        for (aname, app) in appearances {
            // basic
            do {
                let h = makeSampleView(engine: engine, appearance: app, theme: theme)
                _ = h.drawVisible()
                let rep = snapshot(h)
                writePNG(rep, "\(engine.rawValue)-\(aname)-basic")
                let p = probeBand(rep, h: h, codeCharRange: codeRange1)
                log("| \(engine.rawValue) | \(aname) | basic | \(f1(p.leftEdgePt)) | \(f1(p.rightEdgePt)) | \(p.rows) / \(p.gapRows) |")
                h.window.contentView = nil
            }
            // selection across prose -> quote -> code
            do {
                let h = makeSampleView(engine: engine, appearance: app, theme: theme)
                let start = ns.range(of: "Another sentence").location
                let end = fenceStart + 60
                h.textView.setSelectedRange(NSRange(location: start, length: end - start))
                h.layoutVisible()
                let rep = snapshot(h)
                writePNG(rep, "\(engine.rawValue)-\(aname)-selection")
                h.window.contentView = nil
            }
            // scrolled: code block straddles the top edge
            do {
                let h = makeSampleView(engine: engine, appearance: app, height: 420, theme: theme)
                let mid = fenceStart + 70
                let y = h.yOfChar(mid)
                h.scrollTo(y: y - 24)
                h.layoutVisible()
                let rep = snapshot(h)
                writePNG(rep, "\(engine.rawValue)-\(aname)-scrolled")
                let p = probeBand(rep, h: h, codeCharRange: NSRange(location: mid, length: 40))
                log("| \(engine.rawValue) | \(aname) | scrolled (block cut by top edge) | \(f1(p.leftEdgePt)) | \(f1(p.rightEdgePt)) | \(p.rows) / \(p.gapRows) |")
                h.window.contentView = nil
            }
            // narrow window (wrapped paragraphs)
            do {
                let h = makeSampleView(engine: engine, appearance: app, width: 420, height: 700, theme: theme)
                let rep = snapshot(h)
                writePNG(rep, "\(engine.rawValue)-\(aname)-narrow")
                h.window.contentView = nil
            }
            // editing: extend the code block (insert a line), then delete the closing fence of the sh block
            do {
                let h = makeSampleView(engine: engine, appearance: app, theme: theme)
                let hc = HighlightController(theme: theme)
                _ = hc
                let idx = ns.range(of: "    return message").location
                h.textView.setSelectedRange(NSRange(location: idx, length: 0))
                h.textView.insertText("    let extra = 42\n", replacementRange: NSRange(location: NSNotFound, length: 0))
                restyleAll(h, theme: theme)
                h.layoutVisible()
                // remove the closing fence of the "sh" block -> the rest of the document becomes code (unclosed fence)
                let cur = h.storage.string as NSString
                let shOpen = cur.range(of: "```sh")
                let close = cur.range(of: "```\n", options: [], range: NSRange(location: shOpen.location + 5, length: cur.length - shOpen.location - 5))
                h.textView.insertText("", replacementRange: close)
                restyleAll(h, theme: theme)
                h.layoutVisible()
                h.scrollTo(y: h.yOfChar(shOpen.location) - 300)
                h.layoutVisible()
                let edited = snapshot(h)
                writePNG(edited, "\(engine.rawValue)-\(aname)-edited")
                // fresh view of the identical final text (incremental vs fresh must be pixel identical)
                let fresh = makeSampleView(engine: engine, appearance: app, theme: theme, text: h.storage.string)
                fresh.scrollTo(y: h.visibleRect.minY)
                fresh.layoutVisible()
                let freshRep = snapshot(fresh)
                let (n, mx) = pixelDiff(edited, freshRep)
                log("| \(engine.rawValue) | \(aname) | edited vs fresh render: differing pixels / max delta | \(n) | \(mx) | |")
                h.window.contentView = nil
                fresh.window.contentView = nil
            }
        }
    }

    // Partial redraw: the text view is drawn in two independent strips (what AppKit does after scrolling / invalidating a region);
    // the result must equal the full draw, in particular where a strip boundary cuts through a code block or quote.
    log("\n### partial-redraw seam test (full draw vs two independent strips, boundary cutting through the code block)")
    log("| engine | appearance | split y (pt from top) | differing pixels | max channel delta |")
    log("|---|---|---|---|---|")
    for engine in engines {
        for (aname, app) in appearances {
            let h = makeSampleView(engine: engine, appearance: app, theme: theme)
            let full = snapshot(h)
            let W = h.scroll.bounds.width, H = h.scroll.bounds.height
            for split in [CGFloat(396), CGFloat(417.5), CGFloat(452)] {
                let s2 = Int(split * 2)
                let fl = h.scroll.isFlipped
                let top = fl ? NSRect(x: 0, y: 0, width: W, height: split) : NSRect(x: 0, y: H - split, width: W, height: split)
                let bottom = fl ? NSRect(x: 0, y: split, width: W, height: H - split) : NSRect(x: 0, y: 0, width: W, height: H - split)
                let r1 = h.scroll.bitmapImageRepForCachingDisplay(in: top)!
                h.scroll.cacheDisplay(in: top, to: r1)
                let r2 = h.scroll.bitmapImageRepForCachingDisplay(in: bottom)!
                h.scroll.cacheDisplay(in: bottom, to: r2)
                if rest.contains("--debug-strips") && aname == "light" {
                    try? r1.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(Corpus.dir)/../out/strip-top-\(engine.rawValue).png"))
                    try? r2.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(Corpus.dir)/../out/strip-bottom-\(engine.rawValue).png"))
                    log("full \(full.pixelsWide)x\(full.pixelsHigh) bpp \(full.bitsPerPixel) bpr \(full.bytesPerRow); r1 \(r1.pixelsWide)x\(r1.pixelsHigh) bpr \(r1.bytesPerRow); r2 \(r2.pixelsWide)x\(r2.pixelsHigh); flipped scroll=\(h.scroll.isFlipped)")
                }
                var n = 0, mx = 0
                let bpp = full.bitsPerPixel / 8
                for y in 0..<full.pixelsHigh {
                    let (src, sy): (NSBitmapImageRep, Int) = y < s2 ? (r1, y) : (r2, y - s2)
                    guard sy < src.pixelsHigh, let da = full.bitmapData, let db = src.bitmapData else { continue }
                    for x in 0..<full.pixelsWide {
                        let oa = y * full.bytesPerRow + x * bpp, ob = sy * src.bytesPerRow + x * bpp
                        var d = 0
                        for c in 0..<3 { d = max(d, abs(Int(da[oa + c]) - Int(db[ob + c]))) }
                        if d > 0 { n += 1; mx = max(mx, d) }
                    }
                }
                log("| \(engine.rawValue) | \(aname) | \(split) | \(n) | \(mx) |")
            }
            h.window.contentView = nil
        }
    }

    // Draw cost of the decoration pass itself
    log("\n### decoration draw cost (first screen of the 1 MB corpus, cacheDisplay of the visible area, median of 15)")
    log("| engine | decorations | draw ms |")
    log("|---|---|---|")
    let text = Corpus.load("1m")
    let doc = Doc(text)
    for engine in engines {
        for deco in [false, true] {
            var o = HarnessOptions(); o.decorate = deco
            let h = Harness(engine: engine, options: o)
            h.textView.font = theme.bodyFont
            h.textView.string = text
            h.layoutVisible()
            h.styleViewport(doc: doc, theme: theme)
            h.layoutVisible()
            _ = h.snapshotRep
            var t: [Double] = []
            for _ in 0..<15 { t.append(h.drawVisible()) }
            log("| \(engine.rawValue) | \(deco ? "on" : "off") | \(f2(Stats(Array(t.dropFirst(3))).median)) |")
            h.window.contentView = nil
        }
    }
}
