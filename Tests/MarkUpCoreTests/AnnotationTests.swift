import Foundation
import Testing

@testable import MarkUpCore

struct AnnotationTests {
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MarkUpAnnotationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func identity(_ name: String, resource: String?) -> AnnotationDocumentIdentity {
    AnnotationDocumentIdentity(
      resourceIdentifier: resource, canonicalURL: URL(fileURLWithPath: "/test/\(name).md"))
  }

  @Test func unicodeAndCombiningCharacterRanges() throws {
    let text = "Hello 👨‍👩‍👧‍👦 café e\u{301} İstanbul 日本語"
    for selected in ["👨‍👩‍👧‍👦", "e\u{301}", "İstanbul", "日本語"] {
      let range = (text as NSString).range(of: selected, options: .literal)
      let anchor = try TextAnchor.capture(in: text, range: range)
      #expect(AnchorResolver.resolve(anchor, in: text) == .resolved(range))
    }
    #expect(throws: AnnotationError.invalidRange) {
      try TextAnchor.capture(in: text, range: NSRange(location: 6, length: 1))
    }
    let combining = (text as NSString).range(of: "e\u{301}", options: .literal)
    #expect(throws: AnnotationError.invalidRange) {
      try TextAnchor.capture(in: text, range: NSRange(location: combining.location, length: 1))
    }
    #expect(throws: AnnotationError.invalidRange) {
      try TextAnchor.capture(in: text, range: NSRange(location: Int.max, length: 10))
    }
  }

  @Test func trustworthyShiftAndAmbiguousDuplicate() throws {
    let paragraph = "A sufficiently distinctive prefix. Selected passage. A distinctive suffix."
    let selected = (paragraph as NSString).range(of: "Selected passage")
    let anchor = try TextAnchor.capture(in: paragraph, range: selected)
    let shifted = "New heading\n" + paragraph
    #expect(
      AnchorResolver.resolve(anchor, in: shifted)
        == .resolved((shifted as NSString).range(of: "Selected passage")))
    #expect(AnchorResolver.resolve(anchor, in: paragraph + "\n" + paragraph) == .ambiguous)
    #expect(
      AnchorResolver.resolve(
        anchor, in: paragraph.replacingOccurrences(of: "Selected", with: "Changed")) == .missing)
    #expect(
      AnchorResolver.resolve(anchor, in: "Selected passage but unrelated context") == .missing)
  }

  @Test func wholeDocumentSelectionDoesNotGuessAfterContentChange() throws {
    let anchor = try TextAnchor.capture(in: "sample", range: NSRange(location: 0, length: 6))
    #expect(
      AnchorResolver.resolve(anchor, in: "sample") == .resolved(NSRange(location: 0, length: 6)))
    #expect(AnchorResolver.resolve(anchor, in: "other sample context") == .ambiguous)
    let weak = try TextAnchor.capture(in: "OK\n", range: NSRange(location: 0, length: 2))
    #expect(AnchorResolver.resolve(weak, in: "Other text\nOK\n") == .ambiguous)
  }

  @Test func renameReplacementAndUnrelatedFileIdentity() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AnnotationStore(directory: directory)
    let id = try await store.documentID(for: identity("original", resource: "volume1:file1:birth1"))
    let renamed = try await store.documentID(
      for: identity("renamed", resource: "volume1:file1:birth1"))
    #expect(id == renamed)
    let replacement = try await store.documentID(
      for: identity("renamed", resource: "volume1:file2:birth2"), continuing: id,
      observedReplacement: true)
    #expect(replacement == id)
    let unrelated = try await store.documentID(
      for: identity("renamed", resource: "volume1:file3:birth3"))
    #expect(unrelated != id)
    await #expect(throws: AnnotationError.invalidIdentityContinuation) {
      try await store.documentID(
        for: identity("elsewhere", resource: "volume1:file4:birth4"), continuing: id,
        observedReplacement: true)
    }
    let missingResourceOne = try await store.documentID(for: identity("unknown", resource: nil))
    let missingResourceTwo = try await store.documentID(for: identity("unknown", resource: nil))
    #expect(missingResourceOne != missingResourceTwo)
  }

  @Test func persistsUndoAndClearEpochAcrossRestart() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AnnotationStore(directory: directory)
    let id = try await store.documentID(for: identity("document", resource: "file1"))
    let initial = await store.snapshot(documentID: id)
    let anchor = try TextAnchor.capture(in: "hello world", range: NSRange(location: 6, length: 5))
    let mark = try await store.add(
      documentID: id, anchor: anchor, style: .underline, expectedEpoch: initial.epoch)
    let restarted = try AnnotationStore(directory: directory)
    #expect(await restarted.snapshot(documentID: id).annotations == [mark])
    #expect(try await store.remove(id: mark.id, expectedEpoch: initial.epoch) == mark)
    try await store.restore(mark, expectedEpoch: initial.epoch)
    #expect(await store.count == 1)
    let epoch = try await store.clearAll()
    #expect(epoch == initial.epoch + 1)
    await #expect(throws: AnnotationError.staleEpoch) {
      try await store.restore(mark, expectedEpoch: initial.epoch)
    }
    await #expect(throws: AnnotationError.staleEpoch) {
      try await store.add(
        documentID: id, anchor: anchor, style: .highlightBlue, expectedEpoch: initial.epoch)
    }
    let afterClear = try AnnotationStore(directory: directory)
    #expect(await afterClear.count == 0)
    #expect(await afterClear.snapshot(documentID: id).epoch == epoch)
    #expect(try await store.clearAll() == epoch + 1)
    #expect(await store.count == 0)
    let permissions =
      try FileManager.default.attributesOfItem(
        atPath: directory.appendingPathComponent("annotations.json").path)[.posixPermissions]
      as? NSNumber
    #expect(permissions?.intValue == 0o600)
  }

  @Test func corruptionPreservesBytesAndRequiresExplicitClear() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = Data("{broken input".utf8)
    try bytes.write(to: directory.appendingPathComponent("annotations.json"))
    let store = try AnnotationStore(directory: directory)
    let recovery = try #require(await store.recovery)
    #expect(try Data(contentsOf: recovery.preservedFile) == bytes)
    await #expect(throws: AnnotationError.recoveryRequired) {
      try await store.documentID(for: identity("document", resource: "file1"))
    }
    _ = try await store.clearAll()
    #expect(!FileManager.default.fileExists(atPath: recovery.preservedFile.path))
    #expect(await store.recovery == nil)
    _ = try await store.documentID(for: identity("document", resource: "file1"))
    #expect(await store.count == 0)
  }

  @Test func unknownSchemaIsPreservedRatherThanDowngraded() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = Data(#"{"version":99,"epoch":3,"documents":[],"annotations":[]}"#.utf8)
    try bytes.write(to: directory.appendingPathComponent("annotations.json"))
    let store = try AnnotationStore(directory: directory)
    let recovery = try #require(await store.recovery)
    #expect(try Data(contentsOf: recovery.preservedFile) == bytes)
    #expect(try Data(contentsOf: directory.appendingPathComponent("annotations.json")) == bytes)
  }

  @Test func observersReceiveGlobalInvalidationOnClear() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AnnotationStore(directory: directory)
    let stream = await store.changes()
    var iterator = stream.makeAsyncIterator()
    let epoch = try await store.clearAll()
    let event = await iterator.next()
    #expect(event?.epoch == epoch)
    #expect(event?.documentID == nil)
  }

  @Test func explicitRecoveryRetainsAnchorAndClearInvalidatesTransfer() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AnnotationStore(directory: directory)
    let originalID = try await store.documentID(for: identity("document", resource: "old"))
    let replacementID = try await store.documentID(for: identity("document", resource: "new"))
    let anchor = try TextAnchor.capture(in: "select this", range: NSRange(location: 7, length: 4))
    let mark = try await store.add(
      documentID: originalID, anchor: anchor, style: .highlightYellow, expectedEpoch: 0)
    #expect(await store.documents().first { $0.id == originalID }?.annotationCount == 1)
    try await store.transferAnnotations(from: originalID, to: replacementID, expectedEpoch: 0)
    let transferred = await store.snapshot(documentID: replacementID)
    #expect(transferred.annotations.first?.id == mark.id)
    #expect(transferred.annotations.first?.anchor == anchor)
    #expect(await store.snapshot(documentID: originalID).annotations.isEmpty)
    _ = try await store.clearAll()
    await #expect(throws: AnnotationError.staleEpoch) {
      try await store.transferAnnotations(from: replacementID, to: originalID, expectedEpoch: 0)
    }
  }
}
