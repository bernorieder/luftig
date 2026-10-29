import AppKit
import MarkdownKit
import UniformTypeIdentifiers

// Images drawn in the text (Settings > General > Images; EditorPreferences.renderImages).
//
// A line that holds only an image (`![alt](path)`, spaces around it allowed; not in a quote, a list item or code) shows the image while neither the caret
// nor an end of a selection is on it - the same rule and the same machinery as a table drawn as a grid (TableRender.swift): the line's characters
// stay in the text with hidden glyphs (`.luftigImage`), the line is as tall as the image, the image is drawn with the decorations.
//
//   * Where: a path relative to the document's folder, an absolute path, `~/...`, a `file:` URL; `http(s):` only with "this Mac and the web". A
//     destination in angle brackets may hold spaces; percent escapes are decoded.
//   * Size: the image's own size in points (its resolution counted: a 144 dpi screenshot is half its pixels), never wider than the text column, never
//     taller than three quarters of the column's width (a tall screenshot would fill the window).
//   * Not drawn (shown as Markdown): an image in a sentence (TextKit 1 cannot give part of a line another height without a character in the text),
//     a missing or unreadable image, a web image until it has arrived, and a line without a line break (the last line of the text: a paragraph of
//     hidden glyphs alone gets no line fragment of its own).

extension NSAttributedString.Key {
    /// On every character of a line drawn as an image (its line break included): the ImageRenderLine to draw. Its glyphs are hidden.
    static let luftigImage = NSAttributedString.Key("luftig.image")
}

final class ImageRenderLine: NSObject {
    let url: URL
    /// The drawn size in points.
    let size: CGSize
    let alt: String
    init(url: URL, size: CGSize, alt: String) { self.url = url; self.size = size; self.alt = alt }
    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? ImageRenderLine else { return false }
        return url == o.url && size == o.size && alt == o.alt
    }
    override var hash: Int { url.hashValue }
    override var description: String { "image(\(url.lastPathComponent), \(Int(size.width))x\(Int(size.height)))" }
}

enum ImageRenderer {
    /// Room above and below the image.
    static let padY: CGFloat = 8

    /// The destination and the alt text of a line that holds only an image, or nil.
    static func imageLine(_ line: TableAligner.Line, lexRuns: [MDRun], text: NSString) -> (dest: String, alt: String)? {
        var a = line.start, b = line.end
        while a < b, text.character(at: a) == 0x20 || text.character(at: a) == 0x09 { a += 1 }
        while b > a, text.character(at: b - 1) == 0x20 || text.character(at: b - 1) == 0x09 { b -= 1 }
        guard b - a >= 5, text.character(at: a) == 0x21, text.character(at: a + 1) == 0x5B, text.character(at: b - 1) == 0x29 else { return nil }
        // every run of the line's text is the image, outside quotes and code
        var i = lexRuns.firstIndex { NSMaxRange($0.range) > a } ?? lexRuns.count
        while i < lexRuns.count && lexRuns[i].range.location < b {
            let run = lexRuns[i], s = run.style
            i += 1
            if s.quoteDepth > 0 || s.contains(.codeBlock) || s.contains(.codeFence) || s.contains(.listMarker) { return nil }
            if s.contains(.image) { continue }
            // (the space before a title, `![a](b "t")`, is not part of the image's runs)
            let lo = max(run.range.location, a), hi = min(NSMaxRange(run.range), b)
            for p in lo..<max(lo, hi) where text.character(at: p) != 0x20 && text.character(at: p) != 0x09 { return nil }
        }
        let body = text.substring(with: NSRange(location: a + 2, length: b - 1 - (a + 2))) as NSString      // alt](dest "title"
        let split = body.range(of: "](")
        guard split.location != NSNotFound else { return nil }
        let alt = body.substring(to: split.location)
        var dest = body.substring(from: NSMaxRange(split)).trimmingCharacters(in: .whitespaces)
        if dest.hasPrefix("<") {
            guard let close = dest.firstIndex(of: ">") else { return nil }
            dest = String(dest[dest.index(after: dest.startIndex)..<close])
        } else if let space = dest.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            dest = String(dest[..<space])
        }
        guard !dest.isEmpty, !dest.contains("](") else { return nil }
        return (dest, alt)
    }

    /// The image the destination names, relative to `base` (the document's folder), or nil.
    static func resolve(_ dest: String, base: URL?) -> URL? {
        if let u = URL(string: dest), let scheme = u.scheme?.lowercased(), scheme.count > 1 {
            return ["http", "https", "file"].contains(scheme) ? u : nil
        }
        let path = dest.removingPercentEncoding ?? dest
        if path.hasPrefix("~/") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard let base else { return nil }
        return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
    }

    /// The drawn size: the image's own, at most `available` wide and three quarters of that tall.
    static func drawnSize(_ info: ImageStore.Info, available: CGFloat) -> CGSize {
        var w = min(info.size.width, available), h = info.size.height * w / max(1, info.size.width)
        let cap = max(120, available * 0.75)
        if h > cap { w = w * cap / h; h = cap }
        return CGSize(width: max(1, w.rounded()), height: max(1, h.rounded()))
    }

    /// Draws the image of a line whose line fragment is `rect` (view coordinates), from `left`; a quiet box until its pixels are decoded.
    static func draw(_ line: ImageRenderLine, rect: CGRect, left: CGFloat, ctx: CGContext, placeholder: CGColor, scale: CGFloat) {
        let r = CGRect(x: left, y: rect.minY + padY, width: line.size.width, height: line.size.height)
        if let image = ImageStore.shared.image(for: line.url, pixelWidth: Int((line.size.width * scale).rounded(.up))) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).addClip()
            NSImage(cgImage: image, size: line.size).draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                                                         hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
            NSGraphicsContext.restoreGraphicsState()
        } else {
            ctx.setFillColor(placeholder)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
        }
    }
}

// MARK: - dropping images into the text

/// Images dropped into the text (or web images dragged from a browser) become Markdown image links, each on a line of its own:
/// `![name](path)` with the path relative to the document's folder (`../` where needed; absolute when nothing but `/` is shared, or for an untitled
/// document), in angle brackets when it holds spaces or parentheses. The file is linked where it is, not copied.
enum ImageDrop {
    /// Web images by their extension (a browser drags the image's address).
    static let webExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg", "avif"]

    static func isImage(_ url: URL) -> Bool {
        if url.isFileURL { return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false }
        guard let s = url.scheme?.lowercased(), s == "http" || s == "https" else { return false }
        return webExtensions.contains(url.pathExtension.lowercased())
    }

    static func markdown(for url: URL, documentFolder: URL?) -> String {
        var alt = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.deletingPathExtension().lastPathComponent
        alt = alt.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        var dest = url.isFileURL ? (documentFolder.map { relativePath(from: $0, to: url) } ?? url.path) : url.absoluteString
        if dest.contains(where: { $0 == " " || $0 == "(" || $0 == ")" || $0 == "\t" }) { dest = "<\(dest)>" }
        return "![\(alt)](\(dest))"
    }

    /// `file`'s path from `folder`: `name.png`, `img/name.png`, `../shared/name.png`; the absolute path when the two share nothing but the root.
    static func relativePath(from folder: URL, to file: URL) -> String {
        let a = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let b = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var i = 0
        while i < a.count && i < b.count && a[i] == b[i] { i += 1 }
        if i <= 1 { return file.path }
        return (Array(repeating: "..", count: a.count - i) + Array(b[i...])).joined(separator: "/")
    }
}
