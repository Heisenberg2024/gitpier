import AppKit
import Foundation

// Guidance only: Finder draws the real app and Applications objects.
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/Installer")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let logical = NSSize(width: 720, height: 420)
let image = NSImage(size: logical)
for scale in [1, 2] {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 720 * scale, pixelsHigh: 420 * scale,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = logical
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSColor(calibratedRed: 0.965, green: 0.969, blue: 0.976, alpha: 1).setFill()
  NSBezierPath(rect: NSRect(origin: .zero, size: logical)).fill()
  func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    let measured = (value as NSString).size(withAttributes: attributes)
    (value as NSString).draw(at: NSPoint(x: (720 - measured.width) / 2, y: 420 - y - measured.height), withAttributes: attributes)
  }
  let ink = NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.21, alpha: 1)
  let muted = NSColor(calibratedRed: 0.40, green: 0.45, blue: 0.51, alpha: 1)
  text("GitPier", y: 30, size: 25, weight: .semibold, color: ink)
  text("All Your Repositories. One Workspace.", y: 65, size: 13, weight: .regular, color: muted)
  NSColor(calibratedRed: 0.28, green: 0.52, blue: 0.48, alpha: 1).setStroke()
  let arrow = NSBezierPath()
  arrow.lineWidth = 2.5
  arrow.lineCapStyle = .round
  arrow.lineJoinStyle = .round
  arrow.move(to: NSPoint(x: 325, y: 224))
  arrow.line(to: NSPoint(x: 395, y: 224))
  arrow.move(to: NSPoint(x: 385, y: 234))
  arrow.line(to: NSPoint(x: 395, y: 224))
  arrow.line(to: NSPoint(x: 385, y: 214))
  arrow.stroke()
  text("Drag GitPier to Applications to install", y: 306, size: 19, weight: .medium, color: ink)
  text("将 GitPier 拖入 Applications 文件夹即可安装", y: 342, size: 13, weight: .regular, color: muted)
  NSGraphicsContext.restoreGraphicsState()
  image.addRepresentation(rep)
  if scale == 2 {
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("background@2x.png"))
  }
}
try image.tiffRepresentation!.write(to: output.appendingPathComponent("background.tiff"))
print("Installer background: 720 × 420 pt, 1x + 2x TIFF, 1440 × 840 PNG")
