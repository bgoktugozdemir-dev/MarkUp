import AppKit
import Foundation
import MarkUpCore
import Testing

@testable import MarkUp

@MainActor
struct SessionTests {
  @Test(arguments: [false, true])
  func noOpDecorationsDoNotReplaceReadableDocument(blockedImage: Bool) async throws {
    let source =
      "# Stable document\n\nReadable words remain selectable.\n"
      + (blockedImage ? "\n![Accessible missing image](not-granted.png)\n" : "")
    let session = ReaderSession(
      url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md"),
      source: source)
    defer { session.close() }
    session.document = try await MarkdownParser().parse(source)
    session.render()
    let original = try #require(session.rendered?.attributedString)
    let revision = session.renderedRevision
    try await Task.sleep(for: .milliseconds(150))
    #expect(session.rendered?.attributedString === original)
    #expect(session.renderedRevision == revision)
    #expect(session.source == source)
    if blockedImage {
      #expect(original.string.contains("[Accessible missing image]"))
      #expect(
        session.status
          == localized("Some images need access or are missing, unsupported, or too large."))
    }
  }

  @Test(arguments: [false, true])
  func annotationResolutionPublishesOnlyChangesAndClearRemovesMarks(resolvable: Bool) async throws {
    let source = "A stable introduction before selected words and a distinctive ending after them."
    let session = ReaderSession(url: nil, source: source)
    defer { session.close() }
    session.document = try await MarkdownParser().parse(source)
    session.render()
    let canonical = try #require(session.rendered?.attributedString.string)
    let anchoredText =
      resolvable
      ? canonical
      : "An entirely different document with absent words and stable surrounding context."
    let range = (anchoredText as NSString).range(of: resolvable ? "selected words" : "absent words")
    let mark = TextAnnotation(
      documentID: UUID(), anchor: try TextAnchor.capture(in: anchoredText, range: range),
      style: .highlightYellow)
    session.annotations = [mark]
    session.render()
    let deadline = ContinuousClock.now + .seconds(3)
    while session.resolvedAnnotations.isEmpty && session.unresolved.isEmpty,
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(resolvable ? session.resolvedAnnotations[mark.id] != nil : session.unresolved == [mark])
    session.render()
    let revision = session.renderedRevision
    try await Task.sleep(for: .milliseconds(150))
    #expect(session.renderedRevision == revision)
    session.annotations = []
    session.render()
    #expect(session.resolvedAnnotations.isEmpty)
    #expect(session.unresolved.isEmpty)
    #expect(session.renderedRevision > revision)
    #expect(session.rendered?.attributedString.string == canonical)
  }

  @Test func rapidReloadPublishesOnlyLatestSourceAndCloseStopsWork() async throws {
    let session = ReaderSession(
      url: nil, source: String(repeating: "# Old\n\nOld paragraph.\n\n", count: 2000))
    session.start()
    session.source = "# Latest\n\nOnly the final content belongs here."
    session.reload()
    let deadline = ContinuousClock.now + .seconds(8)
    while session.loading, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(session.rendered?.attributedString.string.contains("Latest") == true)
    #expect(session.rendered?.attributedString.string.contains("Old paragraph") == false)
    session.source = String(repeating: "# Obsolete\n\nNever publish after close.\n\n", count: 2000)
    session.reload()
    session.close()
    let revision = session.renderedRevision
    try await Task.sleep(for: .milliseconds(300))
    #expect(session.renderedRevision == revision)
  }

  @Test func searchUsesNativeUTF16RangesWithoutChangingSource() async throws {
    let source = "# Türkçe 😀\n\nCafé and cafe and CAFÉ.\n\n```swift\nlet untouched = 1\n```"
    let session = ReaderSession(url: nil, source: source)
    session.start()
    defer { session.close() }
    let deadline = ContinuousClock.now + .seconds(5)
    while session.loading, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    session.search = "cafe"
    session.find()
    #expect(session.matches.count == 3)
    let text = try #require(session.rendered?.attributedString.string as NSString?)
    #expect(session.matches.map { text.substring(with: $0) } == ["Café", "cafe", "CAFÉ"])
    session.nextMatch(-1)
    #expect(session.matchIndex == 2)
    #expect(session.source == source)
  }

  @Test func imageLoadingRequiresExplicitRootAndDoesNotReadTraversal() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let image = NSImage(size: NSSize(width: 40, height: 20))
    image.lockFocus()
    NSColor.blue.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 40, height: 20)).fill()
    image.unlockFocus()
    try #require(image.tiffRepresentation).write(to: base.appendingPathComponent("sample.tiff"))
    let document = base.appendingPathComponent("readme.md")
    let loader = ImageLoader()
    do {
      _ = try await loader.load("sample.tiff", document: document, roots: [], remoteAllowed: false)
      Issue.record("An ungranted sibling image must not load")
    } catch {}
    let loaded = try await loader.load(
      "sample.tiff", document: document, roots: [base], remoteAllowed: false)
    let decoded = try #require(NSImage(data: loaded))
    #expect(abs(decoded.size.width / decoded.size.height - 2) < 0.01)
    do {
      _ = try await loader.load(
        "../outside.tiff", document: document, roots: [base], remoteAllowed: false)
      Issue.record("Traversal must not read outside a granted root")
    } catch {}
    await loader.close()
  }
}
