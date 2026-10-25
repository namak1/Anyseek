import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
let iconset = destination.appendingPathComponent("Anyseek.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

func png(size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 208, yRadius: 208)
    NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.20, blue: 0.31, alpha: 1), ending: NSColor(calibratedRed: 0.04, green: 0.08, blue: 0.15, alpha: 1))!.draw(in: tile, angle: -90)
    let gold = NSColor(calibratedRed: 1, green: 0.73, blue: 0.20, alpha: 1)
    gold.setStroke()
    let handle = NSBezierPath(); handle.lineWidth = 96; handle.lineCapStyle = .round
    handle.move(to: NSPoint(x: 602, y: 415)); handle.line(to: NSPoint(x: 788, y: 229)); handle.stroke()
    let lens = NSBezierPath(ovalIn: NSRect(x: 232, y: 380, width: 420, height: 420)); lens.lineWidth = 80; lens.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try png(size: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(size: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
