import AppKit
import MarkUpCore
import SwiftUI

@MainActor final class ReaderScrollView: NSScrollView {
  var viewportDidResize: (() -> Void)?
  var windowDidChange: ((NSWindow?) -> Void)?
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    windowDidChange?(window)
    // SwiftUI can attach the native view after its first update. Reconcile once its
    // mounted frame has been assigned; ordinary subsequent resize callbacks stay synchronous.
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, window != nil else { return }
      viewportDidResize?()
    }
  }
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    viewportDidResize?()
  }
  override func tile() {
    super.tile()
    viewportDidResize?()
  }
}

struct NativeReader: NSViewRepresentable {
  let session: ReaderSession
  let preferences: ReaderPreferences

  func makeCoordinator() -> Coordinator { Coordinator(session: session) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = ReaderScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    installTextView(in: scroll, coordinator: context.coordinator)
    scroll.contentView.postsBoundsChangedNotifications = true
    context.coordinator.observer = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
    ) { [weak coordinator = context.coordinator] _ in
      MainActor.assumeIsolated { coordinator?.updateGeometry() }
    }
    scroll.windowDidChange = { [weak coordinator = context.coordinator] window in
      coordinator?.bindWindow(window)
    }
    scroll.viewportDidResize = { [weak coordinator = context.coordinator] in
      coordinator?.updateGeometry()
    }
    return scroll
  }

  /// A retained SwiftUI representable may reappear after its session restarts. Recreate the
  /// released native text graph in that same scroll view instead of leaving it permanently blank.
  @discardableResult
  private func installTextView(in scroll: NSScrollView, coordinator: Coordinator) -> ReaderTextView
  {
    let storage = NSTextStorage()
    let layout = CodeLayoutManager()
    layout.backgroundLayoutEnabled = false
    let container = CodeTextContainer(
      size: NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    let text = ReaderTextView(frame: .zero, textContainer: container)
    text.codeControls = CodeBlockController(textView: text)
    container.codeControls = text.codeControls
    layout.codeControls = text.codeControls
    text.session = session
    text.isEditable = false
    text.isSelectable = true
    text.isRichText = true
    text.allowsUndo = true
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.autoresizingMask = [.width]
    text.textContainerInset = NSSize(width: 32, height: 60)
    text.textContainer?.widthTracksTextView = false
    text.textContainer?.lineFragmentPadding = 0
    text.setAccessibilityLabel(localized("Markdown document"))
    text.delegate = coordinator
    scroll.documentView = text
    session.textView = text
    coordinator.attachTextView(text)
    coordinator.bindWindow(scroll.window)
    text.geometryChanged = { [weak coordinator] in
      coordinator?.updateGeometry()
    }
    return text
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard !session.isClosed, let rendered = session.rendered,
      !context.coordinator.wasClosed || scroll.window?.isVisible == true
    else { return }
    let text: ReaderTextView
    if let existing = scroll.documentView as? ReaderTextView {
      guard session.textView === existing else { return }
      text = existing
    } else {
      guard session.textView == nil else { return }
      text = installTextView(in: scroll, coordinator: context.coordinator)
    }
    let undoManager = text.undoManager
    undoManager?.disableUndoRegistration()
    defer { undoManager?.enableUndoRegistration() }
    text.setAccessibilityLabel(localized("Markdown document"))
    let originalViewport = scroll.contentView.bounds.origin
    context.coordinator.preferredContentWidth = preferences.contentWidth
    let originalContainerWidth = text.textContainer?.size.width ?? 0
    let originalVisibleCharacter = context.coordinator.visibleCharacter()
    text.frame.size.width = scroll.contentSize.width
    let width = max(180, min(preferences.contentWidth, scroll.contentSize.width - 64))
    let widthChanged = abs(originalContainerWidth - width) > 0.5
    text.textContainerInset.width = max(20, (scroll.contentSize.width - width) / 2)
    text.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    if widthChanged { text.codeControls?.containerDidResize() }
    let coordinator = context.coordinator
    let unchangedLayout =
      coordinator.attributedSource === rendered.attributedString && !widthChanged
    guard coordinator.revision != session.renderedRevision else {
      if widthChanged {
        text.fitDocument()
        text.frame.size.width = scroll.contentSize.width
        if originalVisibleCharacter < text.string.utf16.count {
          text.scrollRangeToVisible(NSRange(location: originalVisibleCharacter, length: 0))
        }
      }
      text.codeControls?.updateFrames()
      coordinator.updateGeometry()
      return
    }
    let oldSelection = text.selectedRange()
    let oldText = text.string
    let firstVisible = originalVisibleCharacter
    let oldBlock = coordinator.blocks.semanticReadingBlock(at: firstVisible)
    let offset = oldBlock.map { firstVisible - $0.range.location } ?? 0
    coordinator.revision = session.renderedRevision
    coordinator.attributedSource = rendered.attributedString
    coordinator.blocks = rendered.blocks
    let display = NSMutableAttributedString(attributedString: rendered.attributedString)
    for annotation in session.annotations {
      if let range = session.resolvedAnnotations[annotation.id], NSMaxRange(range) <= display.length
      {
        if annotation.style == .underline {
          display.addAttribute(
            .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        } else {
          let color: NSColor =
            switch annotation.style {
            case .highlightGreen: .systemGreen
            case .highlightBlue: .systemBlue
            default: .systemYellow
            }
          display.addAttribute(
            .backgroundColor, value: color.withAlphaComponent(0.32), range: range)
          display.addAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue,
            range: range)
        }
      }
    }
    text.codeControls?.prepare(
      display, rendered: rendered, document: session.document, preferences: preferences)
    let contentChanged = oldText != display.string
    if contentChanged { coordinator.selectionRestorer.cancel() }
    coordinator.isUpdatingContent = true
    text.textStorage?.setAttributedString(display)
    text.fitDocument()
    text.frame.size.width = scroll.contentSize.width
    if !contentChanged, NSMaxRange(oldSelection) <= display.length {
      text.setSelectedRange(oldSelection)
    } else {
      text.setSelectedRange(NSRange(location: 0, length: 0))
    }
    coordinator.isUpdatingContent = false
    if contentChanged {
      coordinator.selectionRestorer.restore(oldSelection, from: oldText, in: text) {
        [weak session] in
        session?.isClosed == false
      }
    }
    if unchangedLayout {
      scroll.contentView.scroll(to: originalViewport)
      scroll.reflectScrolledClipView(scroll.contentView)
    } else if let oldBlock, let newBlock = rendered.blocks.first(where: { $0.id == oldBlock.id }) {
      text.scrollRangeToVisible(
        NSRange(
          location: min(NSMaxRange(newBlock.range), newBlock.range.location + offset), length: 0))
    }
    coordinator.updateGeometry()
    text.codeControls?.updateFrames()
    PerformanceTrace.readyWhenMounted(
      ObjectIdentifier(session), text: text, contentWidth: preferences.contentWidth)
  }

  static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
    coordinator.closeReader()
    if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    coordinator.selectionRestorer.cancel()
    (nsView.documentView as? ReaderTextView)?.imagePreviewController?.close()
  }

  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    let session: ReaderSession
    var observer: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private weak var observedWindow: NSWindow?
    weak var ownedTextView: ReaderTextView?
    var revision = -1
    var hasRestored = false
    var wasClosed = false
    var blocks: [RenderedBlock] = []
    weak var attributedSource: NSAttributedString?
    var preferredContentWidth: CGFloat = 860
    private var synchronizingWidth = false
    private var initialRestore: Task<Void, Never>?
    private var restoreGeneration = 0
    let selectionRestorer = ReaderSelectionRestorer()
    var isUpdatingContent = false
    init(session: ReaderSession) { self.session = session }
    func attachTextView(_ text: ReaderTextView) {
      cancelInitialRestore()
      ownedTextView = text
      revision = -1
      hasRestored = false
      wasClosed = false
    }
    func bindWindow(_ window: NSWindow?) {
      guard window !== observedWindow else { return }
      if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
      closeObserver = nil
      observedWindow = window
      guard let window else { return }
      closeObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.closeReader() }
      }
    }
    func closeReader() {
      cancelInitialRestore()
      wasClosed = true
      selectionRestorer.cancel()
      // A delayed dismantle from an old representable must not close a restarted session
      // which already owns a different native view.
      if let ownedTextView, session.textView === ownedTextView {
        session.close()
      } else {
        ownedTextView?.releaseDocumentResources()
      }
      blocks = []
      attributedSource = nil
      bindWindow(nil)
    }
    func textViewDidChangeSelection(_ notification: Notification) {
      if let view = notification.object as? NSTextView {
        if !isUpdatingContent { selectionRestorer.cancel() }
        let previous = session.selection
        session.selection = view.selectedRange()
        (view as? ReaderTextView)?.codeControls?.revealSelection(
          session.selection, previous: previous)
      }
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
      session.openLink((link as? URL)?.absoluteString ?? (link as? String ?? ""))
      return true
    }
    func visibleCharacter() -> Int {
      guard let text = ownedTextView, session.textView === text, let layout = text.layoutManager,
        let container = text.textContainer
      else { return 0 }
      let glyph = layout.glyphIndex(
        for: CGPoint(x: 0, y: max(0, text.visibleRect.minY - text.textContainerOrigin.y)),
        in: container)
      return glyph < layout.numberOfGlyphs ? layout.characterIndexForGlyph(at: glyph) : 0
    }
    func updateGeometry() {
      // AppKit tiles the scroll view during text replacement and fitting. The completed
      // updateNSView pass publishes geometry once; intermediate scans repeat full block work.
      guard !session.isClosed, !isUpdatingContent, !synchronizingWidth,
        let text = ownedTextView, session.textView === text
      else { return }
      synchronizeContainerWidth()
      scheduleInitialRestore(in: text)
      if hasRestored, text.window?.isVisible == true {
        session.captureReadingLocation(character: visibleCharacter(), blocks: blocks)
      }
      (text as? ReaderTextView)?.codeControls?.updateFrames()
      session.viewport = text.visibleRect
      session.documentHeight = max(1, text.bounds.height)
      session.minimap.update(
        source: text, revision: revision, enabled: AppSettings.shared.value.showMinimap)
    }

    private func cancelInitialRestore() {
      restoreGeneration += 1
      initialRestore?.cancel()
      initialRestore = nil
    }

    private func canRestore(in text: ReaderTextView) -> Bool {
      guard !session.isClosed, !isUpdatingContent, !synchronizingWidth, revision >= 0,
        ownedTextView === text, session.textView === text, text.window?.isVisible == true,
        let scroll = text.enclosingScrollView, scroll.contentSize.width > 0,
        scroll.contentSize.height > 0, let container = text.textContainer
      else { return false }
      let width = max(180, min(preferredContentWidth, scroll.contentSize.width - 64))
      return abs(container.size.width - width) < 0.5
    }

    private func scheduleInitialRestore(in text: ReaderTextView) {
      guard !hasRestored, initialRestore == nil, canRestore(in: text) else { return }
      let expected = restoreGeneration
      initialRestore = Task { @MainActor [weak self, weak text] in
        // Native mounting may reset clip bounds after its synchronous geometry callback.
        // Restore only after that stack unwinds; no timer or repeated defaults writes.
        await Task.yield()
        guard !Task.isCancelled, let self, expected == restoreGeneration else { return }
        initialRestore = nil
        guard let text, canRestore(in: text), !hasRestored else { return }
        hasRestored = true
        session.restorePosition()
        updateGeometry()
      }
    }

    /// SwiftUI can assign the final NSScrollView frame after updateNSView. Clip-bounds
    /// notifications also cover first mount and ordinary window resizes without state changes.
    private func synchronizeContainerWidth() {
      guard let text = ownedTextView, session.textView === text,
        let scroll = text.enclosingScrollView, let container = text.textContainer,
        scroll.contentSize.width > 0
      else { return }
      let width = max(180, min(preferredContentWidth, scroll.contentSize.width - 64))
      let inset = max(20, (scroll.contentSize.width - width) / 2)
      let widthChanged = abs(container.size.width - width) > 0.5
      guard widthChanged || abs(text.textContainerInset.width - inset) > 0.5 else { return }
      synchronizingWidth = true
      let undo = text.undoManager
      undo?.disableUndoRegistration()
      defer {
        undo?.enableUndoRegistration()
        synchronizingWidth = false
      }
      let firstVisible = visibleCharacter()
      text.textContainerInset.width = inset
      container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
      if widthChanged { text.codeControls?.containerDidResize() }
      text.fitDocument()
      text.frame.size.width = scroll.contentSize.width
      if widthChanged, firstVisible < text.string.utf16.count {
        text.scrollRangeToVisible(NSRange(location: firstVisible, length: 0))
      }
    }
  }
}

extension Array where Element == RenderedBlock {
  /// Renderer traversal is postorder, so array.last can select a large enclosing quote/list.
  /// Reading restoration uses the nearest actual text block, independent of traversal order.
  func semanticReadingBlock(at character: Int) -> RenderedBlock? {
    let structural: Set<MarkdownBlockKind> = [.quote, .alert, .list, .listItem]
    return filter {
      !structural.contains($0.kind) && $0.range.length > 0 && $0.range.location <= character
    }
    .max { left, right in
      if left.range.location == right.range.location {
        return left.range.length > right.range.length
      }
      return left.range.location < right.range.location
    }
  }
}

@MainActor final class ReaderTextView: NSTextView {
  weak var session: ReaderSession?
  var codeControls: CodeBlockController?
  var geometryChanged: (() -> Void)?
  var imagePreviewController: ImagePreviewController?
  // NSLayoutManager paints selection backgrounds separately from temporary attributes.
  // During a synchronous minimap draw, project an empty selection to its public queries;
  // the real stored selection, setters, notifications and undo history stay untouched.
  override var selectedRanges: [NSValue] {
    get {
      if codeControls?.minimapSourceRect != nil {
        return [NSValue(range: NSRange(location: 0, length: 0))]
      }
      return super.selectedRanges
    }
    set { super.selectedRanges = newValue }
  }
  override func selectedRange() -> NSRange {
    if codeControls?.minimapSourceRect != nil { return NSRange(location: 0, length: 0) }
    return super.selectedRange()
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    geometryChanged?()
  }
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    geometryChanged?()
  }
  func releaseDocumentResources() {
    if let responder = window?.firstResponder as? NSView,
      responder === self || responder.isDescendant(of: self)
    {
      window?.makeFirstResponder(nil)
    }
    imagePreviewController?.close()
    imagePreviewController = nil
    geometryChanged = nil
    delegate = nil
    codeControls = nil
    for view in subviews { view.removeFromSuperview() }
    let undo = undoManager
    undo?.disableUndoRegistration()
    textStorage?.setAttributedString(NSAttributedString(string: ""))
    undo?.enableUndoRegistration()
    // SwiftUI/NSDocument may retain a closed window. Detach its heavy native text graph
    // rather than retaining glyph/layout buffers until that window object is released.
    enclosingScrollView?.documentView = nil
  }
  override var undoManager: UndoManager? { session?.annotationUndoManager }
  // Overflow fragments intentionally have negative x coordinates. NSTextView's automatic
  // origin compensation would cancel their scroll offset and push overlay controls offscreen.
  override var textContainerOrigin: NSPoint {
    NSPoint(x: textContainerInset.width, y: textContainerInset.height)
  }
  override func accessibilityChildren() -> [Any]? {
    let nativeChildren = super.accessibilityChildren() ?? []
    let controls = codeControls?.visibleAccessibilityElements ?? []
    return nativeChildren
      + controls.filter { control in
        !nativeChildren.contains { ($0 as AnyObject) === control }
      }
  }
  /// Attaching an initially zero-sized text view to a scroll view can set maxSize to the
  /// viewport. Reset those limits before fitting, otherwise fully laid-out text stays clipped.
  func fitDocument() {
    minSize = .zero
    maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textContainer?.heightTracksTextView = false
    if let layoutManager, let textContainer { layoutManager.ensureLayout(for: textContainer) }
    sizeToFit()
  }
  func previewableImage(at point: NSPoint) -> (image: NSImage, alt: String)? {
    guard let layoutManager, let textContainer, let textStorage else { return nil }
    let location = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
    let glyph = layoutManager.glyphIndex(for: location, in: textContainer)
    guard glyph < layoutManager.numberOfGlyphs,
      layoutManager.boundingRect(
        forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer
      ).contains(location)
    else { return nil }
    let character = layoutManager.characterIndexForGlyph(at: glyph)
    guard character < textStorage.length,
      textStorage.attribute(.markupImageSource, at: character, effectiveRange: nil) != nil,
      let attachment = textStorage.attribute(.attachment, at: character, effectiveRange: nil)
        as? NSTextAttachment,
      let image = attachment.image
    else { return nil }
    return (
      image,
      textStorage.attribute(.markupImageAlt, at: character, effectiveRange: nil) as? String ?? ""
    )
  }
  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2,
      let preview = previewableImage(at: convert(event.locationInWindow, from: nil))
    {
      if imagePreviewController == nil { imagePreviewController = ImagePreviewController() }
      imagePreviewController?.show(image: preview.image, alt: preview.alt)
      return
    }
    super.mouseDown(with: event)
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    codeControls?.drawLineNumbers(in: dirtyRect)
  }
  override func scrollWheel(with event: NSEvent) {
    if codeControls?.scrollWheel(event) == true { return }
    super.scrollWheel(with: event)
  }
  override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
    guard type == .string || type.rawValue == "NSStringPboardType", let storage = textStorage else {
      return super.writeSelection(to: pboard, type: type)
    }
    let range = selectedRange()
    guard range.length > 0, NSMaxRange(range) <= storage.length else { return false }
    let value = NSMutableString(string: (storage.string as NSString).substring(with: range))
    var markers: [Int] = []
    storage.enumerateAttribute(.markupImageSource, in: range) { source, run, _ in
      guard source != nil else { return }
      for index in run.location..<NSMaxRange(run)
      where (storage.string as NSString).character(at: index) == 0xFFFC {
        markers.append(index - range.location)
      }
    }
    for index in markers.reversed() {
      value.deleteCharacters(in: NSRange(location: index, length: 1))
    }
    return pboard.setString(value as String, forType: type)
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = super.menu(for: event) ?? NSMenu()
    guard selectedRange().length > 0 else { return menu }
    menu.addItem(.separator())
    for (title, action) in [
      ("Highlight Yellow", #selector(highlightYellow)),
      ("Highlight Green", #selector(highlightGreen)), ("Highlight Blue", #selector(highlightBlue)),
      ("Underline", #selector(underlineSelection)),
    ] {
      let item = NSMenuItem(title: localized(title), action: action, keyEquivalent: "")
      item.target = self
      menu.addItem(item)
    }
    return menu
  }
  @objc private func highlightYellow() { session?.addAnnotation(.highlightYellow) }
  @objc private func highlightGreen() { session?.addAnnotation(.highlightGreen) }
  @objc private func highlightBlue() { session?.addAnnotation(.highlightBlue) }
  @objc private func underlineSelection() { session?.addAnnotation(.underline) }
}

extension NSColor {
  convenience init(hex: String) {
    let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
    self.init(
      srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
      blue: Double(value & 255) / 255, alpha: 1)
  }
}
