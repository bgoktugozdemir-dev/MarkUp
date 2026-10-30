import AppKit
import Foundation
import MarkUpCore
import PDFKit
import Testing

@testable import MarkUp

@MainActor
struct PDFCancellationTests {
  @Test(arguments: [PDFExportProgress.Stage.paginating, .drawing, .writing])
  func cancellationAfterRealWorkPreservesDestinationAndCleansIntermediates(
    stage: PDFExportProgress.Stage
  ) async throws {
    let source =
      (0..<300).map { index in
        "## Section \(index)\n\n"
          + String(
            repeating: "A real native pagination paragraph with selectable content. ", count: 12)
          + "\n\n"
      }.joined() + "DOCUMENT-END"
    let document = try await MarkdownParser().parse(source)
    let rendered = NativeMarkdownRenderer().render(
      document: document, preferences: ReaderPreferences(), tokens: [:])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("existing.pdf")
    let original = Data("existing owner content must survive cancellation".utf8)
    try original.write(to: destination)
    var reachedStage = false
    var pagesActuallyLaidOut = 0
    var finished = false
    let task = Task {
      defer { finished = true }
      try await PDFExporter().export(rendered: rendered, to: destination, options: PDFOptions()) {
        progress in
        if progress.stage == .paginating {
          pagesActuallyLaidOut = max(pagesActuallyLaidOut, progress.completed)
        }
        if progress.stage == stage { reachedStage = true }
      }
    }
    let deadline = ContinuousClock.now + .seconds(10)
    while !reachedStage, !finished, ContinuousClock.now < deadline { await Task.yield() }
    #expect(reachedStage, "The real export must reach the requested cancellation boundary")
    #expect(pagesActuallyLaidOut > 0, "Cancellation must exercise actual native pagination")
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try Data(contentsOf: destination) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["existing.pdf"])
  }

  @Test func failedAtomicCommitRemovesTemporarySiblingAndKeepsDestination() async throws {
    let document = try await MarkdownParser().parse("# Safe atomic export\n\nSelectable text.")
    let rendered = NativeMarkdownRenderer().render(
      document: document, preferences: ReaderPreferences(), tokens: [:])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("existing-directory", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    try Data("keep me".utf8).write(to: destination.appendingPathComponent("owner-file"))
    await #expect(throws: (any Error).self) {
      try await PDFExporter().export(rendered: rendered, to: destination, options: PDFOptions())
    }
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["existing-directory"])
    #expect(
      try String(contentsOf: destination.appendingPathComponent("owner-file"), encoding: .utf8)
        == "keep me")
  }

  @Test func nativePDFLinksAndBookmarksSurviveCooperativeExport() async throws {
    let document = try await MarkdownParser().parse(
      "# First\n\n[External](https://example.org/docs) and [Target](#target). [Unsafe](javascript:alert(1)) [Relative](../private.md)\n\n# Target\n\nDOCUMENT-END"
    )
    let rendered = NativeMarkdownRenderer().render(
      document: document, preferences: ReaderPreferences(), tokens: [:])
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".pdf")
    defer { try? FileManager.default.removeItem(at: destination) }
    try await PDFExporter().export(rendered: rendered, to: destination, options: PDFOptions())
    let pdf = try #require(PDFDocument(url: destination))
    #expect(pdf.outlineRoot?.numberOfChildren == 2)
    let links = (0..<pdf.pageCount).flatMap { pdf.page(at: $0)?.annotations ?? [] }
    #expect(links.contains { $0.url?.absoluteString == "https://example.org/docs" })
    #expect(
      links.contains {
        $0.destination?.page != nil || ($0.action as? PDFActionGoTo)?.destination.page != nil
      })
    #expect(links.count == 2)
    #expect(
      !links.contains {
        $0.url?.scheme?.lowercased() == "javascript" || $0.url?.relativeString == "../private.md"
      })
    #expect(pdf.string?.contains("DOCUMENT-END") == true)
  }

  @Test func completePDFCanBeCreatedAndReplacedWithoutTouchingOtherFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("export.pdf")
    let unrelated = directory.appendingPathComponent("owner-notes.txt")
    let ownerBytes = Data("Unrelated owner content must remain unchanged.".utf8)
    try ownerBytes.write(to: unrelated)
    let parser = MarkdownParser()
    for text in ["# First complete export", "# Replacement export succeeded"] {
      let document = try await parser.parse(text)
      let rendered = NativeMarkdownRenderer().render(
        document: document, preferences: ReaderPreferences(), tokens: [:])
      try await PDFExporter().export(rendered: rendered, to: destination, options: PDFOptions())
      let pdf = try #require(PDFDocument(url: destination))
      #expect(pdf.string?.contains(String(text.dropFirst(2))) == true)
      #expect(try Data(contentsOf: unrelated) == ownerBytes)
      #expect(
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
          == ["export.pdf", "owner-notes.txt"])
    }
    let permissions =
      try FileManager.default.attributesOfItem(atPath: destination.path)[
        .posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
  }
}
