import AppKit
import ImageIO

// The approved raster is the source of truth. Regeneration never restores old concepts.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Resources/Branding/gitpier-icon-1024.png")
guard let image = NSImage(contentsOf: source) else {
  fatalError("Missing canonical GitPier PNG")
}
let assets = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

func png(size: Int) throws -> Data {
  guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)
  else { fatalError("Unable to allocate icon bitmap") }
  bitmap.size = NSSize(width: size, height: size)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  NSGraphicsContext.current?.imageInterpolation = .high
  image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero,
             operation: .copy, fraction: 1)
  NSGraphicsContext.restoreGraphicsState()
  let data = NSMutableData()
  guard let cgImage = bitmap.cgImage,
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
  else {
    fatalError("Unable to encode icon PNG")
  }
  CGImageDestinationAddImage(destination, cgImage, nil)
  guard CGImageDestinationFinalize(destination) else { fatalError("Unable to write icon PNG") }
  return data as Data
}

var entries: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let filename = "icon_\(size)x\(size)@\(scale)x.png"
    try png(size: size * scale).write(to: assets.appendingPathComponent(filename))
    entries.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x",
                    "filename": filename])
  }
}
try JSONSerialization.data(
  withJSONObject: ["images": entries, "info": ["author": "xcode", "version": 1]],
  options: [.prettyPrinted, .sortedKeys]).write(to: assets.appendingPathComponent("Contents.json"))
let data = try png(size: 1024)
try data.write(to: source)
try data.write(to: root.appendingPathComponent("Sources/GitPier/Resources/gitpier-icon-1024.png"))
let cleaner = Process()
cleaner.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
cleaner.arguments = [root.appendingPathComponent("Scripts/strip-png-metadata.py").path, source.path,
  root.appendingPathComponent("Sources/GitPier/Resources/gitpier-icon-1024.png").path]
  + entries.compactMap { $0["filename"].map { assets.appendingPathComponent($0).path } }
try cleaner.run()
cleaner.waitUntilExit()
guard cleaner.terminationStatus == 0 else { fatalError("PNG metadata cleanup failed") }
print("Generated GitPier PNG resources and macOS AppIcon sizes")
