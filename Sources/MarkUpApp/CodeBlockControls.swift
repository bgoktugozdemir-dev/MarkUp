import AppKit
import MarkUpCore

/// Native tables otherwise clamp absolute cell widths to their incoming layout rectangle.
/// Only the screen-owned copy expands that rectangle; PDF owns separate ordinary tables.
final class ReaderOverflowTable: NSTextTable {
  private let minimumWidth: CGFloat
  init(minimumWidth: CGFloat) {
    self.minimumWidth = minimumWidth
    super.init()
  }
  required init?(coder: NSCoder) { nil }

  override func rect(
    for block: NSTextTableBlock, layoutAt startingPoint: NSPoint, in rect: NSRect,
    textContainer: NSTextContainer, characterRange: NSRange
  ) -> NSRect {
    precondition(Thread.isMainThread, "Reader tables are main-thread owned")
    var expanded = rect
    expanded.size.width = max(rect.width, minimumWidth)
    return super.rect(
      for: block, layoutAt: startingPoint, in: expanded,
      textContainer: textContainer, characterRange: characterRange)
  }

  override func boundsRect(
    for block: NSTextTableBlock, contentRect: NSRect, in rect: NSRect,
    textContainer: NSTextContainer, characterRange: NSRange
  ) -> NSRect {
    precondition(Thread.isMainThread, "Reader tables are main-thread owned")
    var expanded = rect
    expanded.size.width = max(rect.width, minimumWidth)
    return super.boundsRect(
      for: block, contentRect: contentRect, in: expanded,
      textContainer: textContainer, characterRange: characterRange)
  }
}

/// All code remains in the reader's single text storage. Only line-fragment geometry changes.
/// Native selection, keyboard movement, copying and accessibility therefore use original indices.
// Objective-C callbacks are nonisolated. The only unsafe fields are weak UI-owner links:
// assignment is main-actor-only and every callback asserts the main thread before reading one.
// The text objects themselves are never Sendable and background layout is disabled.
@MainActor final class CodeTextContainer: NSTextContainer {
  nonisolated(unsafe) weak var codeControls: CodeBlockController?

  override func lineFragmentRect(
    forProposedRect proposedRect: NSRect, at characterIndex: Int,
    writingDirection: NSWritingDirection,
    remaining remainingRect: UnsafeMutablePointer<NSRect>?
  ) -> NSRect {
    precondition(Thread.isMainThread, "Reader layout is main-thread owned")
    let controls = codeControls
    let geometry:
      (indent: CGFloat, gutter: CGFloat, offset: CGFloat, wrap: Bool, width: CGFloat, table: Bool)? =
        MainActor.assumeIsolated {
          guard let record = controls?.record(at: characterIndex) else { return nil }
          return (
            record.indent, record.gutter, record.offset, record.wrap, record.layoutWidth,
            record.kind == .table
          )
        }
    guard let geometry else {
      return super.lineFragmentRect(
        forProposedRect: proposedRect, at: characterIndex,
        writingDirection: writingDirection, remaining: remainingRect)
    }
    remainingRect?.pointee = .zero
    if geometry.table {
      // NSTextTable has already proposed each cell's own column position and width.
      // Preserve that geometry; only shift the whole table within its local viewport.
      return proposedRect.offsetBy(dx: -geometry.offset, dy: 0)
    }
    let available = max(60, size.width - geometry.indent - geometry.gutter - 16)
    return NSRect(
      x: geometry.indent + geometry.gutter - geometry.offset,
      y: proposedRect.minY,
      width: geometry.wrap ? available : max(available, geometry.width),
      height: proposedRect.height)
  }
}

@MainActor final class CodeLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
  // Read only from AppKit callbacks after the main-thread assertion below.
  nonisolated(unsafe) weak var codeControls: CodeBlockController?

  /// Reuse the screen's glyphs, attachments and stored attributes without drawing native
  /// views, insertion points, spelling marks or transient selection colors.
  func drawMinimap(in region: CGRect, textOrigin: CGPoint) {
    let controls = codeControls
    let previous = controls?.minimapSourceRect
    controls?.minimapSourceRect = region
    defer { controls?.minimapSourceRect = previous }
    guard let container = textContainers.first else { return }
    codeControls?.drawPanels(in: region)
    let glyphs = glyphRange(
      forBoundingRect: region.offsetBy(dx: -textOrigin.x, dy: -textOrigin.y), in: container)
    guard glyphs.length > 0 else { return }
    drawBackground(forGlyphRange: glyphs, at: textOrigin)
    drawGlyphs(forGlyphRange: glyphs, at: textOrigin)
    codeControls?.drawLineNumbers(in: region)
  }

  nonisolated func layoutManager(
    _ layoutManager: NSLayoutManager,
    shouldUseTemporaryAttributes attrs: [NSAttributedString.Key: Any],
    forDrawingToScreen toScreen: Bool, atCharacterIndex charIndex: Int,
    effectiveRange effectiveCharRange: NSRangePointer?
  ) -> [NSAttributedString.Key: Any]? {
    precondition(Thread.isMainThread, "Reader drawing is main-thread owned")
    let controls = codeControls
    let preview = MainActor.assumeIsolated { controls?.minimapSourceRect != nil }
    return !preview && toScreen ? attrs : nil
  }

  override init() {
    super.init()
    delegate = self
  }
  required init?(coder: NSCoder) {
    super.init(coder: coder)
    delegate = self
  }

  nonisolated func layoutManager(
    _ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
    properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
    characterIndexes: UnsafePointer<Int>, font: NSFont, forGlyphRange glyphRange: NSRange
  ) -> Int {
    precondition(Thread.isMainThread, "Reader glyphs are main-thread owned")
    let controls = codeControls
    let hidden = MainActor.assumeIsolated { controls?.hiddenRanges ?? [] }
    guard !hidden.isEmpty else { return 0 }
    var adjusted = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
    var changed = false
    for index in 0..<glyphRange.length
    where hidden.contains(where: { NSLocationInRange(characterIndexes[index], $0) }) {
      adjusted[index] = .null
      changed = true
    }
    guard changed else { return 0 }
    adjusted.withUnsafeBufferPointer { buffer in
      layoutManager.setGlyphs(
        glyphs, properties: buffer.baseAddress!, characterIndexes: characterIndexes,
        font: font, forGlyphRange: glyphRange)
    }
    return glyphRange.length
  }

  nonisolated func layoutManager(
    _ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
    forControlCharacterAt charIndex: Int
  ) -> NSLayoutManager.ControlCharacterAction {
    precondition(Thread.isMainThread, "Reader glyphs are main-thread owned")
    let controls = codeControls
    let hidden = MainActor.assumeIsolated { controls?.hiddenRanges ?? [] }
    return hidden.contains { NSLocationInRange(charIndex, $0) } ? .zeroAdvancement : action
  }

  override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    let segments = drawingSegments(glyphsToShow, origin: origin)
    for segment in segments {
      NSGraphicsContext.saveGraphicsState()
      segment.clip?.clip()
      super.drawGlyphs(forGlyphRange: segment.range, at: origin)
      NSGraphicsContext.restoreGraphicsState()
    }
  }

  override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    precondition(Thread.isMainThread, "Reader drawing is main-thread owned")
    let controls = codeControls
    MainActor.assumeIsolated {
      if controls?.minimapSourceRect == nil { controls?.drawPanels() }
    }
    let segments = drawingSegments(glyphsToShow, origin: origin)
    for segment in segments {
      NSGraphicsContext.saveGraphicsState()
      segment.clip?.clip()
      super.drawBackground(forGlyphRange: segment.range, at: origin)
      NSGraphicsContext.restoreGraphicsState()
    }
  }

  override func fillBackgroundRectArray(
    _ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
    forCharacterRange charRange: NSRange, color: NSColor
  ) {
    if charRange.location < (textStorage?.length ?? 0),
      textStorage?.attribute(.markupInlineCode, at: charRange.location, effectiveRange: nil) != nil,
      let background = textStorage?.attribute(
        .backgroundColor, at: charRange.location, effectiveRange: nil) as? NSColor,
      background == color
    {
      color.setFill()
      for rect in UnsafeBufferPointer(start: rectArray, count: rectCount) {
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
      }
    } else {
      super.fillBackgroundRectArray(
        rectArray, count: rectCount, forCharacterRange: charRange, color: color)
    }
  }

  nonisolated private func drawingSegments(_ glyphs: NSRange, origin: CGPoint) -> [(
    range: NSRange, clip: CGRect?
  )] {
    precondition(Thread.isMainThread, "Reader layout is main-thread owned")
    let controls = codeControls
    let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    let snapshot = MainActor.assumeIsolated {
      (
        controls?.records(intersecting: characters).map {
          ($0.range, $0.indent, $0.gutter, $0.kind == .code ? CGFloat(16) : 0)
        } ?? [],
        controls?.containerWidth ?? 1, controls?.documentHeight ?? 1
      )
    }
    guard !snapshot.0.isEmpty else { return [(glyphs, nil)] }
    var result: [(range: NSRange, clip: CGRect?)] = []
    var cursor = glyphs.location
    for record in snapshot.0 where NSIntersectionRange(characters, record.0).length > 0 {
      let codeGlyphs = glyphRange(forCharacterRange: record.0, actualCharacterRange: nil)
      let intersection = NSIntersectionRange(codeGlyphs, glyphs)
      guard intersection.length > 0 else { continue }
      if intersection.location > cursor {
        result.append((NSRange(location: cursor, length: intersection.location - cursor), nil))
      }
      // Clip selection/backgrounds and glyphs, while retaining the actual offset geometry
      // for the text system's native insertion-point and selection hit tests.
      let rect = NSRect(
        x: origin.x + record.1 + record.2,
        y: origin.y - 1, width: max(1, snapshot.1 - record.1 - record.2 - record.3),
        height: max(1, snapshot.2 + 2))
      result.append((intersection, rect))
      cursor = NSMaxRange(intersection)
    }
    if cursor < NSMaxRange(glyphs) {
      result.append((NSRange(location: cursor, length: NSMaxRange(glyphs) - cursor), nil))
    }
    return result
  }

}

@MainActor final class CodeBlockRecord {
  let id: String
  let kind: MarkdownBlockKind
  let range: NSRange
  let original: String
  let language: String
  let lineStarts: [Int]
  let indent: CGFloat
  let layoutWidth: CGFloat
  let tabInterval: CGFloat
  let surfaceColor: NSColor
  var wrap: Bool
  var numbers: Bool
  var offset: CGFloat = 0
  var contentWidth: CGFloat = 0
  var frame: CGRect = .zero
  var headerFrame: CGRect = .zero
  var scrollbarFrame: CGRect = .zero
  var measuredGeometryRevision = -1
  var limited = false
  var hiddenRange: NSRange?
  var foldCandidate: NSRange?
  var panelFrame: CGRect = .zero
  var controlColor: NSColor {
    let rgb = surfaceColor.usingColorSpace(.deviceRGB)
    let luminance =
      (rgb?.redComponent ?? 0) * 0.2126
      + (rgb?.greenComponent ?? 0) * 0.7152 + (rgb?.blueComponent ?? 0) * 0.0722
    return luminance > 0.5
      ? NSColor.black.withAlphaComponent(0.72) : NSColor.white.withAlphaComponent(0.78)
  }
  var gutter: CGFloat {
    kind == .table ? 0 : (numbers ? max(48, CGFloat(String(lineStarts.count).count) * 8 + 24) : 16)
  }

  init(
    id: String, range: NSRange, original: String, language: String, indent: CGFloat,
    font: NSFont, wrap: Bool, numbers: Bool, kind: MarkdownBlockKind = .code,
    tableWidth: CGFloat? = nil, surfaceColor: NSColor = .textBackgroundColor
  ) {
    self.kind = kind
    self.id = id
    self.range = range
    self.original = original
    self.language = language
    self.indent = indent
    self.wrap = wrap
    self.numbers = numbers
    self.surfaceColor = surfaceColor
    tabInterval = max(1, (" " as NSString).size(withAttributes: [.font: font]).width * 4)
    let source = original as NSString
    var starts = [range.location]
    var cursor = 0
    var longest = 1
    while cursor < source.length {
      let line = source.lineRange(for: NSRange(location: cursor, length: 0))
      longest = max(longest, line.length)
      cursor = NSMaxRange(line)
      if cursor < source.length { starts.append(range.location + cursor) }
    }
    lineStarts = starts
    // A conservative width permits a first native layout without measuring a second text copy.
    // Actual glyph bounds, measured from that same layout, determine the scrollbar extent.
    layoutWidth =
      tableWidth
      ?? (CGFloat(longest + 2) * max(32, font.maximumAdvancement.width, font.pointSize * 8))
  }
}

@MainActor final class CodeBlockController {
  // Scoped by CodeLayoutManager.drawMinimap; Objective-C callbacks read through the
  // existing weak actor-owned controller link after asserting the main thread.
  var minimapSourceRect: CGRect?
  private struct Options {
    var wrap: Bool?
    var numbers: Bool?
    var offset: CGFloat = 0
    var limited = false
  }
  weak var textView: ReaderTextView?
  private(set) var records: [CodeBlockRecord] = []
  private var byID: [String: CodeBlockRecord] = [:]
  private var overrides: [String: Options] = [:]
  private var headers: [String: CodeBlockHeader] = [:]
  private var scrollers: [String: CodeBlockScroller] = [:]
  private var currentPreferences = ReaderPreferences()
  private var geometryRevision = 0
  private var panelIndexRevision = -1
  private var panelRecords: [CodeBlockRecord] = []
  private(set) var geometryMeasurementCount = 0
  private(set) var previewRevision = 0
  var containerWidth: CGFloat { textView?.textContainer?.size.width ?? 1 }
  var documentHeight: CGFloat { textView?.bounds.height ?? 1 }
  private(set) var hiddenRanges: [NSRange] = []

  init(textView: ReaderTextView) { self.textView = textView }

  /// NSTextView supplies a specialized text accessibility tree which omits ordinary overlay
  /// subviews. Return the real, currently visible controls for the text view to append to it.
  var visibleAccessibilityElements: [NSView] {
    guard let textView else { return [] }
    let visible = textView.visibleRect
    var elements: [NSView] = []
    for record in records {
      if let header = headers[record.id], !header.isHidden, header.frame.intersects(visible) {
        header.layoutSubtreeIfNeeded()
        elements += header.subviews.filter { !$0.isHidden && $0.isAccessibilityElement() }
      }
      if let scroller = scrollers[record.id], !scroller.isHidden, scroller.frame.intersects(visible)
      {
        elements.append(scroller)
      }
    }
    return elements
  }

  func record(at character: Int) -> CodeBlockRecord? {
    guard let storage = textView?.textStorage, character < storage.length,
      let id = storage.attribute(.markupBlockID, at: character, effectiveRange: nil) as? String,
      let record = byID[id], NSLocationInRange(character, record.range)
    else { return nil }
    return record
  }

  /// Records are sorted, nonoverlapping text ranges. A tile/dirty glyph slice needs only
  /// the neighboring code/table records, even in documents with thousands of fences.
  func records(intersecting range: NSRange) -> ArraySlice<CodeBlockRecord> {
    guard range.length > 0 else { return records[0..<0] }
    var lower = 0
    var upper = records.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if NSMaxRange(records[middle].range) <= range.location {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    let start = lower
    while lower < records.count, records[lower].range.location < NSMaxRange(range) { lower += 1 }
    return records[start..<lower]
  }

  /// Adds layout attributes only. The character string and source-copy payload never change.
  func prepare(
    _ display: NSMutableAttributedString, rendered: RenderedDocument,
    document: MarkdownDocument?, preferences: ReaderPreferences
  ) {
    currentPreferences = preferences
    geometryRevision += 1
    previewRevision += 1
    panelRecords = []
    panelIndexRevision = -1
    hiddenRanges = []
    func flatten(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
      blocks.flatMap { [$0] + flatten($0.children) }
    }
    let sourceBlocks = Dictionary(
      uniqueKeysWithValues: flatten(document?.blocks ?? []).filter {
        $0.kind == .code || $0.kind == .table
      }.map { ($0.id, $0) })
    records = rendered.blocks.filter { $0.kind == .code || $0.kind == .table }.compactMap { block in
      guard let source = sourceBlocks[block.id], block.range.length > 0,
        block.range.location < display.length
      else { return nil }
      let isTable = block.kind == .table
      let original =
        isTable ? (display.string as NSString).substring(with: block.range) : source.code ?? ""
      // Include the renderer's terminating newline for an empty/no-final-newline code fence.
      let length =
        isTable
        ? block.range.length - 1
        : min(
          block.range.length - 1, max(1, original.utf16.count + (original.hasSuffix("\n") ? 0 : 1)))
      guard length > 0 else { return nil }
      let range = NSRange(location: block.range.location, length: length)
      let font =
        display.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        ?? .monospacedSystemFont(ofSize: preferences.codeSize * preferences.zoom, weight: .regular)
      let paragraph =
        display.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
        as? NSParagraphStyle
      let saved = overrides[block.id]
      let record = CodeBlockRecord(
        id: block.id, range: range, original: original,
        language: source.language ?? "plaintext", indent: paragraph?.headIndent ?? 0, font: font,
        wrap: isTable ? false : saved?.wrap ?? preferences.wrapCode,
        numbers: isTable ? false : saved?.numbers ?? preferences.lineNumbers, kind: block.kind,
        tableWidth: isTable
          ? CGFloat(max(1, source.table?.rows.map(\.count).max() ?? 1)) * 160 * preferences.zoom
          : nil,
        surfaceColor: rendered.attributedString.attribute(
          .backgroundColor, at: range.location, effectiveRange: nil) as? NSColor
          ?? .textBackgroundColor)
      record.offset = record.wrap ? 0 : saved?.offset ?? 0
      record.limited = !isTable && (saved?.limited ?? false)
      if isTable {
        prepareTable(record, storage: display)
      } else {
        // The screen paints one rounded surface. Preserve annotation backgrounds, while
        // removing only the renderer's original per-glyph code background from this copy.
        display.enumerateAttribute(.backgroundColor, in: range) { value, run, _ in
          if let color = value as? NSColor, color == record.surfaceColor {
            display.removeAttribute(.backgroundColor, range: run)
          }
        }
        applyLayout(record, to: display)
      }
      return record
    }.sorted { $0.range.location < $1.range.location }
    byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    overrides = overrides.filter { byID[$0.key] != nil }
  }

  private func prepareTable(_ record: CodeBlockRecord, storage: NSMutableAttributedString) {
    var copiedTables: [ObjectIdentifier: NSTextTable] = [:]
    storage.enumerateAttribute(.paragraphStyle, in: record.range) { value, range, _ in
      guard let paragraph = value as? NSParagraphStyle,
        let cell = paragraph.textBlocks.first as? NSTextTableBlock,
        let copied = paragraph.mutableCopy() as? NSMutableParagraphStyle
      else { return }
      let tableID = ObjectIdentifier(cell.table)
      let table: NSTextTable
      if let existing = copiedTables[tableID] {
        table = existing
      } else {
        table = ReaderOverflowTable(minimumWidth: record.layoutWidth)
        table.numberOfColumns = cell.table.numberOfColumns
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.setValue(
          max(containerWidth - record.indent, record.layoutWidth), type: .absoluteValueType,
          for: .width)
        copiedTables[tableID] = table
      }
      let newCell = NSTextTableBlock(
        table: table, startingRow: cell.startingRow, rowSpan: cell.rowSpan,
        startingColumn: cell.startingColumn, columnSpan: cell.columnSpan)
      newCell.setValue(
        max(containerWidth - record.indent, record.layoutWidth)
          / CGFloat(max(1, table.numberOfColumns)),
        type: .absoluteValueType, for: .width)
      newCell.setWidth(7 * currentPreferences.zoom, type: .absoluteValueType, for: .padding)
      newCell.setWidth(0.5, type: .absoluteValueType, for: .border)
      newCell.setBorderColor(.separatorColor)
      newCell.backgroundColor = cell.backgroundColor
      copied.textBlocks = [newCell]
      storage.addAttribute(.paragraphStyle, value: copied, range: range)
    }
  }

  private func applyLayout(_ record: CodeBlockRecord, to storage: NSMutableAttributedString) {
    let source = storage.string as NSString
    var cursor = record.range.location
    while cursor < NSMaxRange(record.range) {
      let line = NSIntersectionRange(
        source.paragraphRange(for: NSRange(location: cursor, length: 0)), record.range)
      guard line.length > 0 else { break }
      let original =
        storage.attribute(.paragraphStyle, at: cursor, effectiveRange: nil) as? NSParagraphStyle
      let paragraph =
        (original?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
      paragraph.lineBreakMode = .byCharWrapping
      paragraph.headIndent = 0
      paragraph.firstLineHeadIndent = 0
      paragraph.tailIndent = 0
      // System prose tab stops end after twelve positions; beyond that TextKit wraps
      // even a wide fragment. A repeating four-space interval keeps code tabs unwrapped.
      paragraph.tabStops = []
      paragraph.defaultTabInterval = record.tabInterval
      // A toolbar occupies paragraph spacing, not inserted/copied characters.
      paragraph.paragraphSpacingBefore = cursor == record.range.location ? 52 : 0
      paragraph.paragraphSpacing = NSMaxRange(line) == NSMaxRange(record.range) ? 28 : 0
      storage.addAttribute(.paragraphStyle, value: paragraph, range: line)
      cursor = NSMaxRange(line)
    }
  }

  func containerDidResize() {
    geometryRevision += 1
    previewRevision += 1
    guard let storage = textView?.textStorage, let layout = textView?.layoutManager else { return }
    for record in records where record.kind == .code { invalidateFold(record) }
    for record in records where record.kind == .table {
      guard NSMaxRange(record.range) <= storage.length else { continue }
      storage.enumerateAttribute(.paragraphStyle, in: record.range) { value, _, _ in
        guard let cell = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock else {
          return
        }
        let width = max(containerWidth - record.indent, record.layoutWidth)
        cell.table.setValue(width, type: .absoluteValueType, for: .width)
        cell.setValue(
          width / CGFloat(max(1, cell.table.numberOfColumns)), type: .absoluteValueType, for: .width
        )
      }
      layout.invalidateLayout(forCharacterRange: record.range, actualCharacterRange: nil)
    }
  }

  func updateFrames() {
    guard let text = textView, let layout = text.layoutManager, let container = text.textContainer
    else { return }
    let origin = text.textContainerOrigin
    let visible = text.visibleRect.insetBy(dx: 0, dy: -180)
    var visibleIDs = Set<String>()
    var clamped: [CodeBlockRecord] = []
    var folds: [CodeBlockRecord] = []
    for record in records {
      guard NSMaxRange(record.range) <= text.string.utf16.count else { continue }
      if record.measuredGeometryRevision != geometryRevision {
        let glyphs = layout.glyphRange(forCharacterRange: record.range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { continue }
        let first = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = layout.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        // boundingRect includes a newline's selection rectangle through the full proposed
        // width. Measure used line rectangles so scrolling ends at content, not blank space.
        var contentRight: CGFloat = 0
        if record.kind == .code {
          var cursor = glyphs.location
          var row = 0
          if record.hiddenRange == nil { record.foldCandidate = nil }
          while cursor < NSMaxRange(glyphs) {
            var line = NSRange()
            let used = layout.lineFragmentUsedRect(forGlyphAt: cursor, effectiveRange: &line)
            contentRight = max(contentRight, used.maxX)
            row += 1
            if row == 13, record.hiddenRange == nil {
              var boundary = layout.characterIndexForGlyph(at: cursor)
              let source = text.string as NSString
              if boundary > record.range.location, source.character(at: boundary - 1) == 10 {
                boundary -= 1
              }
              // Keep the block's final newline so following prose retains its own paragraph.
              let end = NSMaxRange(record.range) - 1
              if boundary < end {
                record.foldCandidate = NSRange(location: boundary, length: end - boundary)
              }
            }
            cursor = max(cursor + 1, NSMaxRange(line))
          }
          if record.limited, record.hiddenRange == nil, let hidden = record.foldCandidate {
            record.hiddenRange = hidden
            folds.append(record)
          }
        }
        let font =
          text.textStorage?.attribute(.font, at: record.range.location, effectiveRange: nil)
          as? NSFont
          ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        // Paragraph spacing is included in a line-fragment rectangle. Place overlays against
        // its actual baseline, so the toolbar cannot cover the preceding paragraph.
        let firstBaseline = first.minY + layout.location(forGlyphAt: glyphs.location).y
        let lastBaseline = last.minY + layout.location(forGlyphAt: NSMaxRange(glyphs) - 1).y
        let top = firstBaseline - font.ascender - 2
        let bottom = lastBaseline - font.descender + 2
        record.contentWidth =
          record.kind == .table
          ? max(containerWidth - record.indent, record.layoutWidth)
          : max(0, contentRight - record.indent - record.gutter + record.offset)
        record.frame = CGRect(
          x: origin.x + record.indent, y: origin.y + top,
          width: max(60, container.size.width - record.indent),
          height: max(font.pointSize, bottom - top))
        if record.kind == .table {
          record.frame.origin.y = origin.y + first.minY
          record.frame.size.height = max(first.height, last.maxY - first.minY)
        }
        record.measuredGeometryRevision = geometryRevision
        geometryMeasurementCount += 1
      }
      // Centering insets can change even while the configured content width stays fixed.
      record.frame.origin.x = origin.x + record.indent
      let limit = maximumOffset(record)
      if record.offset > limit {
        record.offset = limit
        var saved = overrides[record.id] ?? Options()
        saved.offset = limit
        overrides[record.id] = saved
        clamped.append(record)
      }
      record.headerFrame = CGRect(
        x: record.frame.minX, y: record.frame.minY - 48,
        width: record.frame.width, height: 36)
      record.panelFrame = record.headerFrame.union(record.frame)
      record.panelFrame.size.height += 24
      record.scrollbarFrame = CGRect(
        x: record.frame.minX + record.gutter,
        y: record.frame.maxY + 4,
        width: max(1, record.frame.width - record.gutter - (record.kind == .code ? 16 : 0)),
        height: 14)
      guard record.frame.union(record.headerFrame).intersects(visible) else { continue }
      visibleIDs.insert(record.id)
      if record.kind == .code {
        let header = headers[record.id] ?? CodeBlockHeader(record: record, owner: self)
        if header.superview == nil {
          text.addSubview(header)
          headers[record.id] = header
        }
        header.frame = record.headerFrame
        header.refresh(record)
      }
      let maxOffset = maximumOffset(record)
      if !record.wrap && maxOffset > 0 {
        let scroller =
          scrollers[record.id]
          ?? CodeBlockScroller(recordID: record.id, owner: self, table: record.kind == .table)
        if scroller.superview == nil {
          text.addSubview(scroller)
          scrollers[record.id] = scroller
        }
        scroller.frame = record.scrollbarFrame
        scroller.knobProportion = Double(
          min(1, record.scrollbarFrame.width / max(1, record.contentWidth)))
        scroller.doubleValue = Double(record.offset / maxOffset)
      } else {
        scrollers.removeValue(forKey: record.id)?.removeFromSuperview()
      }
    }
    if !folds.isEmpty {
      previewRevision += 1
      hiddenRanges.append(contentsOf: folds.compactMap(\.hiddenRange))
      for record in folds {
        if let range = record.hiddenRange {
          layout.invalidateGlyphs(
            forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
        }
      }
      geometryRevision += 1
      text.fitDocument()
      if let scroll = text.enclosingScrollView { text.frame.size.width = scroll.contentSize.width }
      updateFrames()
      text.needsDisplay = true
      return
    }
    if !clamped.isEmpty {
      previewRevision += 1
      for record in clamped {
        layout.invalidateLayout(forCharacterRange: record.range, actualCharacterRange: nil)
      }
      text.fitDocument()
      if let scroll = text.enclosingScrollView { text.frame.size.width = scroll.contentSize.width }
      updateFrames()
      text.needsDisplay = true
      return
    }
    for id in headers.keys.filter({ !visibleIDs.contains($0) }) {
      headers.removeValue(forKey: id)?.removeFromSuperview()
    }
    for id in scrollers.keys.filter({ !visibleIDs.contains($0) }) {
      scrollers.removeValue(forKey: id)?.removeFromSuperview()
    }
    if panelIndexRevision != geometryRevision {
      panelRecords = records.filter { $0.kind == .code }.sorted {
        $0.panelFrame.minY < $1.panelFrame.minY
      }
      panelIndexRevision = geometryRevision
    }
  }

  func toggleWrap(_ id: String, enabled: Bool) {
    guard let record = byID[id] else { return }
    var options = overrides[id] ?? Options()
    options.wrap = enabled
    options.offset = 0
    overrides[id] = options
    record.wrap = enabled
    record.offset = 0
    invalidateFold(record)
    geometryRevision += 1
    relayout(record)
  }

  func toggleNumbers(_ id: String, enabled: Bool) {
    guard let record = byID[id] else { return }
    var options = overrides[id] ?? Options()
    options.numbers = enabled
    overrides[id] = options
    record.numbers = enabled
    invalidateFold(record)
    geometryRevision += 1
    relayout(record)
  }

  func toggleLimit(_ id: String, enabled: Bool) {
    guard let record = byID[id], record.kind == .code,
      !enabled || record.foldCandidate != nil
    else { return }
    var options = overrides[id] ?? Options()
    options.limited = enabled
    overrides[id] = options
    record.limited = enabled
    invalidateFold(record)
    geometryRevision += 1
    relayout(record)
  }

  private func invalidateFold(_ record: CodeBlockRecord) {
    let previous = record.hiddenRange
    record.hiddenRange = nil
    record.foldCandidate = nil
    if let previous {
      hiddenRanges.removeAll { $0 == previous }
      textView?.layoutManager?.invalidateGlyphs(
        forCharacterRange: previous, changeInLength: 0, actualCharacterRange: nil)
    }
  }

  /// Search, keyboard selection and reading restoration reveal the original canonical range.
  @discardableResult
  func revealHiddenContent(in selection: NSRange) -> Bool {
    let hidden = records.filter { record in
      guard let range = record.hiddenRange else { return false }
      return selection.length == 0
        ? NSLocationInRange(selection.location, range)
        : NSIntersectionRange(selection, range).length > 0
    }
    for record in hidden { toggleLimit(record.id, enabled: false) }
    return !hidden.isEmpty
  }

  func setScroll(_ id: String, fraction: Double) {
    guard let record = byID[id], !record.wrap else { return }
    setOffset(record, value: CGFloat(fraction) * maximumOffset(record))
  }

  func revealSelection(_ selection: NSRange, previous: NSRange) {
    guard let text = textView, let layout = text.layoutManager else { return }
    if revealHiddenContent(in: selection) { text.scrollRangeToVisible(selection) }
    let active =
      selection.location != previous.location ? selection.location : NSMaxRange(selection)
    guard active < text.string.utf16.count, let record = record(at: active), !record.wrap else {
      return
    }
    let glyph = layout.glyphIndexForCharacter(at: active)
    let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    let x = fragment.minX + layout.location(forGlyphAt: glyph).x
    let left = record.indent + record.gutter
    let right = containerWidth - 16
    if x < left {
      setOffset(record, value: record.offset - (left - x))
    } else if x > right {
      setOffset(record, value: record.offset + x - right)
    }
  }

  func scrollWheel(_ event: NSEvent) -> Bool {
    guard let text = textView else { return false }
    let point = text.convert(event.locationInWindow, from: nil)
    guard let record = records.first(where: { !$0.wrap && $0.frame.contains(point) }),
      maximumOffset(record) > 0
    else { return false }
    let horizontal =
      event.modifierFlags.contains(.shift) ? event.scrollingDeltaY : event.scrollingDeltaX
    guard abs(horizontal) > 0,
      event.modifierFlags.contains(.shift) || abs(horizontal) > abs(event.scrollingDeltaY)
    else { return false }
    setOffset(
      record, value: record.offset - horizontal * (event.hasPreciseScrollingDeltas ? 1 : 12))
    return true
  }

  private func setOffset(_ record: CodeBlockRecord, value: CGFloat) {
    record.offset = max(0, min(maximumOffset(record), value))
    var options = overrides[record.id] ?? Options()
    options.offset = record.offset
    overrides[record.id] = options
    relayout(record)
  }

  private func maximumOffset(_ record: CodeBlockRecord) -> CGFloat {
    max(
      0,
      record.contentWidth
        - max(
          1,
          containerWidth - record.indent - record.gutter
            - (record.kind == .code ? 16 : 0)))
  }

  private func relayout(_ record: CodeBlockRecord) {
    guard let text = textView, let layout = text.layoutManager else { return }
    previewRevision += 1
    let visibleY = text.visibleRect.minY
    layout.invalidateLayout(forCharacterRange: record.range, actualCharacterRange: nil)
    layout.invalidateDisplay(forCharacterRange: record.range)
    text.fitDocument()
    if let scroll = text.enclosingScrollView { text.frame.size.width = scroll.contentSize.width }
    text.scroll(
      CGPoint(x: 0, y: min(visibleY, max(0, text.bounds.height - text.visibleRect.height))))
    updateFrames()
    text.needsDisplay = true
    text.geometryChanged?()
  }

  func drawLineNumbers(in dirty: CGRect) {
    guard let text = textView, let layout = text.layoutManager, let container = text.textContainer
    else { return }
    let origin = text.textContainerOrigin
    let font = NSFont.monospacedDigitSystemFont(
      ofSize: min(12, currentPreferences.codeSize * currentPreferences.zoom * 0.85),
      weight: .regular)
    let attrs: [NSAttributedString.Key: Any] = [
      .font: font
    ]
    let visibleGlyphs = layout.glyphRange(
      forBoundingRect: dirty.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
    let visibleCharacters = layout.characterRange(
      forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
    for record in records(intersecting: visibleCharacters)
    where record.numbers && record.frame.intersects(dirty) {
      func upperBound(_ value: Int) -> Int {
        var lower = 0
        var upper = record.lineStarts.count
        while lower < upper {
          let middle = (lower + upper) / 2
          if record.lineStarts[middle] <= value { lower = middle + 1 } else { upper = middle }
        }
        return lower
      }
      let first = max(0, upperBound(visibleCharacters.location) - 1)
      let last = upperBound(NSMaxRange(visibleCharacters))
      for index in first..<last {
        let character = record.lineStarts[index]
        guard character < text.string.utf16.count else { continue }
        if let hidden = record.hiddenRange, NSLocationInRange(character, hidden) { continue }
        let glyph = layout.glyphIndexForCharacter(at: character)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        var numberAttributes = attrs
        numberAttributes[.foregroundColor] = record.controlColor.withAlphaComponent(0.45)
        let label = NSAttributedString(string: String(index + 1), attributes: numberAttributes)
        label.draw(
          at: CGPoint(
            x: record.frame.minX + record.gutter - label.size().width - 11,
            y: origin.y + line.minY + layout.location(forGlyphAt: glyph).y - font.ascender))
      }
    }
  }

  func drawPanels(in region: CGRect? = nil) {
    guard let text = textView else { return }
    let dirty = region ?? text.visibleRect
    var lower = 0
    var upper = panelRecords.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if panelRecords[middle].panelFrame.maxY <= dirty.minY {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    while lower < panelRecords.count, panelRecords[lower].panelFrame.minY < dirty.maxY {
      let record = panelRecords[lower]
      lower += 1
      guard record.panelFrame.intersects(dirty) else { continue }
      let path = NSBezierPath(roundedRect: record.panelFrame, xRadius: 10, yRadius: 10)
      record.surfaceColor.setFill()
      path.fill()
      record.controlColor.withAlphaComponent(0.10).setStroke()
      path.lineWidth = 0.7
      path.stroke()
    }
  }
}

@MainActor private final class CodeControlButton: NSButton {
  var checkbox = false
  override func accessibilityRole() -> NSAccessibility.Role? { checkbox ? .checkBox : .button }
  override func accessibilityValue() -> Any? { checkbox ? NSNumber(value: state.rawValue) : nil }
  override func isAccessibilityEnabled() -> Bool { isEnabled }
  override func draw(_ dirtyRect: NSRect) {
    if isHighlighted || (checkbox && state == .on) {
      (contentTintColor ?? .labelColor).withAlphaComponent(isHighlighted ? 0.18 : 0.10).setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
    super.draw(dirtyRect)
  }
  override func accessibilityPerformPress() -> Bool {
    guard isEnabled else { return false }
    performClick(nil)
    if checkbox { NSAccessibility.post(element: self, notification: .valueChanged) }
    return true
  }
  override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
    if selector == #selector(accessibilityPerformPress) { return isEnabled }
    return super.isAccessibilitySelectorAllowed(selector)
  }
}

@MainActor private final class CodeBlockHeader: NSView {
  private let recordID: String
  private let original: String
  private weak var owner: CodeBlockController?
  private let languageIcon = NSImageView()
  private let language = NSTextField(labelWithString: "")
  private let copyButton = CodeControlButton()
  private let wrapButton = CodeControlButton()
  private let numbersButton = CodeControlButton()
  private let heightButton = CodeControlButton()
  private let optionsButton = CodeControlButton()
  private var feedbackTask: Task<Void, Never>?
  private var limited = false

  init(record: CodeBlockRecord, owner: CodeBlockController) {
    recordID = record.id
    original = record.original
    self.owner = owner
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("code-block-header")
    language.font = .systemFont(ofSize: 11, weight: .medium)
    language.lineBreakMode = .byTruncatingTail
    language.setAccessibilityRole(.staticText)
    languageIcon.image = NSImage(
      systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
    languageIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
    languageIcon.setAccessibilityElement(false)
    addSubview(languageIcon)
    wrapButton.checkbox = true
    numbersButton.checkbox = true
    wrapButton.setButtonType(.pushOnPushOff)
    numbersButton.setButtonType(.pushOnPushOff)
    for (button, identifier, symbol, action) in [
      (copyButton, "code-copy", "doc.on.doc", #selector(copyCode)),
      (wrapButton, "code-wrap", "arrow.turn.down.left", #selector(toggleWrap)),
      (numbersButton, "code-lines", "list.number", #selector(toggleNumbers)),
      (heightButton, "code-height", "arrow.down.right.and.arrow.up.left", #selector(toggleHeight)),
      (optionsButton, "code-options", "ellipsis", #selector(showOptions)),
    ] {
      button.identifier = NSUserInterfaceItemIdentifier(identifier)
      button.bezelStyle = .inline
      button.isBordered = false
      button.imagePosition = .imageOnly
      button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
      button.target = self
      button.action = action
      button.setAccessibilityElement(true)
      addSubview(button)
    }
    language.setAccessibilityElement(true)
    addSubview(language)
    refresh(record)
  }
  required init?(coder: NSCoder) { nil }
  override var isFlipped: Bool { true }

  func refresh(_ record: CodeBlockRecord) {
    limited = record.limited
    language.stringValue = record.language
    language.setAccessibilityValue(record.language)
    language.setAccessibilityLabel(localized("Code language") + ": " + record.language)
    if feedbackTask == nil { copyButton.title = localized("Copy") }
    copyButton.setAccessibilityLabel(localized("Copy code"))
    copyButton.toolTip = localized("Copy code")
    wrapButton.title = localized("Wrap")
    wrapButton.state = record.wrap ? .on : .off
    wrapButton.setAccessibilityLabel(localized("Wrap this code block"))
    wrapButton.toolTip = localized("Wrap this code block")
    numbersButton.title = localized("Lines")
    numbersButton.state = record.numbers ? .on : .off
    numbersButton.setAccessibilityLabel(localized("Line numbers for this code block"))
    numbersButton.toolTip = localized("Line numbers for this code block")
    heightButton.title = localized(record.limited ? "Show all code" : "Limit code height")
    heightButton.setAccessibilityLabel(heightButton.title)
    heightButton.isEnabled = record.foldCandidate != nil || record.hiddenRange != nil
    heightButton.toolTip =
      heightButton.isEnabled ? heightButton.title : localized("All code is already visible")
    heightButton.image = NSImage(
      systemSymbolName: record.limited
        ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
      accessibilityDescription: nil)
    optionsButton.title = "…"
    optionsButton.setAccessibilityLabel(
      localized("Wrap") + ", " + localized("Lines") + ", " + heightButton.title)
    optionsButton.toolTip = optionsButton.accessibilityLabel()
    language.textColor = record.controlColor
    languageIcon.contentTintColor = record.controlColor
    for button in [copyButton, wrapButton, numbersButton, heightButton, optionsButton] {
      // AppKit can change imagePosition when a localized title is assigned. Keep those
      // native titles for accessibility, but apply the icon-only layout after every refresh.
      button.imagePosition = .imageOnly
      button.contentTintColor = record.controlColor
      button.needsDisplay = true
    }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let compact = bounds.width < 176
    let tiny = bounds.width < 112
    wrapButton.isHidden = compact
    numbersButton.isHidden = compact
    heightButton.isHidden = compact
    optionsButton.isHidden = !compact
    languageIcon.isHidden = tiny
    language.isHidden = tiny
    let inset: CGFloat = tiny ? 4 : 10
    copyButton.frame = CGRect(x: max(inset, bounds.width - inset - 26), y: 5, width: 26, height: 26)
    let firstControl: CGFloat
    if compact {
      optionsButton.frame = CGRect(
        x: max(inset, copyButton.frame.minX - 30), y: 5, width: 26, height: 26)
      firstControl = optionsButton.frame.minX
    } else {
      heightButton.frame = CGRect(x: copyButton.frame.minX - 30, y: 5, width: 26, height: 26)
      numbersButton.frame = CGRect(x: heightButton.frame.minX - 30, y: 5, width: 26, height: 26)
      wrapButton.frame = CGRect(x: numbersButton.frame.minX - 30, y: 5, width: 26, height: 26)
      firstControl = wrapButton.frame.minX
    }
    languageIcon.frame = CGRect(x: 12, y: 11, width: 14, height: 14)
    language.frame = CGRect(x: 33, y: 10, width: max(0, firstControl - 39), height: 17)
  }

  @objc private func copyCode() {
    NSPasteboard.general.clearContents()
    guard NSPasteboard.general.setString(original, forType: .string) else { return }
    copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
    copyButton.title = localized("Copied")
    copyButton.imagePosition = .imageOnly
    copyButton.setAccessibilityLabel(localized("Code copied"))
    copyButton.toolTip = localized("Code copied")
    NSAccessibility.post(element: copyButton, notification: .valueChanged)
    feedbackTask?.cancel()
    feedbackTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
      guard let self else { return }
      copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
      copyButton.title = localized("Copy")
      copyButton.imagePosition = .imageOnly
      copyButton.setAccessibilityLabel(localized("Copy code"))
      copyButton.toolTip = localized("Copy code")
      feedbackTask = nil
    }
  }
  @objc private func toggleWrap() { owner?.toggleWrap(recordID, enabled: wrapButton.state == .on) }
  @objc private func toggleNumbers() {
    owner?.toggleNumbers(recordID, enabled: numbersButton.state == .on)
  }
  @objc private func toggleHeight() { owner?.toggleLimit(recordID, enabled: !limited) }
  @objc private func showOptions() {
    let menu = NSMenu()
    for (title, action, state, enabled) in [
      (localized("Wrap this code block"), #selector(toggleWrapFromMenu), wrapButton.state, true),
      (
        localized("Line numbers for this code block"), #selector(toggleNumbersFromMenu),
        numbersButton.state, true
      ),
      (
        heightButton.title, #selector(toggleHeight), NSControl.StateValue.off,
        heightButton.isEnabled
      ),
    ] {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      item.state = state
      item.isEnabled = enabled
      menu.addItem(item)
    }
    menu.autoenablesItems = false
    menu.popUp(
      positioning: nil, at: NSPoint(x: optionsButton.frame.minX, y: optionsButton.frame.maxY),
      in: self)
  }
  @objc private func toggleWrapFromMenu() {
    owner?.toggleWrap(recordID, enabled: wrapButton.state != .on)
  }
  @objc private func toggleNumbersFromMenu() {
    owner?.toggleNumbers(recordID, enabled: numbersButton.state != .on)
  }
}

@MainActor private final class CodeBlockScroller: NSScroller {
  private let recordID: String
  private weak var owner: CodeBlockController?
  init(recordID: String, owner: CodeBlockController, table: Bool = false) {
    self.recordID = recordID
    self.owner = owner
    super.init(frame: CGRect(x: 0, y: 0, width: 300, height: 14))
    scrollerStyle = table ? .legacy : .overlay
    controlSize = .small
    isEnabled = true
    target = self
    action = #selector(scrolled)
    setAccessibilityElement(true)
    setAccessibilityLabel(
      table ? localized("Horizontal table scroll") : localized("Horizontal code scroll"))
  }
  required init?(coder: NSCoder) { nil }
  override func accessibilityRole() -> NSAccessibility.Role? { .scrollBar }
  override func accessibilityValue() -> Any? { NSNumber(value: doubleValue) }
  override func accessibilityMinValue() -> Any? { NSNumber(value: 0) }
  override func accessibilityMaxValue() -> Any? { NSNumber(value: 1) }
  override func accessibilityOrientation() -> NSAccessibilityOrientation { .horizontal }
  override func accessibilityPerformIncrement() -> Bool {
    accessibilityScroll(by: max(0.05, knobProportion))
  }
  override func accessibilityPerformDecrement() -> Bool {
    accessibilityScroll(by: -max(0.05, knobProportion))
  }
  override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
    if selector == #selector(accessibilityPerformIncrement)
      || selector == #selector(accessibilityPerformDecrement)
    {
      return isEnabled
    }
    return super.isAccessibilitySelectorAllowed(selector)
  }
  private func accessibilityScroll(by fraction: Double) -> Bool {
    guard isEnabled, let owner else { return false }
    let next = min(1, max(0, doubleValue + fraction))
    guard next != doubleValue else { return false }
    doubleValue = next
    owner.setScroll(recordID, fraction: next)
    NSAccessibility.post(element: self, notification: .valueChanged)
    return true
  }
  @objc private func scrolled() {
    switch hitPart {
    case .decrementLine: doubleValue = max(0, doubleValue - 0.03)
    case .incrementLine: doubleValue = min(1, doubleValue + 0.03)
    case .decrementPage: doubleValue = max(0, doubleValue - knobProportion)
    case .incrementPage: doubleValue = min(1, doubleValue + knobProportion)
    default: break
    }
    owner?.setScroll(recordID, fraction: doubleValue)
  }
}
