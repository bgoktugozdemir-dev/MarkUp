import Foundation
import JavaScriptCore

/// A styled, nonoverlapping span into the original source's UTF-16 representation.
/// Unstyled gaps use the theme foreground. No HTML or replacement text crosses this boundary.
public struct SyntaxToken: Sendable, Equatable, Codable {
  public let range: NSRange
  public let kind: String

  public init(range: NSRange, kind: String) {
    self.range = range
    self.kind = kind
  }
}

public enum SyntaxHighlightingError: Error, Sendable, Equatable {
  case resourceLimit
  case engineUnavailable
  case invalidOutput
}

/// Owns one lazily initialized JavaScriptCore VM; all JS references remain actor isolated.
/// Tokenization is independent of appearance, so callers can recolor cached spans on theme changes.
/// Unknown languages and Mermaid intentionally return no styled spans. On error, show the original code.
public actor SyntaxHighlighter {
  public static let maximumCodeUnits = 65_536
  public static let maximumLineCodeUnits = 16_384
  public static let grammarVersion = "11.12.0"
  public static let supportedLanguages = [
    "swift", "bash", "json", "yaml", "toml", "javascript", "typescript", "jsx", "tsx",
    "python", "html", "xml", "css", "sql", "c", "cpp", "objectivec", "csharp", "java",
    "kotlin", "go", "rust", "markdown", "diff", "plaintext",
  ]

  private var context: JSContext?
  private var loaded: Set<String> = []

  public init() {}

  public static func canonicalLanguage(_ identifier: String?) -> String? {
    guard let identifier else { return nil }
    let name = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    // Match a single fence identifier; metadata is handled by the Markdown parser.
    return aliases[name]
  }

  public func highlight(_ code: String, language: String?) throws -> [SyntaxToken] {
    try Task.checkCancellation()
    guard let grammar = Self.canonicalLanguage(language), !code.isEmpty else { return [] }
    guard code.utf16.count <= Self.maximumCodeUnits,
      !code.split(whereSeparator: \.isNewline).contains(where: {
        $0.utf16.count > Self.maximumLineCodeUnits
      })
    else {
      throw SyntaxHighlightingError.resourceLimit
    }
    let engine = try prepareEngine()
    try load(grammar, in: engine)
    try Task.checkCancellation()
    // This block executes synchronously on this actor's task, including when JS calls it back.
    let cancelled: @convention(block) () -> Bool = { Task.isCancelled }
    engine.setObject(cancelled, forKeyedSubscript: "markupIsCancelled" as NSString)
    defer { engine.setObject(nil, forKeyedSubscript: "markupIsCancelled" as NSString) }
    engine.exception = nil
    let output = engine.objectForKeyedSubscript("markupTokens")?.call(withArguments: [
      code, grammar,
    ])
    try Task.checkCancellation()
    guard engine.exception == nil, let json = output?.toString(), let data = json.data(using: .utf8)
    else {
      engine.exception = nil
      throw SyntaxHighlightingError.resourceLimit
    }
    struct Span: Decodable {
      let location: Int
      let length: Int
      let kind: String
    }
    guard let spans = try? JSONDecoder().decode([Span].self, from: data), spans.count <= 30_000
    else {
      throw SyntaxHighlightingError.invalidOutput
    }
    let length = code.utf16.count
    var end = 0
    var tokens: [SyntaxToken] = []
    tokens.reserveCapacity(spans.count)
    for span in spans {
      guard span.location >= end, span.length > 0, span.location <= length,
        span.length <= length - span.location, !span.kind.isEmpty, span.kind.utf8.count < 128
      else {
        throw SyntaxHighlightingError.invalidOutput
      }
      let range = NSRange(location: span.location, length: span.length)
      // A native text attribute must never split a surrogate pair.
      guard Range(range, in: code) != nil else { throw SyntaxHighlightingError.invalidOutput }
      tokens.append(SyntaxToken(range: range, kind: span.kind))
      end = NSMaxRange(range)
    }
    try Task.checkCancellation()
    return tokens
  }

  /// Releases compiled grammars/VM when a reader closes or memory pressure requires it.
  public func releaseResources() {
    context = nil
    loaded.removeAll()
  }

  private func prepareEngine() throws -> JSContext {
    if let context { return context }
    guard let engine = JSContext() else { throw SyntaxHighlightingError.engineUnavailable }
    let core = try resource("hljs-core")
    engine.evaluateScript(
      "globalThis.hljs = (function() { const module = {exports: {}};\n" + core
        + "\nreturn module.exports; }());")
    engine.evaluateScript(try resource("markup-token-emitter"))
    guard engine.exception == nil else { throw SyntaxHighlightingError.engineUnavailable }
    context = engine
    return engine
  }

  private func load(_ grammar: String, in engine: JSContext) throws {
    guard !loaded.contains(grammar) else { return }
    // Dependencies are bounded and explicit; XML/CSS/JS can embed each other.
    let dependencies: [String]
    switch grammar {
    case "javascript", "typescript", "xml", "markdown": dependencies = ["xml", "css", "javascript"]
    default: dependencies = []
    }
    for name in dependencies + [grammar] where !loaded.contains(name) {
      let source = try resource("hljs-" + name)
      // name is drawn exclusively from the static allowlist, never interpolated document data.
      engine.evaluateScript(
        "(function() { const module = {exports: {}};\n" + source + "\nhljs.registerLanguage('"
          + name + "', module.exports); }());")
      guard engine.exception == nil else { throw SyntaxHighlightingError.engineUnavailable }
      loaded.insert(name)
    }
  }

  private func resource(_ name: String) throws -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: "js"),
      let source = try? String(contentsOf: url, encoding: .utf8)
    else {
      throw SyntaxHighlightingError.engineUnavailable
    }
    return source
  }

  private static let aliases: [String: String] = {
    let groups: [String: [String]] = [
      "swift": ["swift"], "bash": ["bash", "sh", "shell", "zsh", "shellscript"],
      "json": ["json", "jsonc"], "yaml": ["yaml", "yml"], "ini": ["toml", "ini"],
      "javascript": ["javascript", "js", "jsx", "mjs", "cjs"],
      "typescript": ["typescript", "ts", "tsx", "mts", "cts"], "python": ["python", "py"],
      "xml": ["html", "xml", "xhtml", "svg"], "css": ["css"], "sql": ["sql"],
      "c": ["c", "h"], "cpp": ["cpp", "c++", "cc", "cxx", "hpp", "h++"],
      "objectivec": ["objectivec", "objective-c", "objc", "mm"],
      "csharp": ["csharp", "c#", "cs"], "java": ["java"], "kotlin": ["kotlin", "kt", "kts"],
      "go": ["go", "golang"], "rust": ["rust", "rs"],
      "markdown": ["markdown", "md"], "diff": ["diff", "patch"],
    ]
    return Dictionary(
      uniqueKeysWithValues: groups.flatMap { canonical, names in names.map { ($0, canonical) } })
  }()
}
