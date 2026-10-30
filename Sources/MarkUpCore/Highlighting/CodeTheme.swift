import Foundation

/// Original MarkUp palettes inspired by the named editor families; no official affiliation.
/// Hex colors are deliberately UI-framework independent for shared native screen/PDF rendering.
public struct CodeTheme: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let name: String
  public let background: String
  public let foreground: String
  public let colors: [String: String]
  public let isDark: Bool
  public let pairedThemeID: String?

  public init(
    id: String, name: String, background: String, foreground: String,
    colors: [String: String], isDark: Bool = true, pairedThemeID: String? = nil
  ) {
    self.id = id
    self.name = name
    self.background = background
    self.foreground = foreground
    self.colors = colors
    self.isDark = isDark
    self.pairedThemeID = pairedThemeID
  }

  public func color(for kind: String) -> String {
    if let exact = colors[kind] { return exact }
    if let first = kind.split(separator: ".").first, let base = colors[String(first)] {
      return base
    }
    return foreground
  }

  /// Validate imported data before use. Palettes contain data only, with a small bounded vocabulary.
  public var isValid: Bool {
    let hexCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    func isHex(_ string: String) -> Bool {
      string.count == 7 && string.first == "#"
        && string.dropFirst().unicodeScalars.allSatisfy { hexCharacters.contains($0) }
    }
    return !id.isEmpty && id.utf8.count <= 80 && !name.isEmpty && name.utf8.count <= 120
      && colors.count <= 80 && isHex(background) && isHex(foreground)
      && colors.allSatisfy { !$0.key.isEmpty && $0.key.utf8.count <= 80 && isHex($0.value) }
      && (pairedThemeID?.utf8.count ?? 0) <= 80
  }

  public static let all: [CodeTheme] = [
    palette(
      "one-dark", "One Dark", "#282C34", "#ABB2BF", true, nil,
      "#C678DD", "#98C379", "#D19A66", "#7F8799", "#61AFEF", "#E5C07B", "#E06C75"),
    palette(
      "night-owl", "Night Owl", "#011627", "#D6DEEB", true, nil,
      "#C792EA", "#ADDB67", "#F78C6C", "#7E94A3", "#82AAFF", "#ECC48D", "#7FDBCA"),
    palette(
      "darcula", "Darcula", "#2B2B2B", "#D0D0D0", true, nil,
      "#CC7832", "#A5C28A", "#7BA7CC", "#92999E", "#FFC66D", "#BBB5DB", "#6FB7AD"),
    palette(
      "github-light", "GitHub Light", "#FFFFFF", "#24292F", false, "github-dark",
      "#CF222E", "#0A3069", "#0550AE", "#57606A", "#8250DF", "#953800", "#116329"),
    palette(
      "github-dark", "GitHub Dark", "#0D1117", "#C9D1D9", true, "github-light",
      "#FF7B72", "#A5D6FF", "#79C0FF", "#8B949E", "#D2A8FF", "#FFA657", "#7EE787"),
    palette(
      "vscode-light-plus", "VS Code Light+", "#FFFFFF", "#1E1E1E", false, "vscode-dark-plus",
      "#0000FF", "#A31515", "#076534", "#008000", "#795E26", "#267F99", "#AF00DB"),
    palette(
      "vscode-dark-plus", "VS Code Dark+", "#1E1E1E", "#D4D4D4", true, "vscode-light-plus",
      "#C586C0", "#CE9178", "#B5CEA8", "#85A970", "#DCDCAA", "#4EC9B0", "#9CDCFE"),
    palette(
      "xcode-light", "Xcode-inspired Light", "#FFFFFF", "#262626", false, "xcode-dark",
      "#9B2393", "#C41A16", "#1C00CF", "#536579", "#326D74", "#6C36A8", "#5D6C79"),
    palette(
      "xcode-dark", "Xcode-inspired Dark", "#292A30", "#DFDFE0", true, "xcode-light",
      "#FC5FA3", "#FC6A5D", "#D0BF69", "#8A9BA5", "#67B7A4", "#D0A8FF", "#5DD8FF"),
  ]

  public static func theme(id: String) -> CodeTheme {
    all.first { $0.id == id } ?? all[0]
  }

  public func matchingAppearance(dark: Bool) -> CodeTheme {
    guard dark != isDark, let pairedThemeID else { return self }
    return Self.theme(id: pairedThemeID)
  }

  private static func palette(
    _ id: String, _ name: String, _ background: String, _ foreground: String,
    _ dark: Bool, _ pair: String?, _ keyword: String, _ string: String,
    _ number: String, _ comment: String, _ function: String,
    _ type: String, _ variable: String
  ) -> CodeTheme {
    CodeTheme(
      id: id, name: name, background: background, foreground: foreground,
      colors: [
        "keyword": keyword, "literal": keyword, "operator": keyword, "selector-tag": keyword,
        "string": string, "regexp": string, "symbol": string, "bullet": string, "addition": string,
        "number": number, "comment": comment, "quote": comment, "doctag": comment,
        "title": function, "title.function": function, "title.function.invoke": function,
        "built_in": type, "type": type, "title.class": type, "class": type,
        "meta": variable, "variable": variable, "attr": variable, "attribute": variable,
        "property": variable, "params": foreground, "punctuation": foreground,
        "subst": foreground, "char.escape": number, "tag": keyword, "name": keyword,
        "selector-class": type, "selector-id": type, "selector-pseudo": keyword,
        "section": function, "strong": keyword, "emphasis": variable,
        "code": string, "link": type, "deletion": keyword,
      ], isDark: dark, pairedThemeID: pair)
  }
}
