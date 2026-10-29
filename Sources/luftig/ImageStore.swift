import AppKit
import ImageIO

// The images that documents show (ImageRender.swift): their sizes, read from the file's header when a line is styled (cheap: no pixels), and their
// pixels, decoded in the background at the size they are drawn at.
//
//   * A file on this Mac is checked again whenever its line is styled (one stat): a changed modification date or size reads the header again.
//   * A web image (Settings > General > Images: this Mac and the web) is downloaded once per run with an ephemeral session (no cookies, no cache on
//     disk), at most `maxDownloadBytes`; until it has arrived its line shows the Markdown, then every editor restyles (`didChange`, kind "size").
//   * Pixels: CGImageSourceCreateThumbnailAtIndex at the drawn size (orientation applied), in an NSCache bounded by bytes; when they are ready the
//     editors redraw (`didChange`, kind "pixels").
// Main thread, except the decoding and the download.
final class ImageStore {
    static let shared = ImageStore()
    /// object nil; userInfo["kind"] = "size" (a size became known or changed: restyle) or "pixels" (decoded pixels are ready: redraw).
    static let didChange = Notification.Name("LuftigImageStoreDidChange")
    static let maxDownloadBytes = 40_000_000

    /// The image's size in points (pixels at its resolution, orientation applied).
    struct Info: Equatable { var size: CGSize }

    private enum State { case ready(Info), loading, failed }
    private struct FileStamp: Equatable { var date: Date?; var size: Int }
    private var files: [URL: (stamp: FileStamp, state: State)] = [:]
    private var web: [URL: State] = [:]
    private var webData: [URL: Data] = [:]
    private let pixels = NSCache<NSString, CGImage>()
    private var decoding = Set<String>()
    private let queue = DispatchQueue(label: "local.luftig.images", qos: .userInitiated)
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    private init() { pixels.totalCostLimit = 256 * 1024 * 1024 }

    #if LUFTIG_SELFTEST
    /// Self-test only: the web addresses a download was started for.
    private(set) var requested: [URL] = []
    #endif

    /// The size of the image at `url`, or nil (not an image, missing, a web image that is not allowed or has not arrived yet).
    func info(for url: URL, web allowWeb: Bool) -> Info? {
        if url.isFileURL {
            let stamp = fileStamp(url)
            guard let stamp else { files[url] = nil; return nil }
            if let hit = files[url], hit.stamp == stamp {
                if case .ready(let i) = hit.state { return i }
                return nil
            }
            let state: State = ImageStore.readInfo(CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)).map { .ready($0) } ?? .failed
            files[url] = (stamp, state)
            if case .ready(let i) = state { return i }
            return nil
        }
        guard allowWeb, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        switch web[url] {
        case .ready(let i): return i
        case .loading, .failed: return nil
        case nil:
            web[url] = .loading
            download(url)
            return nil
        }
    }

    /// The pixels of the image at `url` for drawing `pixelWidth` pixels wide, or nil (they are decoded in the background: the editors redraw when ready).
    func image(for url: URL, pixelWidth: Int) -> CGImage? {
        let bucket = max(64, ((pixelWidth + 63) / 64) * 64)               // (a few sizes per image, not one per point of the window's width)
        let stamp = url.isFileURL ? files[url].map { "\($0.stamp.date?.timeIntervalSince1970 ?? 0)-\($0.stamp.size)" } ?? "" : ""
        let key = "\(url.absoluteString)|\(bucket)|\(stamp)"
        if let hit = pixels.object(forKey: key as NSString) { return hit }
        guard !decoding.contains(key) else { return nil }
        let source: CGImageSource?
        if url.isFileURL { source = CGImageSourceCreateWithURL(url as CFURL, nil) }
        else if let data = webData[url] { source = CGImageSourceCreateWithData(data as CFData, nil) }
        else { return nil }
        guard let source else { return nil }
        decoding.insert(key)
        queue.async { [weak self] in
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: bucket * 4, kCGImageSourceShouldCacheImmediately: true]
            let full = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            // the thumbnail is limited by its longer side: scale it to the bucket's width
            let image = full.flatMap { ImageStore.scaled($0, width: bucket) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.decoding.remove(key)
                if let image { self.pixels.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height) }
                NotificationCenter.default.post(name: ImageStore.didChange, object: nil, userInfo: ["kind": "pixels"])
            }
        }
        return nil
    }

    /// Forget what is known about files (the app became active again: an image may have been changed or added while it was not).
    func forgetFiles() { files.removeAll() }

    // MARK: -

    private func fileStamp(_ url: URL) -> FileStamp? {
        guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { return nil }
        return FileStamp(date: v.contentModificationDate, size: v.fileSize ?? 0)
    }

    private static func readInfo(_ source: CGImageSource?) -> Info? {
        guard let source, CGImageSourceGetCount(source) > 0,
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue, let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else { return nil }
        let dpi = max(72, (p[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72)
        let orientation = (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        var size = CGSize(width: w * 72 / dpi, height: h * 72 / dpi)
        if orientation >= 5 { size = CGSize(width: size.height, height: size.width) }      // (rotated a quarter turn)
        return Info(size: size)
    }

    private static func scaled(_ image: CGImage, width: Int) -> CGImage? {
        guard image.width > width else { return image }
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }

    private func download(_ url: URL) {
        #if LUFTIG_SELFTEST
        requested.append(url)
        #endif
        let task = session.dataTask(with: url) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let usable = ok && (data?.count ?? 0) > 0 && (data?.count ?? 0) <= ImageStore.maxDownloadBytes
            let info = usable ? ImageStore.readInfo(CGImageSourceCreateWithData(data! as CFData, nil)) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                if let info, let data { self.web[url] = .ready(info); self.webData[url] = data } else { self.web[url] = .failed }
                if info != nil { NotificationCenter.default.post(name: ImageStore.didChange, object: nil, userInfo: ["kind": "size"]) }
            }
        }
        task.resume()
    }
}
