import AppKit
import MarkUpCore
import Testing

@testable import MarkUp

@MainActor
struct MinimapTests {
  @MainActor private struct Reader {
    let session: ReaderSession
    let text: ReaderTextView
    let layout: CodeLayoutManager
    let controls: CodeBlockController
    let map: NativeMinimapView
    let window: NSWindow
    var tiles: MinimapTiles { session.minimap }
  }

  private func reader(_ source: String, decorate: Bool = false) async throws -> Reader {
    let document = try await MarkdownParser().parse(source)
    var preferences = ReaderPreferences()
    preferences.wrapCode = false
    preferences.automaticTheme = false
    preferences.codeThemeID = "one-dark"
    let rendered = NativeMarkdownRenderer().render(
      document: document, preferences: preferences, tokens: [:])
    let display = NSMutableAttributedString(attributedString: rendered.attributedString)
    if decorate {
      let heading = (display.string as NSString).range(of: "Blue Heading")
      display.addAttribute(.foregroundColor, value: NSColor.blue, range: heading)
      let code = (display.string as NSString).range(of: "let redToken")
      display.addAttribute(.foregroundColor, value: NSColor.red, range: code)
      let marker = (display.string as NSString).range(of: "\u{FFFC}")
      let context = try #require(
        CGContext(
          data: nil, width: 70, height: 40, bitsPerComponent: 8,
          bytesPerRow: 280, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(NSColor.green.cgColor)
      context.fill(CGRect(x: 0, y: 0, width: 70, height: 40))
      let image = NSImage(
        cgImage: try #require(context.makeImage()), size: NSSize(width: 70, height: 40))
      let attachment = NSTextAttachment()
      attachment.image = image
      display.addAttribute(.attachment, value: attachment, range: marker)
    }
    let storage = NSTextStorage()
    let layout = CodeLayoutManager()
    layout.backgroundLayoutEnabled = false
    storage.addLayoutManager(layout)
    let container = CodeTextContainer(
      size: NSSize(width: 360, height: CGFloat.greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    container.widthTracksTextView = false
    layout.addTextContainer(container)
    let text = ReaderTextView(frame: .zero, textContainer: container)
    text.isEditable = false
    text.isSelectable = true
    text.isVerticallyResizable = true
    text.textContainerInset = NSSize(width: 32, height: 60)
    let controls = CodeBlockController(textView: text)
    text.codeControls = controls
    layout.codeControls = controls
    container.codeControls = controls
    controls.prepare(display, rendered: rendered, document: document, preferences: preferences)
    let session = ReaderSession(url: nil, source: source)
    session.document = document
    session.rendered = rendered
    session.renderedRevision = 1
    session.textView = text
    text.session = session
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 424, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: window.contentLayoutRect)
    scroll.hasVerticalScroller = true
    scroll.documentView = text
    window.contentView = scroll
    storage.setAttributedString(display)
    text.frame.size.width = scroll.contentSize.width
    text.fitDocument()
    controls.updateFrames()
    let map = NativeMinimapView(tiles: session.minimap)
    map.setFrameSize(NSSize(width: 112, height: 600))
    text.geometryChanged = { [weak session, weak text] in
      guard let session, let text, !session.isClosed else { return }
      session.minimap.update(source: text, revision: session.renderedRevision, enabled: true)
    }
    session.minimap.update(source: text, revision: session.renderedRevision, enabled: true)
    try await ready(session.minimap)
    return Reader(
      session: session, text: text, layout: layout, controls: controls, map: map, window: window)
  }

  private func ready(_ tiles: MinimapTiles) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while tiles.isRendering, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(!tiles.isRendering, "Minimap tile work did not finish its bounded visible queue")
  }

  private func payloads(_ tiles: MinimapTiles) -> [Data] {
    tiles.cachedIndices.compactMap { tiles.tile(at: $0)?.dataProvider?.data as Data? }
  }

  @Test func uniformMappingCoversTopMiddleEndAndFittingMaps() {
    for height: CGFloat in [1500, 100_000] {
      for progress: CGFloat in [0, 0.5, 1] {
        let map = MinimapGeometry(
          width: 112, height: 600, containerWidth: 800,
          documentHeight: height,
          viewport: CGRect(x: 0, y: (height - 800) * progress, width: 800, height: 800))
        #expect(abs(map.scale - 0.14) < 0.0001)
        #expect(abs(map.progress - progress) < 0.0001)
        let travel = min(map.viewHeight, map.virtualHeight) - map.thumb.height
        #expect(abs(map.thumb.minY - progress * travel) < 0.001)
        let grab: CGFloat = 13
        #expect(
          abs(
            map.documentOffset(dragY: map.thumb.minY + grab, grabOffset: grab) - map.documentOffset)
            < 0.01)
        #expect(map.documentOffset(at: -1000) >= 0)
        #expect(map.documentOffset(at: 100_000) == map.maximumDocumentOffset)
      }
    }
    let small = MinimapGeometry(
      width: 112, height: 600, containerWidth: 800,
      documentHeight: 200, viewport: CGRect(x: 0, y: 0, width: 800, height: 800))
    #expect(small.maximumDocumentOffset == 0 && small.mapOrigin == 0)
    #expect(small.documentOffset(at: 400) == 0)
    #expect(small.documentOffset(dragY: 200, grabOffset: 4) == 0)
  }

  @Test func rasterContainsRealColoredGlyphsImagesAndOffscreenCodePanelsWithoutSelection()
    async throws
  {
    let preamble = String(repeating: "A short paragraph with real text shapes.\n\n", count: 20)
    let source =
      "# Blue Heading\n\n![green](not-loaded.png)\n\n" + preamble
      + "```swift\nlet redToken = 1\n```\n\n| First | Second |\n|---|---|\n| Native | Table |\n"
    let reader = try await reader(source, decorate: true)
    defer {
      reader.session.close()
      reader.window.close()
    }
    let original = try #require(reader.text.textStorage?.copy() as? NSAttributedString)
    let images = reader.tiles.cachedIndices.compactMap { reader.tiles.tile(at: $0) }
    var red = 0
    var blue = 0
    var green = 0
    var darkSurface = 0
    for image in images {
      let bytes = try #require(image.dataProvider?.data) as Data
      bytes.withUnsafeBytes { raw in
        let pixels = raw.bindMemory(to: UInt8.self)
        for y in 0..<image.height {
          for x in 0..<image.width {
            let index = y * image.bytesPerRow + x * 4
            let r = Int(pixels[index])
            let g = Int(pixels[index + 1])
            let b = Int(pixels[index + 2])
            if r > 150 && g < 100 && b < 100 { red += 1 }
            if b > 150 && r < 100 && g < 100 { blue += 1 }
            if g > 150 && r < 100 && b < 100 { green += 1 }
            if r > 20 && r < 65 && g > 20 && g < 65 && b > 20 && b < 65 { darkSurface += 1 }
          }
        }
      }
    }
    #expect(
      red > 3 && blue > 3 && green > 20,
      "red=\(red) blue=\(blue) green=\(green) tiles=\(images.count) scale=\(reader.window.backingScaleFactor)"
    )
    #expect(
      darkSurface > 200, "Offscreen code panel must use the tile region, not the reader viewport")
    let record = try #require(reader.controls.records.first { $0.kind == .code })
    #expect(record.panelFrame.minY > reader.text.visibleRect.maxY)
    let before = images.map { $0.dataProvider!.data! as Data }
    let selection = NSRange(location: 0, length: original.length)
    reader.text.setSelectedRange(selection)
    reader.layout.addTemporaryAttributes(
      [.foregroundColor: NSColor.magenta, .backgroundColor: NSColor.magenta],
      forCharacterRange: selection)
    reader.tiles.update(source: reader.text, revision: 2, enabled: true)
    try await ready(reader.tiles)
    let after = reader.tiles.cachedIndices.compactMap {
      reader.tiles.tile(at: $0)?.dataProvider?.data as Data?
    }
    #expect(
      before == after, "Transient selection/temporary colors must never enter the content map")
    #expect(reader.text.selectedRange() == selection)
    #expect(reader.text.selectedRanges == [NSValue(range: selection)])
    #expect(reader.text.textStorage?.isEqual(to: original) == true)
    #expect(
      reader.layout.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil)
        as? NSColor == .magenta)
    let multiple = [
      NSValue(range: NSRange(location: 0, length: 3)),
      NSValue(range: NSRange(location: original.length - 4, length: 3)),
    ]
    reader.text.selectedRanges = multiple
    reader.tiles.update(source: reader.text, revision: 3, enabled: true)
    try await ready(reader.tiles)
    #expect(payloads(reader.tiles) == before)
    #expect(reader.text.selectedRanges == multiple)
    #expect(reader.text.selectedRange() == multiple[0].rangeValue)
  }

  @Test func cacheReusesScrollTilesIsBoundedAndInvalidatesEveryDisplayRevision() async throws {
    let source = (0..<800).map { "Paragraph \($0) has real native content.\n\n" }.joined()
    let reader = try await reader(source)
    defer {
      reader.session.close()
      reader.window.close()
    }
    let count = reader.tiles.generatedTileCount
    reader.tiles.scroll(to: 2)
    try await ready(reader.tiles)
    #expect(reader.tiles.generatedTileCount == count)
    for step in 0...16 {
      reader.tiles.scroll(to: reader.tiles.geometry.maximumDocumentOffset * CGFloat(step) / 16)
      try await ready(reader.tiles)
      #expect(reader.tiles.cachedBytes <= MinimapTiles.maximumBytes)
      #expect(reader.tiles.peakResidentBytes <= MinimapTiles.maximumBytes)
    }
    let old = reader.tiles.generation
    reader.tiles.update(source: reader.text, revision: 3, enabled: true)
    #expect(reader.tiles.generation > old)
    try await ready(reader.tiles)
    let fresh = reader.tiles.generatedTileCount
    reader.tiles.disable()
    #expect(reader.tiles.cachedBytes == 0 && reader.tiles.cachedTileCount == 0)
    #expect(reader.tiles.source == nil && !reader.tiles.isRendering)
    reader.tiles.update(source: reader.text, revision: 3, enabled: true)
    try await ready(reader.tiles)
    #expect(reader.tiles.generatedTileCount > fresh)
    #expect(reader.tiles.backingScale == reader.window.backingScaleFactor)
    let tile = try #require(reader.tiles.cachedIndices.first.flatMap { reader.tiles.tile(at: $0) })
    #expect(tile.width == Int(ceil(112 * reader.window.backingScaleFactor)))
    #expect(tile.height <= MinimapTiles.tileHeight)
    // Refuse an oversized working bitmap without scheduling an endless redraw/retry loop.
    let generated = reader.tiles.generatedTileCount
    reader.tiles.setViewSize(NSSize(width: 20_000, height: 600))
    try await ready(reader.tiles)
    for _ in 0..<10 { reader.tiles.requestVisibleTiles() }
    #expect(!reader.tiles.isRendering && reader.tiles.generatedTileCount == generated)
    #expect(reader.tiles.cachedBytes == 0)
  }

  @Test func panelPaddingPaintsWithoutGlyphsOrNativeHeaderControls() async throws {
    let reader = try await reader("```swift\nlet value = 1\n```")
    defer {
      reader.session.close()
      reader.window.close()
    }
    let record = try #require(reader.controls.records.first)
    let region = CGRect(
      x: record.panelFrame.minX + 4, y: record.headerFrame.midY,
      width: record.panelFrame.width - 8, height: 4)
    let scale = 112 / region.width
    let height = max(1, Int(ceil(region.height * scale * 2)))
    let context = try #require(
      CGContext(
        data: nil, width: 224, height: height,
        bitsPerComponent: 8, bytesPerRow: 896, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale * 2, y: -scale * 2)
    context.translateBy(x: -region.minX, y: -region.minY)
    reader.layout.drawMinimap(in: region, textOrigin: reader.text.textContainerOrigin)
    NSGraphicsContext.restoreGraphicsState()
    let image = try #require(context.makeImage())
    let bytes = try #require(image.dataProvider?.data) as Data
    let color = try #require(record.surfaceColor.usingColorSpace(.deviceRGB))
    var matching = 0
    bytes.withUnsafeBytes { raw in
      let pixels = raw.bindMemory(to: UInt8.self)
      for y in 0..<height {
        for x in 0..<224 {
          let index = y * image.bytesPerRow + x * 4
          if abs(Int(pixels[index]) - Int(color.redComponent * 255)) < 10,
            abs(Int(pixels[index + 1]) - Int(color.greenComponent * 255)) < 10,
            abs(Int(pixels[index + 2]) - Int(color.blueComponent * 255)) < 10,
            pixels[index + 3] == 255
          {
            matching += 1
          }
        }
      }
    }
    #expect(matching > Int(Double(224 * height) * 0.9))
  }

  @Test func nativeClickDragAndAccessibilityNavigateWithoutChangingText() async throws {
    let reader = try await reader(
      String(repeating: "Native paragraph with selectable text.\n\n", count: 1000))
    defer {
      reader.session.close()
      reader.window.close()
    }
    let original = reader.text.string
    reader.map.beginNavigation(at: 500)
    let clicked = reader.tiles.geometry.documentOffset
    reader.map.dragNavigation(to: 501)
    #expect(
      abs(reader.tiles.geometry.documentOffset - clicked) < 20,
      "A track click followed by one pixel of drag must not jump to document end")
    reader.tiles.scroll(to: reader.tiles.geometry.maximumDocumentOffset / 2)
    let map = reader.tiles.geometry
    let grab = min(10, map.thumb.height / 2)
    reader.map.beginNavigation(at: map.thumb.minY + grab)
    reader.map.dragNavigation(to: grab)
    #expect(reader.tiles.geometry.documentOffset < 1)
    reader.map.dragNavigation(to: map.viewHeight - map.thumb.height + grab)
    #expect(abs(reader.tiles.geometry.documentOffset - map.maximumDocumentOffset) < 1)
    #expect(reader.map.accessibilityRole() == .scrollBar)
    #expect(reader.map.accessibilityPerformDecrement())
    #expect(reader.text.string == original)
    reader.text.setSelectedRange(NSRange(location: 0, length: original.utf16.count))
    let pasteboard = NSPasteboard.withUniqueName()
    #expect(reader.text.writeSelection(to: pasteboard, types: reader.text.writablePasteboardTypes))
    #expect(pasteboard.string(forType: .string) == original)
  }

  @Test func slidingTilesAndThumbNeverPaintOutsideTheNativeViewBounds() async throws {
    let reader = try await reader(
      String(repeating: "Native text at document end must stay inside its minimap.\n\n", count: 500)
    )
    defer {
      reader.session.close()
      reader.window.close()
    }
    let maximumOrigin = reader.tiles.geometry.virtualHeight - reader.map.bounds.height
    try #require(maximumOrigin > reader.tiles.tilePointHeight * 3)
    // A half-tile origin near the end guarantees a negative first destination Y.
    let origin =
      (floor(maximumOrigin / reader.tiles.tilePointHeight) - 0.5) * reader.tiles.tilePointHeight
    reader.tiles.scroll(to: origin / maximumOrigin * reader.tiles.geometry.maximumDocumentOffset)
    try await ready(reader.tiles)
    let map = reader.tiles.geometry
    let first = floor(map.mapOrigin / reader.tiles.tilePointHeight)
    #expect(first * reader.tiles.tilePointHeight - map.mapOrigin < -10)
    let width = 160
    let height = 720
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    let baseline: [UInt8]
    do {
      NSGraphicsContext.saveGraphicsState()
      defer { NSGraphicsContext.restoreGraphicsState() }
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
      context.translateBy(x: 0, y: CGFloat(height))
      context.scaleBy(x: 1, y: -1)
      context.translateBy(x: 24, y: 60)
      // Compare real encoded pixels, not assumed device-RGB sentinel bytes. Capture only
      // after AppKit has wrapped the context so drawing is the sole operation under test.
      let before = try #require(context.makeImage())
      baseline = [UInt8](try #require(before.dataProvider?.data) as Data)
      reader.map.draw(reader.map.bounds)
    }
    let image = try #require(context.makeImage())
    let data = try #require(image.dataProvider?.data) as Data
    var changedInside = 0
    var changedOutside = 0
    data.withUnsafeBytes { raw in
      let pixels = raw.bindMemory(to: UInt8.self)
      for y in 0..<height {
        for x in 0..<width {
          let offset = y * image.bytesPerRow + x * 4
          let changed =
            pixels[offset] != baseline[offset] || pixels[offset + 1] != baseline[offset + 1]
            || pixels[offset + 2] != baseline[offset + 2]
            || pixels[offset + 3] != baseline[offset + 3]
          guard changed else { continue }
          if x >= 24 && x < 136 && y >= 60 && y < 660 {
            changedInside += 1
          } else {
            changedOutside += 1
          }
        }
      }
    }
    #expect(changedInside > 1000)
    #expect(
      changedOutside == 0,
      "Partially visible tiles and thumb strokes must not paint titlebar or sibling pixels")
  }

  @Test func foldingHorizontalOffsetsAndNumbersInvalidateEvenWhenHeightDoesNotChange() async throws
  {
    let code = (0..<80).map { "line \($0) " + String(repeating: "wide_value_", count: 40) }.joined(
      separator: "\n")
    let reader = try await reader("```swift\n" + code + "\n```\n\nAFTER-END")
    defer {
      reader.session.close()
      reader.window.close()
    }
    let record = try #require(reader.controls.records.first)
    reader.controls.toggleLimit(record.id, enabled: false)
    var generation = reader.tiles.generation
    let height = reader.text.bounds.height
    reader.controls.setScroll(record.id, fraction: 0.5)
    #expect(reader.text.bounds.height == height)
    #expect(reader.tiles.generation > generation)
    generation = reader.tiles.generation
    reader.controls.toggleNumbers(record.id, enabled: true)
    #expect(reader.tiles.generation > generation)
    reader.controls.toggleLimit(record.id, enabled: true)
    #expect(reader.tiles.documentHeight == reader.text.bounds.height)
    #expect(reader.tiles.documentHeight < height / 2)
    try await ready(reader.tiles)
    #expect(reader.tiles.cachedBytes <= MinimapTiles.maximumBytes)
    reader.controls.toggleLimit(record.id, enabled: false)
    #expect(reader.tiles.documentHeight == reader.text.bounds.height)
    #expect(reader.text.bounds.height == height)
    let originalWidth = reader.text.textContainer!.size.width
    reader.text.textContainer!.size.width = originalWidth + 20
    reader.controls.containerDidResize()
    reader.text.fitDocument()
    generation = reader.tiles.generation
    reader.tiles.update(source: reader.text, revision: 1, enabled: true)
    #expect(reader.tiles.generation > generation)
    #expect(reader.tiles.containerWidth == originalWidth + 20)
  }

  @Test func closingCancelsQueuedWorkAndRetainedMapDoesNotOwnNativeText() async throws {
    let (session, window, map, native) = try await closedReader()
    let deadline = ContinuousClock.now + .seconds(5)
    while native.value != nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.minimap.source == nil && session.minimap.cachedBytes == 0)
    #expect(!session.minimap.isRendering)
    #expect(native.value == nil)
    // Delayed callbacks from an old minimap must not resize or disable its replacement.
    let replacement = NativeMinimapView(tiles: session.minimap)
    replacement.setFrameSize(NSSize(width: 112, height: 500))
    map.setFrameSize(NSSize(width: 300, height: 900))
    session.minimap.detach(map)
    #expect(session.minimap.isConsumer(replacement))
    #expect(session.minimap.geometry.viewHeight == 500)
    window.close()
  }

  @MainActor private final class WeakNativeText {
    weak var value: ReaderTextView?
    init(_ value: ReaderTextView) { self.value = value }
  }

  private func closedReader() async throws -> (
    ReaderSession, NSWindow, NativeMinimapView, WeakNativeText
  ) {
    let fixture = try await reader(
      String(repeating: "A retained window must release its text graph.\n\n", count: 100))
    let native = WeakNativeText(fixture.text)
    fixture.tiles.scroll(to: fixture.tiles.geometry.maximumDocumentOffset)
    fixture.session.close()
    // This completed helper drops the Reader aggregate (which intentionally owns the layout,
    // controller and text) before testing weak release while retaining the real window/map.
    return (fixture.session, fixture.window, fixture.map, native)
  }
}
