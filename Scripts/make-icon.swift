// Slices the Flare app icon artwork (Scripts/AppIcon-1024.png) into AppIcon.iconset next to this script.
// build-app.sh does the same with sips; this is for when you want the iconset by hand:
//   swift Scripts/make-icon.swift && iconutil -c icns Scripts/AppIcon.iconset -o Scripts/AppIcon.icns
import AppKit

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
guard let artwork = NSImage(contentsOf: here.appendingPathComponent("AppIcon-1024.png")) else {
    fatalError("Scripts/AppIcon-1024.png is missing")
}

func render(_ pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    artwork.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let iconset = here.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                       ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try? render(pixels)?.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
print("wrote \(iconset.path)")
