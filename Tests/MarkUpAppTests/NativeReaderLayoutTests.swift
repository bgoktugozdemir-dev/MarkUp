import AppKit
import MarkUpCore
import SwiftUI
import Testing

@testable import MarkUp

@MainActor
struct NativeReaderLayoutTests {
  @Test func retainedNativeReaderCanRestartAfterItsWindowCloses() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("reader.md")
    let source = "# Restarted reader\n\n" + String(repeating: "A stable paragraph.\n\n", count: 300)
    try Data(source.utf8).write(to: url)
    defer {
      UserDefaults.standard.removeObject(forKey: "position:\(url.path)")
      try? FileManager.default.removeItem(at: directory)
    }
    let store = try AnnotationStore(directory: directory.appendingPathComponent("annotations"))
    let fixture = try await ReadingWindowFixture(source: source, url: url, width: 640, store: store)
    try await fixture.waitUntil { fixture.session.viewport.height > 0 }
    let scroll = try #require(fixture.text?.enclosingScrollView)
    weak var originalText = fixture.text
    fixture.window.close()
    try await fixture.waitUntil { fixture.session.isClosed && originalText == nil }
    #expect(scroll.documentView == nil)
    fixture.window.makeKeyAndOrderFront(nil)
    fixture.session.start()  // Mirrors the reader's onAppear on a retained native representable.
    try await fixture.waitUntil { fixture.session.textView != nil && !fixture.session.loading }
    #expect(fixture.session.textView?.enclosingScrollView === scroll)
    #expect(fixture.session.textView?.string.contains("Restarted reader") == true)
    #expect((fixture.session.textView as? ReaderTextView)?.codeControls != nil)
    #expect(!fixture.session.isClosed)
    // Keep an obsolete representable alive across removal/recreation, as a tab transition can.
    let obsolete = try #require(fixture.session.textView?.delegate as? NativeReader.Coordinator)
    let host = try #require(fixture.window.contentView as? NSHostingView<ViewportReaderHost>)
    host.rootView = ViewportReaderHost(session: fixture.session, showsReader: false)
    try await fixture.waitUntil { fixture.session.isClosed }
    host.rootView = ViewportReaderHost(session: fixture.session)
    fixture.session.start()
    try await fixture.waitUntil { fixture.session.textView != nil && !fixture.session.loading }
    let currentWidth = try #require(fixture.session.textView?.textContainer?.size.width)
    obsolete.preferredContentWidth = 180
    scroll.setFrameSize(NSSize(width: 300, height: 200))
    obsolete.updateGeometry()
    #expect(fixture.session.textView?.textContainer?.size.width == currentWidth)
    #expect(fixture.session.textView?.enclosingScrollView !== scroll)
    fixture.window.close()
    #expect(fixture.session.isClosed)
  }

  @Test(arguments: [false, true])
  func nativeWindowCloseSavesPositionAndReleasesTextGraph(code: Bool) async throws {
    let lines = (0..<1800).map { "Reading line \($0) has stable content." }.joined(
      separator: code ? "\n" : "\n\n")
    let source = code ? "```text\n\(lines)\nDOCUMENT-END\n```" : "\(lines)\n\nDOCUMENT-END"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("reading-\(UUID()).md")
    let key = "position:\(url.path)"
    defer { UserDefaults.standard.removeObject(forKey: key) }
    // Keep closed windows alive deliberately, as NSDocument/SwiftUI may do. The native text
    // graph and session snapshots must still be released by the actual willClose boundary.
    var retainedWindows: [ReadingWindowFixture] = []
    var preferences = ReaderPreferences()
    // Position restoration deep inside one long fence needs the fully expanded block.
    preferences.limitCodeHeight = !code
    for cycle in 0..<3 {
      let fixture = try await ReadingWindowFixture(
        source: source, url: url, width: cycle == 0 ? 640 : 820, preferences: preferences)
      retainedWindows.append(fixture)
      try await fixture.waitUntil {
        fixture.session.viewport.height > 0 && (fixture.text?.textContainer?.size.width ?? 0) > 500
      }
      if cycle == 0 {
        fixture.scrollToEnd()
        try await fixture.waitUntil { fixture.session.viewport.minY > 1000 }
        #expect(UserDefaults.standard.object(forKey: key) == nil)
      } else {
        try await fixture.waitUntil {
          fixture.session.viewport.minY
            > (fixture.session.documentHeight - fixture.session.viewport.height) * 0.9
        }
        let restoredEndIsVisible = fixture.endIsVisible()
        #expect(restoredEndIsVisible)
      }
      fixture.window.close()  // No explicit session.close(): exercise the production window hook.
      try await fixture.waitUntil { fixture.session.isClosed && fixture.text == nil }
      #expect(fixture.session.rendered == nil && fixture.session.document == nil)
      #expect(fixture.session.source.isEmpty)
      #expect(fixture.session.minimap.cachedBytes == 0 && fixture.session.minimap.source == nil)
      #expect(fixture.session.tokens.isEmpty)
      let stored = try #require(UserDefaults.standard.dictionary(forKey: key))
      #expect(stored["block"] as? String != nil)
      if code { #expect((stored["offset"] as? Int ?? 0) > 1000) }
    }
    #expect(retainedWindows.count == 3)
  }

  @Test func annotationOnlyRefreshPreservesExactReadingViewport() async throws {
    let source = (0..<250).map { "Paragraph \($0) with stable selectable reading content.\n\n" }
      .joined()
    let document = try await MarkdownParser().parse(source)
    let rendered = NativeMarkdownRenderer().render(
      document: document, preferences: ReaderPreferences(), tokens: [:])
    let session = ReaderSession(url: nil, source: source)
    session.document = document
    session.rendered = rendered
    session.renderedRevision = 1
    let host = NSHostingView(rootView: ViewportReaderHost(session: session))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer {
      window.close()
      session.close()
    }
    for _ in 0..<100 {
      host.layoutSubtreeIfNeeded()
      if let text = session.textView, let scroll = text.enclosingScrollView,
        scroll.contentSize.width > 500,
        abs((text.textContainer?.size.width ?? 0) - (scroll.contentSize.width - 64)) < 0.5
      {
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    let text = try #require(session.textView)
    let scroll = try #require(text.enclosingScrollView)
    #expect(scroll.contentSize.width > 500)
    #expect((text.textContainer?.size.width ?? 0) > 500)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 1234))
    scroll.reflectScrolledClipView(scroll.contentView)
    let originalOrigin = scroll.contentView.bounds.origin
    #expect(originalOrigin.y > 1000)
    let range = (rendered.attributedString.string as NSString).range(of: "Paragraph 60")
    let annotation = TextAnnotation(
      documentID: UUID(),
      anchor: try TextAnchor.capture(in: rendered.attributedString.string, range: range),
      style: .highlightYellow)
    session.annotations = [annotation]
    session.resolvedAnnotations = [annotation.id: range]
    session.renderedRevision += 1
    host.rootView = ViewportReaderHost(session: session)
    for _ in 0..<100 {
      host.layoutSubtreeIfNeeded()
      if text.textStorage?.attribute(.backgroundColor, at: range.location, effectiveRange: nil)
        != nil
      {
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.textView === text)
    #expect(
      text.textStorage?.attribute(.backgroundColor, at: range.location, effectiveRange: nil) != nil)
    #expect(scroll.contentView.bounds.origin == originalOrigin)
  }

  @Test func imagePreviewRequiresTheActualAttachmentGlyph() throws {
    let text = ReaderTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let image = NSImage(size: NSSize(width: 80, height: 60))
    let attachment = NSTextAttachment()
    attachment.image = image
    let content = NSMutableAttributedString(string: "\u{FFFC} ordinary selectable words")
    content.addAttributes(
      [
        .attachment: attachment, .markupImageSource: "local.png",
        .markupImageAlt: "Accessible image",
      ], range: NSRange(location: 0, length: 1))
    text.textStorage?.setAttributedString(content)
    text.fitDocument()
    let layout = try #require(text.layoutManager)
    let container = try #require(text.textContainer)
    let imageRect = layout.boundingRect(
      forGlyphRange: NSRange(location: 0, length: 1), in: container
    )
    .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
    let preview = try #require(
      text.previewableImage(at: NSPoint(x: imageRect.midX, y: imageRect.midY)))
    #expect(preview.image === image)
    #expect(preview.alt == "Accessible image")
    #expect(text.previewableImage(at: NSPoint(x: imageRect.maxX + 100, y: imageRect.midY)) == nil)
    #expect(text.previewableImage(at: NSPoint(x: imageRect.midX, y: imageRect.maxY + 100)) == nil)
  }

  @Test func longDocumentGrowsBeyondViewportAndScrollsToItsEnd() async throws {
    let source =
      "# Long native document\n\n"
      + String(repeating: "A paragraph with native text and a stable layout.\n\n", count: 2500)
      + "DOCUMENT-END"
    let document = try await MarkdownParser().parse(source)
    let rendered = NativeMarkdownRenderer().render(
      document: document, preferences: ReaderPreferences(), tokens: [:])
    let storage = NSTextStorage(attributedString: rendered.attributedString)
    let layout = CodeLayoutManager()
    layout.backgroundLayoutEnabled = false
    storage.addLayoutManager(layout)
    let container = CodeTextContainer(
      size: NSSize(width: 360, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = false
    container.lineFragmentPadding = 0
    layout.addTextContainer(container)
    // Match production: the initially zero-sized text view becomes the scroll document view.
    let text = ReaderTextView(frame: .zero, textContainer: container)
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.textContainerInset = NSSize(width: 32, height: 60)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 424, height: 600))
    scroll.hasVerticalScroller = true
    scroll.documentView = text
    text.frame.size.width = scroll.contentSize.width
    text.fitDocument()
    #expect(text.frame.height > scroll.contentSize.height * 20)
    #expect(
      text.frame.height >= layout.usedRect(for: container).maxY + 2 * text.textContainerInset.height
    )
    let end = (text.string as NSString).range(of: "DOCUMENT-END")
    text.scrollRangeToVisible(end)
    #expect(text.visibleRect.minY > 1000)
    let endGlyphs = layout.glyphRange(forCharacterRange: end, actualCharacterRange: nil)
    let endRect = layout.boundingRect(forGlyphRange: endGlyphs, in: container)
      .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
    #expect(text.visibleRect.intersects(endRect))
  }
}

@MainActor
private final class ReadingWindowFixture {
  let window: NSWindow
  let session: ReaderSession
  weak var text: NSTextView?

  init(
    source: String, url: URL, width: CGFloat, store: AnnotationStore? = nil,
    preferences: ReaderPreferences = ReaderPreferences()
  ) async throws {
    session = ReaderSession(url: url, source: source, annotationStore: store)
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.titled],
      backing: .buffered, defer: false)
    let document = try await MarkdownParser().parse(source)
    session.document = document
    session.rendered = NativeMarkdownRenderer().render(
      document: document, preferences: preferences, tokens: [:])
    session.renderedRevision = 1
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: ViewportReaderHost(session: session, preferences: preferences))
    window.makeKeyAndOrderFront(nil)
    try await waitUntil { self.session.textView?.window === self.window }
    text = session.textView
    // User interaction follows the deferred native mounting/restoration turn.
    try await waitUntil {
      (self.text?.delegate as? NativeReader.Coordinator)?.hasRestored == true
    }
    if let text { #expect(window.makeFirstResponder(text)) }
  }

  func scrollToEnd() {
    guard let text, let scroll = text.enclosingScrollView else { return }
    scroll.contentView.scroll(
      to: NSPoint(x: 0, y: max(0, text.frame.height - scroll.contentSize.height)))
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  func endIsVisible() -> Bool {
    guard let text, let layout = text.layoutManager, let container = text.textContainer else {
      return false
    }
    let characters = (text.string as NSString).range(of: "DOCUMENT-END")
    let glyphs = layout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
    let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
      .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
    return text.visibleRect.intersects(rect)
  }

  func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(predicate(), "Mounted reading window did not reach the expected lifecycle state")
  }
}

private struct ViewportReaderHost: View {
  let session: ReaderSession
  var preferences = ReaderPreferences()
  var showsReader = true
  var body: some View {
    let _ = session.renderedRevision
    if showsReader {
      NativeReader(session: session, preferences: preferences)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      Color.clear
    }
  }
}
