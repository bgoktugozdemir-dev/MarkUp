import Foundation
import Testing

@testable import MarkUpCore

struct PreferenceTests {
  @Test func codeBlockHeightPreferencesAreBackwardCompatibleAndValidated() throws {
    var preferences = ReaderPreferences()
    #expect(preferences.limitCodeHeight == false)
    #expect(preferences.codeBlockVisibleRows == 12)
    preferences.limitCodeHeight = true
    preferences.codeBlockVisibleRows = 50
    #expect(try ReaderPreferences.decode(preferences.exported()) == preferences)
    var object = try #require(
      JSONSerialization.jsonObject(with: preferences.exported()) as? [String: Any])
    object.removeValue(forKey: "limitCodeHeight")
    object.removeValue(forKey: "codeBlockVisibleRows")
    let old = try ReaderPreferences.decode(JSONSerialization.data(withJSONObject: object))
    #expect(old.limitCodeHeight ?? true)
    #expect(old.codeBlockVisibleRows ?? 12 == 12)
    preferences.codeBlockVisibleRows = 0
    #expect(throws: PreferenceError.self) { try preferences.validated() }
    preferences.codeBlockVisibleRows = 51
    #expect(throws: PreferenceError.self) { try preferences.validated() }
  }

  @Test func versionOneWithoutOptionalWeightsKeepsSafeDefaults() throws {
    let encoded = try ReaderPreferences().exported()
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "bodyWeight")
    object.removeValue(forKey: "headingWeight")
    let decoded = try ReaderPreferences.decode(JSONSerialization.data(withJSONObject: object))
    #expect(decoded.bodyWeight == nil)
    #expect(decoded.headingWeight == nil)
    #expect(decoded.bodyWeight ?? .regular == .regular)
    #expect(decoded.headingWeight ?? .bold == .bold)
    #expect(decoded.bodySize == 16)
  }

  @Test func weightsRoundTripAndInvalidImportIsRejected() throws {
    var preferences = ReaderPreferences()
    preferences.bodyWeight = .medium
    preferences.headingWeight = .semibold
    #expect(try ReaderPreferences.decode(preferences.exported()) == preferences)
    var object = try #require(
      JSONSerialization.jsonObject(with: preferences.exported()) as? [String: Any])
    object["bodyWeight"] = "execute"
    #expect(throws: (any Error).self) {
      try ReaderPreferences.decode(JSONSerialization.data(withJSONObject: object))
    }
    preferences.codeThemeID = "unknown-theme"
    #expect(throws: PreferenceError.self) { try preferences.validated() }
    #expect(throws: PreferenceError.self) {
      try ReaderPreferences.decode(Data(repeating: 32, count: 64 * 1024 + 1))
    }
  }

  @Test func missingInstalledFontRemainsPortableWhileControlCharactersFail() throws {
    var preferences = ReaderPreferences()
    preferences.bodyFont = "A font unavailable on this Mac"
    #expect(try preferences.validated().bodyFont == preferences.bodyFont)
    preferences.headingFont = "Invalid\nFamily"
    #expect(throws: PreferenceError.self) { try preferences.validated() }
  }
}
