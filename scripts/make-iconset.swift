// Square artwork -> .iconset folder. macOS doesn't mask .icns files, so the rounded
// shape, margin and shadow of Apple's icon grid have to be in the images themselves.
// Usage: swift make-iconset.swift artwork.png output.iconset
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let artwork = NSImage(contentsOfFile: arguments[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("usage: make-iconset.swift artwork.png output.iconset")
}
let output = URL(fileURLWithPath: arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(pixels: Int) throws -> Data {
    let scale = CGFloat(pixels) / 1024
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("no bitmap context") }
    context.interpolationQuality = .high

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824).applying(CGAffineTransform(scaleX: scale, y: scale))
    let shape = CGPath(roundedRect: tile, cornerWidth: 185 * scale, cornerHeight: 185 * scale, transform: nil)
    context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 20 * scale, color: CGColor(gray: 0, alpha: 0.3))
    context.addPath(shape)
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0)
    context.addPath(shape)
    context.clip()
    context.draw(artwork, in: tile)

    guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("no PNG")
    }
    return png
}

for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: output.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
