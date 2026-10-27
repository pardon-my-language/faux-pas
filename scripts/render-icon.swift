// Draws Pardon's brush asterisk as the one layer of the app icon: a 1024-pixel
// PNG on a clear background. macOS 26 and later draws the rounded square and
// the light fill from macos/Packaging/AppIcon.icon/icon.json; an icon that
// draws its own square gets put inside a gray tile. The asterisk comes from
// macos/Sources/quill/UI/PardonMark.swift, so there is one copy of the mark.
//
// Usage: swift scripts/render-icon.swift <PardonMark.swift> <out.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: render-icon.swift <PardonMark.swift> <out.png>\n".utf8))
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

let pixels = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let size: CGFloat = 520
mark.draw(in: NSRect(x: (CGFloat(pixels) - size) / 2, y: (CGFloat(pixels) - size) / 2, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
