import Foundation

public enum AppLanguage: String, Codable, Sendable, CaseIterable { case en, tr }
public enum AppAppearance: String, Codable, Sendable, CaseIterable { case system, light, dark }
public enum TextWeight: String, Codable, Sendable, CaseIterable {
  case regular, medium, semibold, bold
}

public struct ReaderPreferences: Codable, Sendable, Equatable {
  public var version = 1
  public var language: AppLanguage = .en
  public var appearance: AppAppearance = .system
  public var bodyFont = "System"
  public var headingFont = "System"
  public var codeFont = "Menlo"
  // Optional fields keep previously exported version-1 preferences backward compatible.
  public var bodyWeight: TextWeight? = .regular
  public var headingWeight: TextWeight? = .bold
  public var bodySize = 16.0
  public var headingScale = 1.8
  public var headingSizes = [32.0, 27, 23, 20, 18, 16]
  public var codeSize = 13.0
  public var lineSpacing = 4.0
  public var paragraphSpacing = 10.0
  public var contentWidth = 860.0
  public var zoom = 1.0
  public var codeThemeID = "github-light"
  public var automaticTheme = false
  public var showMinimap = true
  public var showOutline = false
  public var wrapCode = true
  public var limitCodeHeight: Bool? = false
  public var codeBlockVisibleRows: Int? = 12
  public var lineNumbers = false
  public var allowRemoteImages = false
  public var externalEditorBookmark: Data?

  public init() {}

  public func validated() throws -> Self {
    guard version == 1 else { throw PreferenceError.unsupportedVersion }
    guard (8...48).contains(bodySize), (8...48).contains(codeSize),
      (1...4).contains(headingScale), headingSizes.count == 6,
      headingSizes.allSatisfy({ (8...96).contains($0) }),
      (0...30).contains(lineSpacing), (0...60).contains(paragraphSpacing),
      (320...1800).contains(contentWidth), (0.5...3).contains(zoom),
      (1...50).contains(codeBlockVisibleRows ?? 12),
      [bodyFont, headingFont, codeFont].allSatisfy({
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 128
          && $0.rangeOfCharacter(from: .controlCharacters) == nil
      }), CodeTheme.all.contains(where: { $0.id == codeThemeID })
    else { throw PreferenceError.invalidValues }
    return self
  }

  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= 64 * 1024 else { throw PreferenceError.tooLarge }
    return try JSONDecoder().decode(Self.self, from: data).validated()
  }

  public func exported() throws -> Data {
    var copy = try validated()
    copy.externalEditorBookmark = nil  // Access grants never travel in preference files.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(copy)
  }
}

public enum PreferenceError: Error, Sendable { case unsupportedVersion, invalidValues, tooLarge }
