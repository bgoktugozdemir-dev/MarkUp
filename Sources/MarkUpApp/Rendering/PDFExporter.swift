import AppKit
import CoreText
import Darwin

struct PDFOptions {
  enum Paper: String, CaseIterable { case a4, letter }
  var paper: Paper = .a4
  var landscape = false
  var margin = 42.0
  var includeAnnotations = false
  var currentAppearance = false

  var paperSize: NSSize {
    let size =
      paper == .a4 ? NSSize(width: 595.276, height: 841.89) : NSSize(width: 612, height: 792)
    return landscape ? NSSize(width: size.height, height: size.width) : size
  }
}

enum PDFExportError: Error {
  case invalidMargins, layoutFailed, tooManyPages, couldNotWrite, invalidPDF
}

struct PDFExportProgress: Equatable, Sendable {
  enum Stage: String, Sendable { case preparing, paginating, navigation, drawing, writing }
  var stage: Stage
  var completed: Int
  var total: Int?
}

/// Native AppKit layout remains main-actor owned. Every bounded page/preparation batch yields
/// so Cancel, window close, and ordinary UI events can run without sharing native text objects.
@MainActor
final class PDFExporter {
  func export(
    rendered: RenderedDocument, to destination: URL, options: PDFOptions,
    progress: (PDFExportProgress) -> Void = { _ in }
  ) async throws {
    let layout = try await PaginatedText.make(
      rendered: rendered, options: options, progress: progress)
    let data = NSMutableData()
    var mediaBox = CGRect(origin: .zero, size: options.paperSize)
    guard let consumer = CGDataConsumer(data: data),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else { throw PDFExportError.couldNotWrite }
    var closed = false
    var pageOpen = false
    defer {
      if pageOpen { context.endPDFPage() }
      if !closed { context.closePDF() }
    }
    for page in layout.containers.indices {
      try Task.checkCancellation()
      context.beginPDFPage(nil)
      pageOpen = true
      context.saveGState()
      context.translateBy(x: 0, y: options.paperSize.height)
      context.scaleBy(x: 1, y: -1)
      layout.draw(page: page, context: context)
      context.restoreGState()
      try await layout.addNavigation(page: page, context: context)
      context.endPDFPage()
      pageOpen = false
      progress(
        PDFExportProgress(stage: .drawing, completed: page + 1, total: layout.containers.count))
      try await Self.checkpoint()
    }
    CGPDFContextSetOutline(context, layout.outline())
    context.closePDF()
    closed = true
    try await Self.checkpoint()
    let final = data as Data
    guard let provider = CGDataProvider(data: final as CFData),
      let verified = CGPDFDocument(provider),
      verified.numberOfPages == layout.containers.count
    else { throw PDFExportError.invalidPDF }
    progress(PDFExportProgress(stage: .writing, completed: 0, total: 1))
    try await Self.checkpoint()
    try await PDFFileWriter.write(final, to: destination)
    progress(PDFExportProgress(stage: .writing, completed: 1, total: 1))
  }

  func print(
    rendered: RenderedDocument, options: PDFOptions,
    progress: (PDFExportProgress) -> Void = { _ in }
  ) async throws -> Bool {
    let layout = try await PaginatedText.make(
      rendered: rendered, options: options, progress: progress)
    try Task.checkCancellation()
    let view = PrintableTextView(layout: layout)
    let info = NSPrintInfo()
    info.paperSize = options.paperSize
    info.leftMargin = 0
    info.rightMargin = 0
    info.topMargin = 0
    info.bottomMargin = 0
    info.horizontalPagination = .fit
    info.verticalPagination = .automatic
    info.isHorizontallyCentered = false
    info.isVerticallyCentered = false
    let operation = NSPrintOperation(view: view, printInfo: info)
    operation.showsPrintPanel = true
    operation.showsProgressPanel = true
    return operation.run()
  }

  static func checkpoint() async throws {
    try Task.checkCancellation()
    await Task.yield()
    try Task.checkCancellation()
  }
}

/// Only immutable PDF bytes and the exact save-panel URL cross this boundary. An OS-provided
/// replacement directory avoids requesting access to an ungranted sibling of the selected file.
/// Staging remains cancellable; Foundation performs the final coordinated atomic commit.
private enum PDFFileWriter {
  nonisolated static func write(_ data: Data, to destination: URL) async throws {
    let cancellation = PDFWriteCancellation()
    let writer = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let accessed = destination.startAccessingSecurityScopedResource()
      defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
      let manager = FileManager()
      let directory = try manager.url(
        for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination,
        create: true)
      var removeReplacementDirectory = true
      defer { if removeReplacementDirectory { try? manager.removeItem(at: directory) } }
      let temporary = directory.appendingPathComponent("export.pdf")
      let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
      guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      defer { try? handle.close() }
      var offset = 0
      while offset < data.count {
        try Task.checkCancellation()
        let end = min(data.count, offset + 256 * 1024)
        try handle.write(contentsOf: data.subdata(in: offset..<end))
        offset = end
      }
      try handle.synchronize()
      try handle.close()
      try Task.checkCancellation()
      let coordinator = NSFileCoordinator(filePresenter: nil)
      cancellation.register(coordinator)
      defer { cancellation.clear() }
      try Task.checkCancellation()
      var coordinationError: NSError?
      var commitError: (any Error)?
      coordinator.coordinate(
        writingItemAt: destination, options: .forReplacing, error: &coordinationError
      ) { target in
        do {
          try Task.checkCancellation()
          let attributes: [FileAttributeKey: Any]?
          do {
            attributes = try manager.attributesOfItem(atPath: target.path)
          } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
          {
            attributes = nil
          }
          if let attributes {
            // Never replace a directory/package or a symlink with a PDF. In particular, a failed
            // commit must not remove unrelated owner files merely because replacement supports it.
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
              throw PDFExportError.couldNotWrite
            }
            do {
              _ = try manager.replaceItemAt(
                target, withItemAt: temporary, options: .usingNewMetadataOnly)
            } catch {
              // Foundation may retain the original in a recovery location after a failed
              // replacement. Preserve this private OS directory rather than risk deleting it.
              // Staging cancellation, preflight failures and successful commits still clean up.
              removeReplacementDirectory = false
              throw error
            }
          } else {
            // The selected file need not exist yet. moveItem commits the fully staged file;
            // unlike a direct write, cancellation/failure never exposes a partial new PDF.
            try manager.moveItem(at: temporary, to: target)
          }
        } catch { commitError = error }
      }
      if let commitError { throw commitError }
      if let coordinationError {
        if Task.isCancelled
          || (coordinationError.domain == NSCocoaErrorDomain
            && coordinationError.code == NSUserCancelledError)
        {
          throw CancellationError()
        }
        throw coordinationError
      }
    }
    try await withTaskCancellationHandler {
      try await writer.value
    } onCancel: {
      writer.cancel()
      cancellation.cancel()
    }
  }
}

/// Synchronizes only cancellation and the coordinator reference. All coordination and file work
/// run on the writer's single thread; the sole cross-thread coordinator call is cancel(), which
/// Apple explicitly documents as callable from any thread and immediately returning.
/// https://developer.apple.com/documentation/foundation/nsfilecoordinator/cancel()
private final class PDFWriteCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var coordinator: NSFileCoordinator?
  private var cancelled = false

  func register(_ coordinator: NSFileCoordinator) {
    let shouldCancel = lock.withLock {
      self.coordinator = coordinator
      return cancelled
    }
    if shouldCancel { coordinator.cancel() }
  }

  func clear() { lock.withLock { coordinator = nil } }

  func cancel() {
    let active = lock.withLock {
      cancelled = true
      return coordinator
    }
    active?.cancel()
  }
}

@MainActor
private final class PaginatedText: NSObject, @MainActor NSLayoutManagerDelegate {
  let storage: NSTextStorage
  let manager: NSLayoutManager
  var containers: [NSTextContainer] = []
  let options: PDFOptions
  let drawingAppearance: NSAppearance

  init(rendered: RenderedDocument, options: PDFOptions) throws {
    let paper = options.paperSize
    guard options.margin.isFinite, options.margin >= 12,
      options.margin * 2 < paper.width - 80, options.margin * 2 < paper.height - 80
    else {
      throw PDFExportError.invalidMargins
    }
    self.options = options
    drawingAppearance =
      options.currentAppearance
      ? NSApp.keyWindow?.effectiveAppearance ?? NSApp.effectiveAppearance
      : NSAppearance(named: .aqua)!
    storage = NSTextStorage(attributedString: rendered.attributedString)
    manager = NSLayoutManager()
    manager.usesFontLeading = true
    manager.backgroundLayoutEnabled = false
    super.init()
    manager.delegate = self
    storage.addLayoutManager(manager)
  }

  static func make(
    rendered: RenderedDocument, options: PDFOptions,
    progress: (PDFExportProgress) -> Void
  ) async throws -> PaginatedText {
    progress(PDFExportProgress(stage: .preparing, completed: 0, total: nil))
    try await PDFExporter.checkpoint()
    let layout = try PaginatedText(rendered: rendered, options: options)
    try await layout.prepareText()
    try await layout.prepareLayout(progress: progress)
    try await layout.prepareNavigation(progress: progress)
    return layout
  }

  private func prepareText() async throws {
    let paper = options.paperSize
    let text = storage
    try await Self.prepareTables(
      text, width: paper.width - 2 * options.margin, height: paper.height - 2 * options.margin)
    let entire = NSRange(location: 0, length: text.length)
    // Resolve the system UI font's ambiguous CJK fallback to an installed font with correct Unicode mappings.
    // Otherwise Quartz can emit a Kangxi-radical alias in ToUnicode instead of the source ideograph.
    var fontRuns: [(NSRange, NSFont)] = []
    text.enumerateAttribute(.font, in: entire) { value, range, _ in
      if let font = value as? NSFont { fontRuns.append((range, font)) }
    }
    var inspected = 0
    for (range, font) in fontRuns {
      try Task.checkCancellation()
      if (CTFontCopyPostScriptName(font) as String).hasPrefix(".SF") {
        // The UI language is not the document language. SF's Turkish localized i glyph has
        // no Unicode cmap entry on affected systems: Quartz emits an empty ToUnicode subset
        // and copied PDF text becomes '!'. Undetermined language uses the mapped glyph,
        // preserving the original font, size, weight and every source Unicode character.
        text.addAttribute(Self.shapingLanguage, value: "und", range: range)
      }
      let substring = (text.string as NSString).substring(with: range)
      var cursor = range.location
      for character in substring {
        inspected += 1
        if inspected % 2048 == 0 { try await PDFExporter.checkpoint() }
        let string = String(character)
        let length = string.utf16.count
        defer { cursor += length }
        guard
          character.unicodeScalars.contains(where: {
            (0x2E80...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
          })
        else { continue }
        let fallback = CTFontCreateForString(
          font, string as CFString, CFRange(location: 0, length: length))
        let name = CTFontCopyPostScriptName(fallback) as String
        guard name.hasPrefix(".PingFangUIText"),
          let concrete = NSFont(
            name: NSFontManager.shared.traits(of: font).contains(.boldFontMask)
              ? "HiraginoSans-W6" : "HiraginoSans-W3", size: font.pointSize)
        else { continue }
        text.addAttribute(.font, value: concrete, range: NSRange(location: cursor, length: length))
      }
    }
    let contentWidth = paper.width - 2 * options.margin
    let contentHeight = paper.height - 2 * options.margin
    var attachments: [(NSRange, NSTextAttachment)] = []
    text.enumerateAttribute(.attachment, in: entire) { value, range, _ in
      if let value = value as? NSTextAttachment { attachments.append((range, value)) }
    }
    for (range, original) in attachments {
      try await PDFExporter.checkpoint()
      guard let image = original.image?.copy() as? NSImage, image.size.width > 0,
        image.size.height > 0
      else { continue }
      let paragraph =
        text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
        as? NSParagraphStyle
      let columns = (paragraph?.textBlocks.first as? NSTextTableBlock)?.table.numberOfColumns ?? 1
      let availableWidth = contentWidth / Double(max(1, columns)) - 14
      let scale = min(1, availableWidth / image.size.width, contentHeight / image.size.height)
      image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
      let attachment = NSTextAttachment()
      attachment.image = image
      text.addAttribute(.attachment, value: attachment, range: range)
    }
    // PDF never truncates long unwrapped screen code. Reflow only changes paragraph layout.
    var paragraphs: [(NSRange, NSParagraphStyle)] = []
    text.enumerateAttribute(.paragraphStyle, in: entire) { value, range, _ in
      if let value = value as? NSParagraphStyle { paragraphs.append((range, value)) }
    }
    for (index, entry) in paragraphs.enumerated() {
      if index % 256 == 0 { try await PDFExporter.checkpoint() }
      guard let style = entry.1.mutableCopy() as? NSMutableParagraphStyle else { continue }
      if style.lineBreakMode == .byClipping { style.lineBreakMode = .byCharWrapping }
      text.addAttribute(.paragraphStyle, value: style, range: entry.0)
    }
    var links: [(NSRange, String)] = []
    text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) {
      value, range, _ in
      if let raw = value as? String { links.append((range, raw)) }
    }
    for (index, entry) in links.enumerated() {
      if index % 256 == 0 { try await PDFExporter.checkpoint() }
      text.addAttribute(Self.exportLink, value: entry.1, range: entry.0)
    }
    // Strip AppKit's automatic PDF links before pagination. Editing attributes after layout would
    // invalidate its geometry and could strand a heading after orphan repair had already run.
    text.removeAttribute(.link, range: NSRange(location: 0, length: text.length))
    try await PDFExporter.checkpoint()
  }

  private static let exportLink = NSAttributedString.Key("MarkUp.PDFLink")
  private static let shapingLanguage = NSAttributedString.Key(kCTLanguageAttributeName as String)

  private func prepareLayout(progress: (PDFExportProgress) -> Void) async throws {
    let paper = options.paperSize
    let pageContent = NSSize(
      width: paper.width - 2 * options.margin, height: paper.height - 2 * options.margin)
    try await paginate(size: pageContent, progress: progress)
    // Move orphan headings to the following page without shrinking text or changing the source.
    while true {
      try await PDFExporter.checkpoint()
      guard keepHeadingsWithFollowingText() else { break }
      while !manager.textContainers.isEmpty { manager.removeTextContainer(at: 0) }
      containers.removeAll()
      try await paginate(size: pageContent, progress: progress)
    }
  }

  // Each heading can force a page break only once, so repair converges in at most the
  // heading count while still allowing a shift to reveal another later orphan.
  private var forcedHeadingAnchors = Set<String>()

  private func paginate(size: NSSize, progress: (PDFExportProgress) -> Void) async throws {
    var previousEnd = 0
    repeat {
      try Task.checkCancellation()
      guard containers.count < 10_000 else { throw PDFExportError.tooManyPages }
      let container = NSTextContainer(containerSize: size)
      container.lineFragmentPadding = 0
      manager.addTextContainer(container)
      containers.append(container)
      manager.ensureLayout(for: container)
      let range = manager.glyphRange(for: container)
      let end = NSMaxRange(range)
      progress(PDFExportProgress(stage: .paginating, completed: containers.count, total: nil))
      try await PDFExporter.checkpoint()
      if end >= manager.numberOfGlyphs { break }
      guard end > previousEnd else { throw PDFExportError.layoutFailed }
      previousEnd = end
    } while true
  }

  func layoutManager(
    _ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
    forControlCharacterAt charIndex: Int
  ) -> NSLayoutManager.ControlCharacterAction {
    (storage.string as NSString).character(at: charIndex) == 12 ? .containerBreak : action
  }

  private func keepHeadingsWithFollowingText() -> Bool {
    let string = storage.string as NSString
    var breaks: [(offset: Int, anchor: String)] = []
    storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) {
      value, range, _ in
      guard let paragraph = value as? NSParagraphStyle, paragraph.headerLevel > 0, range.length > 0
      else { return }
      guard
        let anchor = storage.attribute(.markupAnchor, at: range.location, effectiveRange: nil)
          as? String, !forcedHeadingAnchors.contains(anchor)
      else { return }
      var next = NSMaxRange(range)
      while next < string.length, let scalar = UnicodeScalar(string.character(at: next)),
        CharacterSet.whitespacesAndNewlines.contains(scalar)
      { next += 1 }
      guard next < string.length else { return }
      let firstGlyph = manager.glyphIndexForCharacter(at: range.location)
      let nextGlyph = manager.glyphIndexForCharacter(at: next)
      guard let firstContainer = manager.textContainer(forGlyphAt: firstGlyph, effectiveRange: nil),
        let nextContainer = manager.textContainer(forGlyphAt: nextGlyph, effectiveRange: nil),
        firstContainer !== nextContainer,
        manager.glyphRange(for: firstContainer).location < firstGlyph
      else { return }
      // A trailing newline can belong to the next container even when every visible heading
      // glyph is stranded on the previous page. Inspect the last content glyph, not that newline.
      var contentEnd = NSMaxRange(range)
      while contentEnd > range.location,
        let scalar = UnicodeScalar(string.character(at: contentEnd - 1)),
        CharacterSet.whitespacesAndNewlines.contains(scalar)
      { contentEnd -= 1 }
      guard contentEnd > range.location else { return }
      // A heading whose actual text is taller than a page must be allowed to flow normally.
      let lastGlyph = manager.glyphIndexForCharacter(at: contentEnd - 1)
      guard manager.textContainer(forGlyphAt: lastGlyph, effectiveRange: nil) === firstContainer
      else { return }
      breaks.append((range.location, anchor))
    }
    for entry in breaks.sorted(by: { $0.offset > $1.offset }) {
      let offset = entry.offset
      forcedHeadingAnchors.insert(entry.anchor)
      var attrs = storage.attributes(at: offset, effectiveRange: nil)
      attrs.removeValue(forKey: .markupAnchor)
      attrs[.paragraphStyle] = NSParagraphStyle.default
      storage.insert(NSAttributedString(string: "\u{000c}", attributes: attrs), at: offset)
    }
    return !breaks.isEmpty
  }

  /// TextKit tables cannot reliably split a very tall row. Multi-page tables therefore use a
  /// flowing cell layout with the original column heading repeated at every value. Short tables
  /// retain their grid. This avoids clipped cells and keeps column context on every PDF page.
  private static func prepareTables(
    _ text: NSMutableAttributedString, width: Double, height: Double
  ) async throws {
    struct Cell {
      var range: NSRange
      var block: NSTextTableBlock
    }
    var tables: [ObjectIdentifier: [Cell]] = [:]
    text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) {
      value, range, _ in
      guard let block = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock else {
        return
      }
      tables[ObjectIdentifier(block.table), default: []].append(Cell(range: range, block: block))
    }
    var replacements: [(NSRange, NSAttributedString)] = []
    for cells in tables.values {
      try await PDFExporter.checkpoint()
      var rowHeights: [Int: Double] = [:]
      var headers: [Int: String] = [:]
      for cell in cells {
        try await PDFExporter.checkpoint()
        let content = NSMutableAttributedString(
          attributedString: text.attributedSubstring(from: cell.range))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        content.addAttribute(
          .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: content.length))
        let cellWidth = max(40, width / Double(max(1, cell.block.table.numberOfColumns)) - 14)
        let measured =
          content.length > 8192
          ? height + 1
          : content.boundingRect(
            with: NSSize(width: cellWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
          ).height + 14
        rowHeights[cell.block.startingRow] = max(
          rowHeights[cell.block.startingRow, default: 0], measured)
        if cell.block.startingRow == 0 {
          headers[cell.block.startingColumn] = content.string.trimmingCharacters(
            in: .whitespacesAndNewlines)
        }
      }
      guard rowHeights.values.reduce(0, +) > height * 0.8 else { continue }
      for cell in cells {
        try await PDFExporter.checkpoint()
        let content = NSMutableAttributedString(
          attributedString: text.attributedSubstring(from: cell.range))
        content.enumerateAttribute(
          .paragraphStyle, in: NSRange(location: 0, length: content.length)
        ) { value, range, _ in
          let paragraph =
            ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
            ?? NSMutableParagraphStyle()
          paragraph.textBlocks = []
          paragraph.headIndent = 0
          paragraph.firstLineHeadIndent = 0
          paragraph.alignment = .left
          paragraph.lineBreakMode = .byWordWrapping
          content.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
        if cell.block.startingRow > 0, let heading = headers[cell.block.startingColumn],
          !heading.isEmpty
        {
          content.addAttribute(
            .markupTableColumn, value: heading, range: NSRange(location: 0, length: content.length))
          var attributes = content.length > 0 ? content.attributes(at: 0, effectiveRange: nil) : [:]
          if let font = attributes[.font] as? NSFont {
            attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
          }
          let label = NSAttributedString(string: heading + ": ", attributes: attributes)
          content.insert(label, at: 0)
        }
        replacements.append((cell.range, content))
      }
    }
    for (range, replacement) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
      try await PDFExporter.checkpoint()
      text.replaceCharacters(in: range, with: replacement)
    }
  }

  func draw(page: Int, context: CGContext) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    context.saveGState()
    defer {
      context.restoreGState()
      NSGraphicsContext.restoreGraphicsState()
    }
    drawingAppearance.performAsCurrentDrawingAppearance {
      let surface = options.currentAppearance ? NSColor.textBackgroundColor : NSColor.white
      surface.setFill()
      NSBezierPath(rect: NSRect(origin: .zero, size: options.paperSize)).fill()
      let range = manager.glyphRange(for: containers[page])
      let point = NSPoint(x: options.margin, y: options.margin)
      let characters = manager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
      if characters.location > 0, characters.location < storage.length,
        let heading = storage.attribute(
          .markupTableColumn, at: characters.location, effectiveRange: nil) as? String,
        storage.attribute(.markupTableColumn, at: characters.location - 1, effectiveRange: nil)
          as? String == heading
      {
        NSAttributedString(
          string: heading,
          attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            Self.shapingLanguage: "und",
          ]
        ).draw(at: NSPoint(x: options.margin, y: max(2, options.margin - 16)))
      }
      manager.drawBackground(forGlyphRange: range, at: point)
      // AppKit authors its own PDF structure for native text/images. Adding legacy marked
      // content here conflicts with newer system tagging and can hide real text from extraction.
      manager.drawGlyphs(forGlyphRange: range, at: point)
    }
  }

  private struct PageLink {
    var rect: CGRect
    var url: URL?
    var destination: String?
  }
  private var pageLinks: [Int: [PageLink]] = [:]
  private var pageDestinations: [Int: [(String, CGPoint)]] = [:]
  private var outlineEntries: [[String: Any]] = []

  private func prepareNavigation(progress: (PDFExportProgress) -> Void) async throws {
    let entire = NSRange(location: 0, length: storage.length)
    var anchors: [(String, NSRange)] = []
    var links: [(String, NSRange)] = []
    storage.enumerateAttribute(.markupAnchor, in: entire) { value, range, _ in
      if let value = value as? String, range.length > 0 { anchors.append((value, range)) }
    }
    storage.enumerateAttribute(Self.exportLink, in: entire) { value, range, _ in
      if let value = value as? String, range.length > 0 { links.append((value, range)) }
    }
    let names = Set(anchors.map { $0.0 })
    for (index, entry) in anchors.enumerated() {
      if index % 128 == 0 { try await PDFExporter.checkpoint() }
      guard let location = location(for: entry.1) else { continue }
      pageDestinations[location.page, default: []].append((entry.0, location.point))
      let label = (storage.string as NSString).substring(with: entry.1).trimmingCharacters(
        in: .whitespacesAndNewlines)
      let rect = CGRect(x: location.point.x, y: location.point.y, width: 1, height: 1)
      outlineEntries.append([
        kCGPDFOutlineTitle as String: label,
        kCGPDFOutlineDestination as String: location.page + 1,
        kCGPDFOutlineDestinationRect as String: rect.dictionaryRepresentation,
      ])
    }
    for (linkIndex, entry) in links.enumerated() {
      try await PDFExporter.checkpoint()
      let raw = entry.0
      guard raw.utf8.count <= 8192 else { continue }
      var url: URL?
      var destination: String?
      if raw.hasPrefix("#") {
        let name = String(raw.dropFirst()).removingPercentEncoding ?? String(raw.dropFirst())
        guard names.contains(name) else { continue }
        destination = name
      } else {
        guard let value = URL(string: raw),
          ["http", "https"].contains(value.scheme?.lowercased() ?? ""), value.host != nil
        else { continue }
        url = value
      }
      let glyphs = manager.glyphRange(forCharacterRange: entry.1, actualCharacterRange: nil)
      guard glyphs.length > 0,
        let firstContainer = manager.textContainer(
          forGlyphAt: glyphs.location, effectiveRange: nil),
        let lastContainer = manager.textContainer(
          forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil),
        let first = containers.firstIndex(where: { $0 === firstContainer }),
        let last = containers.firstIndex(where: { $0 === lastContainer })
      else { continue }
      for index in first...last {
        try await PDFExporter.checkpoint()
        let container = containers[index]
        let intersection = NSIntersectionRange(glyphs, manager.glyphRange(for: container))
        guard intersection.length > 0 else { continue }
        manager.enumerateEnclosingRects(
          forGlyphRange: intersection,
          withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
        ) { [self] rect, _ in
          let bounds = CGRect(
            x: rect.minX + options.margin,
            y: options.paperSize.height - options.margin - rect.maxY,
            width: rect.width, height: rect.height)
          pageLinks[index, default: []].append(
            PageLink(rect: bounds, url: url, destination: destination))
        }
      }
      progress(PDFExportProgress(stage: .navigation, completed: linkIndex + 1, total: links.count))
    }

  }

  func outline() -> CFDictionary {
    [kCGPDFOutlineChildren as String: outlineEntries] as CFDictionary
  }

  func addNavigation(page: Int, context: CGContext) async throws {
    for (index, destination) in (pageDestinations[page] ?? []).enumerated() {
      if index % 128 == 0 { try await PDFExporter.checkpoint() }
      context.addDestination(destination.0 as CFString, at: destination.1)
    }
    for (index, link) in (pageLinks[page] ?? []).enumerated() {
      if index % 128 == 0 { try await PDFExporter.checkpoint() }
      if let url = link.url { context.setURL(url as CFURL, for: link.rect) }
      if let destination = link.destination {
        context.setDestination(destination as CFString, for: link.rect)
      }
    }
  }

  private func location(for range: NSRange) -> (page: Int, point: NSPoint)? {
    guard range.location < storage.length else { return nil }
    let glyph = manager.glyphIndexForCharacter(at: range.location)
    var effective = NSRange()
    guard let container = manager.textContainer(forGlyphAt: glyph, effectiveRange: &effective),
      let page = containers.firstIndex(where: { $0 === container })
    else { return nil }
    let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    return (
      page, NSPoint(x: options.margin, y: options.paperSize.height - options.margin - rect.minY)
    )
  }
}

@MainActor
private final class PrintableTextView: NSView {
  let layout: PaginatedText
  override var isFlipped: Bool { true }
  init(layout: PaginatedText) {
    self.layout = layout
    super.init(
      frame: NSRect(
        x: 0, y: 0, width: layout.options.paperSize.width,
        height: layout.options.paperSize.height * Double(layout.containers.count)))
  }
  required init?(coder: NSCoder) { nil }
  override func knowsPageRange(_ range: NSRangePointer) -> Bool {
    range.pointee = NSRange(location: 1, length: layout.containers.count)
    return true
  }
  override func rectForPage(_ page: Int) -> NSRect {
    NSRect(
      x: 0, y: Double(page - 1) * layout.options.paperSize.height,
      width: layout.options.paperSize.width, height: layout.options.paperSize.height)
  }
  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    for index in layout.containers.indices where rectForPage(index + 1).intersects(dirtyRect) {
      context.saveGState()
      context.translateBy(x: 0, y: Double(index) * layout.options.paperSize.height)
      layout.draw(page: index, context: context)
      context.restoreGState()
    }
  }
}
