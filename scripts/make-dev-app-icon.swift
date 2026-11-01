import AppKit
import Foundation

// Derives the Debug ("MarkUp Dev") icon from the shipping AppIcon by adding an orange DEV badge.
// Usage: swift scripts/make-dev-app-icon.swift
let assets = URL(fileURLWithPath: "Sources/MarkUpApp/Resources/Assets.xcassets")
let source = assets.appendingPathComponent("AppIcon.appiconset")
let output = assets.appendingPathComponent("AppIcon-Dev.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let contents = try Data(contentsOf: source.appendingPathComponent("Contents.json"))
try contents.write(to: output.appendingPathComponent("Contents.json"))
let catalog = try JSONSerialization.jsonObject(with: contents) as! [String: Any]

for entry in catalog["images"] as! [[String: String]] {
  guard let filename = entry["filename"], let original = NSImage(
    contentsOf: source.appendingPathComponent(filename)),
    let points = entry["size"].flatMap({ Double($0.split(separator: "x")[0]) }),
    let scale = entry["scale"].flatMap({ Double($0.dropLast()) })
  else { fatalError("Unreadable icon entry \(entry)") }
  let pixels = Int(points * scale)
  let size = CGFloat(pixels)
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  original.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
  let badge = NSRect(x: size * 0.14, y: size * 0.1, width: size * 0.72, height: size * 0.22)
  NSColor(calibratedRed: 0.96, green: 0.42, blue: 0.08, alpha: 1).setFill()
  NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
  // Text is unreadable below 64 px; the orange band alone marks those sizes.
  if pixels >= 64 {
    let font = NSFont.systemFont(ofSize: badge.height * 0.62, weight: .heavy)
    let label = NSAttributedString(
      string: "DEV", attributes: [.font: font, .foregroundColor: NSColor.white, .kern: size * 0.012])
    let bounds = label.size()
    label.draw(
      at: NSPoint(x: badge.midX - bounds.width / 2, y: badge.midY - bounds.height / 2))
  }
  NSGraphicsContext.restoreGraphicsState()
  guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Icon encoding failed")
  }
  try png.write(to: output.appendingPathComponent(filename))
}
print("Wrote \(output.path)")
