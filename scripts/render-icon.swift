// Draws Pardon's app icon (the brush asterisk on a light rounded square) into
// an .iconset folder for iconutil. The asterisk comes from
// macos/Sources/quill/UI/PardonMark.swift, so there is one copy of the mark.
//
// Usage: swift scripts/render-icon.swift <PardonMark.swift> <out.iconset>
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: render-icon.swift <PardonMark.swift> <out.iconset>\n".utf8))
    exit(64)
}
let source = try String(contentsOfFile: args[1], encoding: .utf8)
guard let start = source.range(of: "<svg"), let end = source.range(of: "</svg>") else {
    FileHandle.standardError.write(Data("no <svg> in \(args[1])\n".utf8))
    exit(65)
}
guard let mark = NSImage(data: Data(source[start.lowerBound..<end.upperBound].utf8)) else {
    FileHandle.standardError.write(Data("the asterisk SVG did not load\n".utf8))
    exit(65)
}
let out = URL(fileURLWithPath: args[2], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024
    // Apple's icon grid: an 824-point square with a 185-point corner, centered.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    NSColor(white: 0.98, alpha: 1).setFill()
    NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s).fill()
    NSColor(white: 0.85, alpha: 1).setStroke()
    let edge = NSBezierPath(roundedRect: body.insetBy(dx: s, dy: s), xRadius: 184 * s, yRadius: 184 * s)
    edge.lineWidth = 2 * s
    edge.stroke()
    let size = 520 * s
    mark.draw(in: NSRect(x: (CGFloat(pixels) - size) / 2, y: (CGFloat(pixels) - size) / 2, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try render(points).write(to: out.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(points * 2).write(to: out.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
