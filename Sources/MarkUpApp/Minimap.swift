import AppKit
import SwiftUI

/// A uniform miniature of the existing document layout. Long maps slide beneath the viewport
/// instead of squeezing every document into the sidebar's height.
struct MinimapGeometry {
  let scale: CGFloat
  let documentHeight: CGFloat
  let viewportHeight: CGFloat
  let viewHeight: CGFloat
  let documentOffset: CGFloat

  init(
    width: CGFloat, height: CGFloat, containerWidth: CGFloat, documentHeight: CGFloat,
    viewport: CGRect
  ) {
    scale = max(1, width) / max(1, containerWidth)
    self.documentHeight = max(1, documentHeight)
    viewportHeight = min(self.documentHeight, max(0, viewport.height))
    viewHeight = max(1, height)
    documentOffset = min(max(0, viewport.minY), max(0, self.documentHeight - viewportHeight))
  }

  var maximumDocumentOffset: CGFloat { max(0, documentHeight - viewportHeight) }
  var progress: CGFloat { maximumDocumentOffset > 0 ? documentOffset / maximumDocumentOffset : 0 }
  var virtualHeight: CGFloat { documentHeight * scale }
  var mapOrigin: CGFloat { progress * max(0, virtualHeight - viewHeight) }
  var thumb: CGRect {
    CGRect(
      x: 0, y: documentOffset * scale - mapOrigin, width: 1,
      height: min(viewHeight, viewportHeight * scale))
  }

  func documentOffset(at localY: CGFloat) -> CGFloat {
    min(maximumDocumentOffset, max(0, (localY + mapOrigin) / scale - viewportHeight / 2))
  }

  func documentOffset(dragY: CGFloat, grabOffset: CGFloat) -> CGFloat {
    let travel = max(0, min(viewHeight, virtualHeight) - thumb.height)
    guard travel > 0 else { return 0 }
    return min(1, max(0, (dragY - grabOffset) / travel)) * maximumDocumentOffset
  }
}

/// Only this bounded bitmap cache is additional to the reader's existing text graph.
/// Both its source view and its consumer are weak; queued work never owns a window/session.
@MainActor final class MinimapTiles {
  static let tileHeight = 512
  static let maximumBytes = 8 * 1024 * 1024

  struct Tile {
    let image: CGImage
    let bytes: Int
    var use: Int
  }
  private struct Signature: Equatable {
    let text: ObjectIdentifier
    let storage: ObjectIdentifier
    let revision: Int
    let controlsRevision: Int
    let width: CGFloat
    let height: CGFloat
    let originY: CGFloat
    let appearance: NSAppearance.Name?
    let pixelsWide: Int
    let backingScale: CGFloat
  }

  private(set) weak var source: ReaderTextView?
  private weak var consumer: NativeMinimapView?
  private var signature: Signature?
  private var job: Task<Void, Never>?
  private var cache: [Int: Tile] = [:]
  private var wanted: [Int] = []
  private var failedTiles = Set<Int>()
  private var clock = 0
  private var viewSize = NSSize(width: 112, height: 1)
  private(set) var enabled = false
  private(set) var generation = 0
  private(set) var generatedTileCount = 0
  private(set) var cachedBytes = 0
  private(set) var peakResidentBytes = 0
  private(set) var viewport = CGRect.zero
  private(set) var documentHeight: CGFloat = 1
  private(set) var containerWidth: CGFloat = 1
  private(set) var backingScale: CGFloat = 1
  var tilePointHeight: CGFloat { CGFloat(Self.tileHeight) / backingScale }
  var cachedTileCount: Int { cache.count }
  var cachedIndices: [Int] { cache.keys.sorted() }
  var isRendering: Bool { job != nil }
  var geometry: MinimapGeometry {
    MinimapGeometry(
      width: viewSize.width, height: viewSize.height, containerWidth: containerWidth,
      documentHeight: documentHeight, viewport: viewport)
  }

  func attach(_ view: NativeMinimapView) {
    consumer = view
    setViewSize(view.bounds.size)
    requestVisibleTiles()
  }

  func isConsumer(_ view: NativeMinimapView) -> Bool { consumer === view }

  func resizeConsumer(_ view: NativeMinimapView) {
    guard consumer === view else { return }
    setViewSize(view.bounds.size)
  }

  func detach(_ view: NativeMinimapView) {
    guard consumer === view else { return }
    consumer = nil
    disable()
  }

  func setViewSize(_ size: NSSize) {
    let width = max(1, size.width)
    let changed = Int(ceil(width)) != Int(ceil(viewSize.width))
    viewSize = NSSize(width: width, height: max(1, size.height))
    if changed { invalidate() }
    requestVisibleTiles()
  }

  func update(source text: ReaderTextView, revision: Int, enabled: Bool) {
    guard enabled, let storage = text.textStorage, let container = text.textContainer,
      container.size.width.isFinite, container.size.width > 0,
      text.bounds.height.isFinite, text.bounds.height > 0
    else {
      disable()
      return
    }
    let deviceScale = max(1, text.window?.backingScaleFactor ?? 1)
    let next = Signature(
      text: ObjectIdentifier(text), storage: ObjectIdentifier(storage),
      revision: revision, controlsRevision: text.codeControls?.previewRevision ?? 0,
      width: container.size.width, height: text.bounds.height, originY: text.textContainerOrigin.y,
      appearance: text.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
      pixelsWide: Int(ceil(viewSize.width * deviceScale)), backingScale: deviceScale)
    if next != signature {
      invalidate()
      signature = next
    }
    self.enabled = true
    source = text
    viewport = text.visibleRect
    documentHeight = text.bounds.height
    containerWidth = container.size.width
    backingScale = deviceScale
    consumer?.needsDisplay = true
    requestVisibleTiles()
  }

  func disable() {
    guard enabled || source != nil || job != nil || !cache.isEmpty else { return }
    invalidate()
    enabled = false
    source = nil
    signature = nil
    consumer?.needsDisplay = true
  }

  private func invalidate() {
    generation += 1
    job?.cancel()
    job = nil
    cache.removeAll()
    cachedBytes = 0
    wanted = []
    failedTiles = []
  }

  func requestVisibleTiles() {
    guard enabled, source != nil else { return }
    let map = geometry
    guard map.virtualHeight.isFinite, map.virtualHeight > 0 else { return }
    let last = max(0, Int(ceil(map.virtualHeight / tilePointHeight)) - 1)
    let start = max(0, Int(floor(map.mapOrigin / tilePointHeight)) - 1)
    let end = min(last, Int(floor((map.mapOrigin + viewSize.height) / tilePointHeight)) + 1)
    let bytesPerTile = alignedRowBytes * Self.tileHeight
    let capacity = max(1, Self.maximumBytes / max(1, bytesPerTile) - 2)
    wanted = start <= end ? Array(start...end).prefix(capacity).map { $0 } : []
    for index in wanted where cache[index] != nil {
      clock += 1
      cache[index]?.use = clock
    }
    guard job == nil, wanted.contains(where: { cache[$0] == nil && !failedTiles.contains($0) })
    else { return }
    let expected = generation
    job = Task { @MainActor [weak self] in
      await Task.yield()
      while !Task.isCancelled {
        guard let self, expected == generation, enabled,
          let index = wanted.first(where: { cache[$0] == nil && !failedTiles.contains($0) })
        else { break }
        if renderTile(index) { consumer?.needsDisplay = true } else { failedTiles.insert(index) }
        await Task.yield()
      }
      guard let self, expected == generation else { return }
      job = nil
    }
  }

  private var alignedRowBytes: Int {
    ((max(1, Int(ceil(viewSize.width * backingScale))) * 4 + 63) / 64) * 64
  }

  func tile(at index: Int) -> CGImage? {
    guard var tile = cache[index] else { return nil }
    clock += 1
    tile.use = clock
    cache[index] = tile
    return tile.image
  }

  private func renderTile(_ index: Int) -> Bool {
    guard let text = source, let layout = text.layoutManager as? CodeLayoutManager,
      enabled, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    else { return false }
    let map = geometry
    let top = CGFloat(index) * tilePointHeight
    let height = max(1, min(Self.tileHeight, Int(ceil((map.virtualHeight - top) * backingScale))))
    let width = max(1, Int(ceil(viewSize.width * backingScale)))
    let workingBytes = alignedRowBytes * height * 2
    // Reserve room for the bitmap context and its image snapshot before either is allocated.
    while cachedBytes + workingBytes > Self.maximumBytes, !cache.isEmpty {
      let victim = cache.min { $0.value.use < $1.value.use }!.key
      cachedBytes -= cache.removeValue(forKey: victim)!.bytes
    }
    guard workingBytes <= Self.maximumBytes,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: alignedRowBytes, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue)
    else { return false }
    peakResidentBytes = max(peakResidentBytes, cachedBytes + workingBytes)
    let region = CGRect(
      x: text.textContainerOrigin.x, y: top / map.scale,
      width: containerWidth, height: CGFloat(height) / (map.scale * backingScale))
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: map.scale * backingScale, y: -map.scale * backingScale)
    context.translateBy(x: -region.minX, y: -region.minY)
    text.effectiveAppearance.performAsCurrentDrawingAppearance {
      text.backgroundColor.setFill()
      region.fill()
      layout.drawMinimap(in: region, textOrigin: text.textContainerOrigin)
    }
    guard let image = context.makeImage() else { return false }
    let bytes = image.bytesPerRow * image.height
    clock += 1
    cache[index] = Tile(image: image, bytes: bytes, use: clock)
    cachedBytes += bytes
    generatedTileCount += 1
    return true
  }

  func scroll(to offset: CGFloat) {
    guard let text = source, enabled else { return }
    let y = min(geometry.maximumDocumentOffset, max(0, offset))
    if let scroll = text.enclosingScrollView {
      scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
      scroll.reflectScrolledClipView(scroll.contentView)
    } else {
      text.scroll(NSPoint(x: 0, y: y))
    }
    viewport = text.visibleRect
    consumer?.needsDisplay = true
    requestVisibleTiles()
  }
}

struct MinimapView: NSViewRepresentable {
  let session: ReaderSession
  func makeNSView(context: Context) -> NativeMinimapView {
    NativeMinimapView(tiles: session.minimap)
  }
  func updateNSView(_ view: NativeMinimapView, context: Context) {
    guard session.minimap.isConsumer(view) else { return }
    if let text = session.textView as? ReaderTextView, !session.isClosed {
      session.minimap.update(
        source: text, revision: session.renderedRevision,
        enabled: AppSettings.shared.value.showMinimap)
    } else {
      session.minimap.disable()
    }
    view.setAccessibilityLabel(localized("Document minimap"))
  }
  static func dismantleNSView(_ view: NativeMinimapView, coordinator: ()) {
    view.tiles.detach(view)
  }
}

@MainActor final class NativeMinimapView: NSView {
  let tiles: MinimapTiles
  private enum Drag {
    case thumb(CGFloat)
    case content(y: CGFloat, offset: CGFloat)
  }
  private var drag: Drag?
  init(tiles: MinimapTiles) {
    self.tiles = tiles
    super.init(frame: NSRect(x: 0, y: 0, width: 112, height: 1))
    clipsToBounds = true
    setAccessibilityElement(true)
    setAccessibilityLabel(localized("Document minimap"))
    tiles.attach(self)
  }
  required init?(coder: NSCoder) { nil }
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override var intrinsicContentSize: NSSize { NSSize(width: 112, height: NSView.noIntrinsicMetric) }
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    tiles.resizeConsumer(self)
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    // A sliding map deliberately positions its first/last raster tiles beyond this view.
    // NSView does not always clip custom drawing, so never let those pixels reach siblings
    // or window chrome (including a tile with a negative destination Y at document end).
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSBezierPath(rect: bounds).addClip()
    NSColor.textBackgroundColor.setFill()
    dirtyRect.fill()
    guard tiles.enabled, tiles.isConsumer(self) else { return }
    let map = tiles.geometry
    let first = max(0, Int(floor(map.mapOrigin / tiles.tilePointHeight)))
    let last = max(first, Int(floor((map.mapOrigin + bounds.height) / tiles.tilePointHeight)))
    for index in first...last {
      guard let image = tiles.tile(at: index) else { continue }
      let rect = NSRect(
        x: 0, y: CGFloat(index) * tiles.tilePointHeight - map.mapOrigin,
        width: bounds.width, height: CGFloat(image.height) / tiles.backingScale)
      NSImage(cgImage: image, size: rect.size).draw(
        in: rect, from: .zero,
        operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    var thumb = map.thumb
    thumb.size.width = bounds.width
    let path = NSBezierPath(roundedRect: thumb.insetBy(dx: 1, dy: 0), xRadius: 3, yRadius: 3)
    NSColor.controlAccentColor.withAlphaComponent(0.13).setFill()
    path.fill()
    NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
    path.stroke()
    tiles.requestVisibleTiles()
  }
  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    beginNavigation(at: point.y)
  }
  func beginNavigation(at y: CGFloat) {
    guard tiles.isConsumer(self), tiles.enabled else { return }
    let map = tiles.geometry
    if y >= map.thumb.minY, y <= map.thumb.maxY {
      drag = .thumb(y - map.thumb.minY)
    } else {
      let offset = map.documentOffset(at: y)
      drag = .content(y: y, offset: offset)
      tiles.scroll(to: offset)
    }
  }
  override func mouseDragged(with event: NSEvent) {
    dragNavigation(to: convert(event.locationInWindow, from: nil).y)
  }
  func dragNavigation(to y: CGFloat) {
    guard tiles.isConsumer(self), tiles.enabled else { return }
    switch drag {
    case .thumb(let grabOffset):
      tiles.scroll(to: tiles.geometry.documentOffset(dragY: y, grabOffset: grabOffset))
    case .content(let anchorY, let offset):
      tiles.scroll(to: offset + (y - anchorY) / tiles.geometry.scale)
    case nil: break
    }
  }
  override func mouseUp(with event: NSEvent) { drag = nil }
  override func scrollWheel(with event: NSEvent) {
    guard tiles.enabled, tiles.isConsumer(self) else { return }
    tiles.source?.enclosingScrollView?.scrollWheel(with: event)
  }
  override func keyDown(with event: NSEvent) {
    guard tiles.enabled, tiles.isConsumer(self) else { return }
    switch event.keyCode {
    case 125, 121:
      tiles.scroll(to: tiles.geometry.documentOffset + tiles.geometry.viewportHeight * 0.8)
    case 126, 116:
      tiles.scroll(to: tiles.geometry.documentOffset - tiles.geometry.viewportHeight * 0.8)
    case 115: tiles.scroll(to: 0)
    case 119: tiles.scroll(to: tiles.geometry.maximumDocumentOffset)
    default: super.keyDown(with: event)
    }
  }
  override func accessibilityRole() -> NSAccessibility.Role? { .scrollBar }
  override func accessibilityOrientation() -> NSAccessibilityOrientation { .vertical }
  override func accessibilityValue() -> Any? {
    NSNumber(value: tiles.isConsumer(self) ? Double(tiles.geometry.progress) : 0)
  }
  override func accessibilityMinValue() -> Any? { NSNumber(value: 0) }
  override func accessibilityMaxValue() -> Any? { NSNumber(value: 1) }
  override func accessibilityPerformIncrement() -> Bool { accessibilityScroll(forward: true) }
  override func accessibilityPerformDecrement() -> Bool { accessibilityScroll(forward: false) }
  private func accessibilityScroll(forward: Bool) -> Bool {
    guard tiles.enabled, tiles.isConsumer(self) else { return false }
    let before = tiles.geometry.documentOffset
    tiles.scroll(to: before + (forward ? 1 : -1) * tiles.geometry.viewportHeight * 0.8)
    NSAccessibility.post(element: self, notification: .valueChanged)
    return tiles.geometry.documentOffset != before
  }
}
