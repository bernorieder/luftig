// contact-sheet.swift - stitches PNGs into one labelled grid (used by regenerate.sh).
//   contact-sheet OUT.png COLUMNS "Label=path.png" ...
// Every image is scaled to the same width (the cell width), cut to the same height and labelled underneath.
import AppKit

let args = CommandLine.arguments
guard args.count >= 4, let columns = Int(args[2]), columns > 0 else { FileHandle.standardError.write(Data("usage: contact-sheet OUT.png COLUMNS Label=path ...\n".utf8)); exit(2) }
let out = args[1]
let items: [(String, NSImage)] = args[3...].compactMap { a in
    guard let eq = a.firstIndex(of: "=") else { return nil }
    let label = String(a[a.startIndex..<eq]), path = String(a[a.index(after: eq)...])
    guard let img = NSImage(contentsOfFile: path) else { FileHandle.standardError.write(Data("cannot read \(path)\n".utf8)); return nil }
    return (label, img)
}
let cellW: CGFloat = 460, gap: CGFloat = 16, labelH: CGFloat = 30
let cellH: CGFloat = {
    // the tallest image at cell width, but at most 1.5 x the cell width (a long page is cut off at the bottom)
    let tallest = items.map { $0.1.size.height / $0.1.size.width * cellW }.max() ?? cellW
    return min(tallest, cellW * 1.5)
}()
let rows = (items.count + columns - 1) / columns
let width = CGFloat(columns) * cellW + CGFloat(columns + 1) * gap
let height = CGFloat(rows) * (cellH + labelH) + CGFloat(rows + 1) * gap
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
for (i, item) in items.enumerated() {
    let col = i % columns, row = i / columns
    let x = gap + CGFloat(col) * (cellW + gap)
    let top = height - gap - CGFloat(row) * (cellH + labelH + gap)       // y grows upwards: the top edge of this cell
    let img = item.1
    let scaledH = img.size.height / img.size.width * cellW
    let drawH = min(scaledH, cellH)
    // the TOP part of the image: draw it scaled to cell width, clipped to the cell
    let cell = NSRect(x: x, y: top - cellH, width: cellW, height: cellH)
    NSColor.white.setFill(); cell.fill()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: cell).addClip()
    img.draw(in: NSRect(x: x, y: top - scaledH, width: cellW, height: scaledH), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    _ = drawH
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white]
    NSAttributedString(string: item.0, attributes: attrs).draw(at: NSPoint(x: x + 2, y: top - cellH - labelH + 5))
}
NSGraphicsContext.restoreGraphicsState()
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: out))
print("wrote \(out): \(items.count) images, \(Int(width)) x \(Int(height)) px")
