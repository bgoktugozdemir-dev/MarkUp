import AppKit
import Testing

@testable import MarkUp

@MainActor
struct ImagePreviewTests {
  @Test func decodedImageFitsResizedPreviewWithoutDistortionAndCloseReleasesContent() throws {
    let controller = ImagePreviewController()
    defer { controller.close() }
    let image = NSImage(size: NSSize(width: 160, height: 80))
    image.lockFocus()
    NSColor.red.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 160, height: 80)).fill()
    image.unlockFocus()
    let alt = "Original anonymous image preview " + UUID().uuidString
    controller.show(image: image, alt: alt)
    let panel = try #require(NSApp.windows.first { $0.title == alt } as? NSPanel)
    let view = try #require(panel.contentView?.subviews.compactMap { $0 as? NSImageView }.first)
    #expect(panel.isVisible)
    #expect(view.accessibilityLabel() == alt)
    for size in [NSSize(width: 620, height: 260), NSSize(width: 280, height: 520)] {
      panel.setContentSize(size)
      panel.contentView?.layoutSubtreeIfNeeded()
      panel.displayIfNeeded()
      view.displayIfNeeded()
      // App-hosted NSImageView can use a backing layer that cacheDisplay omits. Capture the
      // actual native view's printing representation, then inspect its rendered pixels.
      let data = view.dataWithPDF(inside: view.bounds)
      let provider = try #require(CGDataProvider(data: data as CFData))
      let document = try #require(CGPDFDocument(provider))
      let page = try #require(document.page(at: 1))
      let width = Int(view.bounds.width.rounded(.up))
      let height = Int(view.bounds.height.rounded(.up))
      var pixels = [UInt8](repeating: 255, count: width * height * 4)
      pixels.withUnsafeMutableBytes { bytes in
        let context = CGContext(
          data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(target)
        context.concatenate(
          page.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
      }
      var minimumX = width
      var maximumX = -1
      var minimumY = height
      var maximumY = -1
      for y in 0..<height {
        for x in 0..<width {
          let offset = (y * width + x) * 4
          guard pixels[offset] > 200, pixels[offset + 1] < 60, pixels[offset + 2] < 60
          else { continue }
          minimumX = min(minimumX, x)
          maximumX = max(maximumX, x)
          minimumY = min(minimumY, y)
          maximumY = max(maximumY, y)
        }
      }
      #expect(maximumX > minimumX && maximumY > minimumY)
      let ratio = Double(maximumX - minimumX + 1) / Double(maximumY - minimumY + 1)
      #expect(
        (1.95...2.05).contains(ratio),
        "Actual preview pixels must retain the image's 2:1 aspect ratio")
    }
    panel.performClose(nil)
    #expect(view.image == nil)
    controller.show(image: image, alt: alt)
    #expect(view.image === image)
    controller.close()
    #expect(!panel.isVisible)
    #expect(view.image == nil)
  }
}
