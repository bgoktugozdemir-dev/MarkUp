import AppKit
import Foundation

// Original temporary development artwork, deliberately not final product branding.
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/DevelopmentIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let size = CGFloat(pixels)
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor(calibratedRed: 0.16, green: 0.26, blue: 0.43, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: size * 0.06, y: size * 0.06, width: size * 0.88, height: size * 0.88), xRadius: size * 0.2, yRadius: size * 0.2).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: size * 0.26, y: size * 0.21, width: size * 0.48, height: size * 0.6), xRadius: size * 0.04, yRadius: size * 0.04).fill()
        NSColor(calibratedRed: 0.16, green: 0.26, blue: 0.43, alpha: 1).setFill()
        for index in 0..<3 {
            NSBezierPath(rect: NSRect(x: size * 0.34, y: size * (0.63 - Double(index) * 0.12), width: size * (index == 2 ? 0.2 : 0.32), height: max(1, size * 0.035))).fill()
        }
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: NSRect(x: size * 0.62, y: size * 0.12, width: size * 0.24, height: size * 0.24)).fill()
        image.unlockFocus()
        let filename = "dev-\(points)@\(scale)x.png"
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Icon rendering failed") }
        try png.write(to: output.appendingPathComponent(filename))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "MarkUp temporary development artwork", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("Contents.json"))
