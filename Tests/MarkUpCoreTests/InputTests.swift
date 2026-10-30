import Foundation
import Testing

@testable import MarkUpCore

@Test func inputPreservesUnicodeAndLineEndings() throws {
  let text = "Türkçe 😀 e\u{301}\r\n# Heading\n"
  #expect(try DocumentInput.decode(Data(text.utf8)) == text)
  #expect(try DocumentInput.decode(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)) == text)
  #expect(
    try DocumentInput.decode(Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!) == text)
  #expect(throws: DocumentInputError.self) { try DocumentInput.decode(Data([0xFF, 0x00, 0xCC])) }
  #expect(throws: DocumentInputError.self) { try DocumentInput.decode(Data([0])) }
  #expect(throws: DocumentInputError.self) { try DocumentInput.decode(Data([0xFF, 0xFE, 0x61])) }
  #expect(throws: DocumentInputError.self) {
    try DocumentInput.decode(Data([0xFF, 0xFE, 0x00, 0xD8]))
  }
}

@Test func preferencesRejectUnsafeOrUnboundedValues() throws {
  var value = ReaderPreferences()
  #expect(try ReaderPreferences.decode(value.exported()) == value)
  value.zoom = .infinity
  #expect(throws: PreferenceError.self) { try value.validated() }
  value = ReaderPreferences()
  value.version = 2
  #expect(throws: PreferenceError.self) { try value.validated() }
}

@Test func linksDoNotAuthorizePathsOrExecution() {
  #expect(ResourcePolicy.externalURL("javascript:alert(1)") == nil)
  #expect(ResourcePolicy.externalURL("https://example.com/docs") != nil)
  let document = URL(fileURLWithPath: "/tmp/docs/readme.md")
  #expect(
    ResourcePolicy.localURL(
      "../../etc/passwd", relativeTo: document, grantedRoots: [URL(fileURLWithPath: "/tmp/docs")])
      == nil)
  #expect(ResourcePolicy.localURL("image.png", relativeTo: document, grantedRoots: []) == nil)
}
