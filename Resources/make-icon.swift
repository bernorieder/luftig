// make-icon.swift - draws the luftig app icon with CoreGraphics (no image assets, deterministic).
//
//   swift Resources/make-icon.swift /path/to/AppIcon.iconset && iconutil -c icns /path/to/AppIcon.iconset -o Resources/AppIcon.icns
//
// Scripts/build-app.sh --regen-icon does this (the committed Resources/AppIcon.icns is otherwise copied as it is).
// Every size is rendered natively from vectors (no downscaling), so 16 px and 1024 px are both crisp.
//
// Design ("air"): the macOS icon grid (body = 80.5 % of the canvas, continuous-ish 22.4 % corners), a near-white page with a cool
// cast, and a short block of text set in generous white space - an indigo heading bar and three grey text bars, the last two of
// which end in the small upward curl of a breeze (the "luftig" in it). Nothing else: the white space is the subject.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func renderIcon(pixels px: Int) -> Data {
    let s = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }

    let margin = s * 0.0977
    let body = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let radius = body.width * 0.2237
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    let w = body.width

    // drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: rgb(0, 0, 0.1, 0.28))
    ctx.addPath(path); ctx.setFillColor(rgb(0.90, 0.92, 0.98)); ctx.fillPath()
    ctx.restoreGState()

    // the page: white with a cool cast towards the bottom
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [rgb(0.985, 0.985, 1.0), rgb(0.90, 0.92, 0.98)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
    ctx.restoreGState()

    // thin inner rim
    ctx.saveGState()
    ctx.addPath(path); ctx.setStrokeColor(rgb(1, 1, 1, 0.5)); ctx.setLineWidth(max(1, s * 0.004)); ctx.strokePath()
    ctx.restoreGState()

    // the text block: a heading bar (indigo) and three text bars (grey), left-aligned, bigger than the page's air around them is small
    let indigo = rgb(0.20, 0.23, 0.62)
    let grey = rgb(0.58, 0.61, 0.72)
    let x = body.minX + w * 0.24
    let h = w * 0.075                                     // a text bar's height
    let gap = w * 0.115                                   // from one bar's bottom to the next one's
    func bar(_ y: CGFloat, width: CGFloat, height: CGFloat, _ color: CGColor) {
        let r = CGRect(x: x, y: y, width: width, height: height)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)); ctx.setFillColor(color); ctx.fillPath()
    }
    /// A text bar whose end turns into the small curl of a breeze: a thinner stroke that leaves the bar's end and bends up (`direction` 1) or down
    /// (-1) and a little back, like the hook of a wind line (thinner than the bar, so it reads as air leaving the text).
    func breezeBar(_ y: CGFloat, width: CGFloat, height: CGFloat, curl: CGFloat, direction: CGFloat, _ color: CGColor) {
        bar(y, width: width, height: height, color)
        ctx.saveGState()
        ctx.setStrokeColor(color); ctx.setLineWidth(height * 0.5); ctx.setLineCap(.round)
        let yMid = y + height / 2
        let endX = x + width - height / 2
        let p = CGMutablePath()
        p.move(to: CGPoint(x: endX, y: yMid))
        p.addCurve(to: CGPoint(x: endX + curl * 0.35, y: yMid + direction * curl * 0.95),
                   control1: CGPoint(x: endX + curl * 0.9, y: yMid), control2: CGPoint(x: endX + curl * 0.95, y: yMid + direction * curl * 0.9))
        ctx.addPath(p); ctx.strokePath()
        ctx.restoreGState()
    }
    let top = body.minY + w * 0.665
    breezeBar(top, width: w * 0.24, height: h * 1.35, curl: w * 0.085, direction: 1, indigo)      // the heading curls up
    breezeBar(top - gap - h, width: w * 0.50, height: h, curl: w * 0.085, direction: -1, grey)     // the text lines curl down
    breezeBar(top - 2 * gap - 2 * h, width: w * 0.42, height: h, curl: w * 0.085, direction: -1, grey)
    breezeBar(top - 3 * gap - 3 * h, width: w * 0.30, height: h, curl: w * 0.085, direction: -1, grey)

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
