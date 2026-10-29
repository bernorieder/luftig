#if LUFTIG_SELFTEST
// SelfTestImageRender.swift - image-render: lines that hold only an image show the image (ImageRender.swift, Settings > General > Images).
//   the size (the image's points, its resolution counted; never wider than the column, never taller than 3/4 of it), hidden glyphs and the line's
//   height, the pixels decoded in the background; not drawn: an image in a sentence, in a quote or a list item, a missing file, a web image with
//   "this Mac" (and no download is started); paths relative / in angle brackets / percent-encoded / absolute; the caret on the line and a click show
//   the Markdown; the switch; dropping image files inserts `![name](path)` lines (relative paths, angle brackets, one undo step); == a fresh restyle.

import AppKit
import MarkdownKit

extension SelfTestScenarios {
    static let imageRenderScenarios: [SelfTest.Scenario] = [
        .init(name: "image-render", summary: "images on lines of their own drawn while the caret is elsewhere: size, hidden glyphs, where not, paths, the caret and a click, the switch, dropped files, == a fresh restyle", run: { t in try await imageRender(t) }),
    ]

    /// A plain PNG of `width` x `height` pixels at `dpi`, in the scenario's folder.
    @MainActor static func writePNG(_ t: SelfTest.T, _ name: String, width: Int, height: Int, dpi: Double = 72) -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: Double(width) * 72 / dpi, height: Double(height) * 72 / dpi)
        return t.write(data: rep.representation(using: .png, properties: [:])!, to: name)
    }

    @MainActor static func imageAt(_ host: EditorViewController, _ needle: String) -> ImageRenderLine? {
        let loc = (host.textView.string as NSString).range(of: needle).location
        guard loc != NSNotFound else { return nil }
        return host.textView.textStorage?.attribute(.luftigImage, at: loc, effectiveRange: nil) as? ImageRenderLine
    }

    @MainActor static func imageRender(_ t: SelfTest.T) async throws {
        let mode = EditorPreferences.renderImages
        EditorPreferences.renderImages = .local
        defer { EditorPreferences.renderImages = mode }
        let pic = writePNG(t, "pic.png", width: 400, height: 200)
        _ = writePNG(t, "retina.png", width: 800, height: 400, dpi: 144)
        _ = writePNG(t, "wide.png", width: 3000, height: 600)
        _ = writePNG(t, "tall.png", width: 300, height: 3000)
        _ = writePNG(t, "with space.png", width: 100, height: 50)
        let text = """
        # Images

        ![pic](pic.png)

        ![retina](retina.png)

        ![wide](wide.png)

        ![tall](tall.png "a title")

        ![spaced](<with space.png>)

        ![encoded](with%20space.png)

        ![absolute](\(pic.path))

        A sentence with ![inline](pic.png) in it.

        > ![quoted](pic.png)

        - ![listed](pic.png)

        ![missing](nope.png)

        ![web](https://example.com/luftig-test.png)

        The end.

        """
        let (doc, host, url) = try await openEditor(t, text: text, name: "images.md", size: NSSize(width: 1000, height: 900))
        await t.spin(30)
        let tv = host.textView
        host.styler.styleEverything()
        let limit = host.provider.tables.widthLimit

        // ---- what is drawn, at what size
        t.equal(imageAt(host, "![pic]")?.size, CGSize(width: 400, height: 200), "an image on a line of its own: drawn at its own size")
        t.equal(imageAt(host, "![retina]")?.size, CGSize(width: 400, height: 200), "a 144 dpi image: half its pixels")
        if let w = imageAt(host, "![wide]") { t.check(abs(w.size.width - limit) <= 1 && abs(w.size.height - (limit / 5).rounded()) <= 1, "a wide image: as wide as the column (\(w.size), column \(limit))") } else { t.check(false, "the wide image is drawn") }
        if let h = imageAt(host, "![tall]") { t.check(abs(h.size.height - (limit * 0.75).rounded()) <= 1, "a tall image: three quarters of the column's width tall (\(h.size))") } else { t.check(false, "the tall image (with a title) is drawn") }
        t.equal(imageAt(host, "![spaced]")?.size, CGSize(width: 100, height: 50), "a path in angle brackets with a space")
        t.equal(imageAt(host, "![encoded]")?.size, CGSize(width: 100, height: 50), "a percent-encoded path")
        t.equal(imageAt(host, "![absolute]")?.size, CGSize(width: 400, height: 200), "an absolute path")
        for (needle, what) in [("![inline]", "an image in a sentence"), ("![quoted]", "an image in a quote"), ("![listed]", "an image in a list item"),
                               ("![missing]", "a missing image"), ("![web]", "a web image with \"this Mac\"")] {
            t.check(imageAt(host, needle) == nil, "\(what): Markdown")
        }
        t.check(!ImageStore.shared.requested.contains { $0.host == "example.com" }, "... and no download was started")
        let picLine = (tv.string as NSString).range(of: "![pic]").location
        t.check(glyphIsHidden(host, at: picLine + 3), "the image line's characters have no glyphs")
        t.equal(fragment(host, at: picLine).height, 200 + 2 * ImageRenderer.padY, "the line is as tall as the image")
        assertMatchesFreshLex(t, host, "images drawn")
        // the pixels arrive in the background, at the drawn size
        _ = ImageStore.shared.image(for: pic, pixelWidth: 800)
        await t.spin(300)
        t.check(ImageStore.shared.image(for: pic, pixelWidth: 800) != nil, "the pixels are decoded in the background")

        // ---- the caret on the line: the Markdown; off it: the image; a click on the image: the Markdown, the caret at the line's end
        tv.setSelectedRange(NSRange(location: picLine + 2, length: 0))
        await t.spin(20)
        t.check(imageAt(host, "![pic]") == nil && !glyphIsHidden(host, at: picLine + 3), "the caret on the line: its Markdown")
        assertMatchesFreshLex(t, host, "an image line with the caret")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        await t.spin(20)
        t.check(imageAt(host, "![pic]") != nil, "the caret gone: the image")
        let f = fragment(host, at: picLine), o = tv.textContainerOrigin
        t.check(host.clickIntoTable(at: NSPoint(x: o.x + f.minX + 50, y: o.y + f.midY)), "a click on the image is taken")
        await t.spin(20)
        t.equal(tv.selectedRange().location, picLine + ("![pic](pic.png)" as NSString).length, "... the caret at the end of its line")
        t.check(imageAt(host, "![pic]") == nil, "... which shows its Markdown")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        await t.spin(20)

        // ---- the switch
        EditorPreferences.renderImages = .never
        await t.spin(20)
        host.styler.styleEverything()
        t.check(imageAt(host, "![pic]") == nil, "Images: Never: Markdown")
        assertMatchesFreshLex(t, host, "images off")
        EditorPreferences.renderImages = .local
        await t.spin(20)
        host.styler.styleEverything()
        t.check(imageAt(host, "![pic]") != nil, "Images: this Mac: drawn again")

        // ---- dropping image files: `![name](path)` lines, relative to the document's folder, one undo step
        let folder = url.deletingLastPathComponent()
        t.equal(ImageDrop.relativePath(from: folder, to: folder.appendingPathComponent("img/a.png")), "img/a.png", "relative path: a subfolder")
        t.equal(ImageDrop.relativePath(from: folder.appendingPathComponent("docs"), to: folder.appendingPathComponent("img/a.png")), "../img/a.png", "relative path: a sibling folder")
        t.equal(ImageDrop.markdown(for: folder.appendingPathComponent("with space.png"), documentFolder: folder), "![with space](<with space.png>)", "a name with a space: in angle brackets")
        t.equal(ImageDrop.markdown(for: URL(string: "https://example.com/a.png")!, documentFolder: folder), "![a](https://example.com/a.png)", "a web image dropped from a browser")
        t.check(ImageDrop.isImage(pic) && !ImageDrop.isImage(url) && ImageDrop.isImage(URL(string: "https://x.org/b.jpg")!) && !ImageDrop.isImage(URL(string: "https://x.org/page")!), "what counts as an image")
        let before = tv.string
        let mid = (tv.string as NSString).range(of: "A sentence with").location + 2
        t.check(host.insertImageLinks([pic, folder.appendingPathComponent("with space.png")], at: mid), "dropped files are taken")
        await t.spin(20)
        t.check(tv.string.contains("A \n![pic](pic.png)\n![with space](<with space.png>)\nsentence with"), "... inserted as lines of their own (\((tv.string as NSString).substring(with: NSRange(location: mid - 2, length: 70)).debugDescription))")
        host.styler.styleEverything()
        t.check(imageAt(host, "![with space](<with") != nil, "... and drawn")
        assertMatchesFreshLex(t, host, "after a drop")
        tv.undoManager?.undo()
        await t.spin(20)
        t.equal(tv.string, before, "one Undo removes them")

        // ---- the file
        doc.updateChangeCount(.changeDone)
        let saved: Error? = await withCheckedContinuation { c in doc.save(to: url, ofType: doc.fileType ?? "net.daringfireball.markdown", for: .saveOperation) { c.resume(returning: $0) } }
        t.check(saved == nil && (try? String(contentsOf: url, encoding: .utf8)) == tv.string, "the saved file is the Markdown")
        t.close(doc)
    }
}
#endif
