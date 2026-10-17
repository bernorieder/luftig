// make-icon.swift - draws the luftig app icon with CoreGraphics/CoreText (no image assets, deterministic).
//
//   swift Resources/make-icon.swift /path/to/AppIcon.iconset && iconutil -c icns /path/to/AppIcon.iconset -o Resources/AppIcon.icns
//
// Scripts/build-app.sh does this automatically when Resources/AppIcon.icns is missing or older than this file.
// Every size is rendered natively from vectors (no downscaling), so 16 px and 1024 px are both crisp.
//
// Design: macOS icon grid (body = 80.5 % of the canvas, continuous-ish 22.4 % corners), indigo gradient,
// a heavy rounded "M" followed by the down arrow of the Markdown mark, soft highlight and shadow.

import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

func renderIcon(pixels px: Int) -> Data {
    let s = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let margin = s * 0.0977
    let body = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let radius = body.width * 0.2237
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(red: 0, green: 0, blue: 0.1, alpha: 0.35))
    ctx.addPath(path); ctx.setFillColor(CGColor(red: 0.20, green: 0.22, blue: 0.62, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    // body gradient
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.42, green: 0.45, blue: 0.97, alpha: 1),     // top
        CGColor(red: 0.17, green: 0.19, blue: 0.62, alpha: 1),     // bottom
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
    // soft highlight on the upper half
    let hi = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 1, alpha: 0.20), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hi, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.midY), options: [])
    ctx.restoreGState()

    // thin inner rim
    ctx.saveGState()
    ctx.addPath(path); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18)); ctx.setLineWidth(max(1, s * 0.004)); ctx.strokePath()
    ctx.restoreGState()

    // glyph: "M↓"
    var font = NSFont.systemFont(ofSize: body.width * 0.50, weight: .heavy)
    if let d = font.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: body.width * 0.50) { font = f }
    let attr = NSAttributedString(string: "M↓", attributes: [
        .font: font,
        .foregroundColor: NSColor.white,
        .kern: -body.width * 0.012,
    ])
    let line = CTLineCreateWithAttributedString(attr)
    let b = CTLineGetImageBounds(line, ctx)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.014, color: CGColor(red: 0, green: 0, blue: 0.15, alpha: 0.35))
    ctx.textPosition = CGPoint(x: body.midX - b.midX, y: body.midY - b.midY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()

    let img = ctx.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <output.iconset>\n".utf8)); exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: outDir)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    try renderIcon(pixels: px).write(to: outDir.appendingPathComponent("\(name).png"))
}
print("wrote \(sizes.count) PNGs to \(outDir.path)")
