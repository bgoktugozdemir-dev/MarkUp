import Foundation
import Testing

@testable import MarkUpCore

@Suite struct HighlightingTests {
  @Test func swiftGrammarUnderstandsModernSyntaxWithoutChangingSource() async throws {
    let source = ##"""
      @MainActor
      struct Box<T: Sendable> {
          @State private var value = #"raw \#(item)"#
          let text = """
          hello \(value)
          """
          // 😀 Turkish: İstanbul; combining: é
          /* outer /* nested */ comment */
          func map<U>(_ transform: (T) -> U) -> [U] { [] }
      }
      """##
    let engine = SyntaxHighlighter()
    let tokens = try await engine.highlight(source, language: "swift")
    assertValid(tokens, source: source)
    #expect(has(tokens, source: source, text: "@MainActor", kind: "meta"))
    #expect(has(tokens, source: source, text: "@State", kind: "meta"))
    #expect(has(tokens, source: source, text: "struct", kind: "keyword"))
    #expect(has(tokens, source: source, text: "raw", kind: "string"))
    #expect(has(tokens, source: source, text: "hello", kind: "string"))
    #expect(has(tokens, source: source, text: "😀", kind: "comment"))
    #expect(has(tokens, source: source, text: "nested", kind: "comment"))
    #expect(has(tokens, source: source, text: "map", kind: "title"))
    #expect(has(tokens, source: source, text: "Sendable", kind: "type"))
    #expect(has(tokens, source: source, text: "item", kind: "subst"))
    #expect(has(tokens, source: source, text: "value", kind: "subst"))
    // Recoloring never passes source back to the grammar or changes the token identities.
    let dark = tokens.map { CodeTheme.theme(id: "github-dark").color(for: $0.kind) }
    let light = tokens.map { CodeTheme.theme(id: "github-light").color(for: $0.kind) }
    #expect(dark.count == light.count && dark != light)
  }

  @Test func allShippedLanguagesUseSpecificGrammars() async throws {
    let samples: [(String, String)] = [
      ("swift", "let answer: Int = 42"), ("bash", "#!/bin/bash\necho \"$HOME\""),
      ("json", "{\"answer\": true}"), ("yaml", "name: \"MarkUp\"\nenabled: true"),
      ("toml", "[package]\nname = \"MarkUp\""), ("javascript", "const x = () => 42;"),
      ("typescript", "interface Item { value: number }"),
      ("jsx", "const x = <span title=\"read\">Hello</span>;"),
      ("tsx", "const x: Element = <span>Hello</span>;"),
      ("python", "def greet(name):\n    return f\"Hello {name}\""),
      ("html", "<div class=\"book\">Read</div>"), ("xml", "<book id=\"1\" />"),
      ("css", ".book { color: #ffffff; }"), ("sql", "SELECT title FROM books WHERE id = 1;"),
      ("c", "#include <stdio.h>\nint main(void) { return 0; }"),
      ("cpp", "template<typename T> class Box { T value; };"),
      ("objectivec", "@interface Book : NSObject\n@property NSString *title;\n@end"),
      ("csharp", "public class Book { public string Title { get; set; } }"),
      ("java", "public class Book { private int count = 1; }"),
      ("kotlin", "data class Book(val title: String)"),
      ("go", "package main\nfunc main() { return }"),
      ("rust", "fn main() { let mut value = 42; }"),
      ("markdown", "# Book\n**bold** [link](https://example.com)"),
      ("diff", "--- old\n+++ new\n@@ -1 +1 @@\n-old\n+new"),
    ]
    let engine = SyntaxHighlighter()
    for (language, source) in samples {
      let tokens = try await engine.highlight(source, language: language)
      #expect(!tokens.isEmpty, "No specific spans for \(language)")
      assertValid(tokens, source: source)
    }
  }

  @Test func aliasesAndPredictableFallback() async throws {
    let groups = [
      ["bash", "sh", "shell", "zsh"], ["javascript", "js", "jsx"],
      ["typescript", "ts", "tsx"], ["toml", "ini"], ["c++", "cpp", "hpp"],
      ["objective-c", "objc", "objectivec"], ["c#", "cs", "csharp"], ["md", "markdown"],
    ]
    for aliases in groups {
      let canonical = SyntaxHighlighter.canonicalLanguage(aliases[0])
      #expect(canonical != nil)
      #expect(aliases.allSatisfy { SyntaxHighlighter.canonicalLanguage($0) == canonical })
    }
    #expect(SyntaxHighlighter.canonicalLanguage(" SWIFT\n") == "swift")
    let engine = SyntaxHighlighter()
    for language in [
      nil, "", "plaintext", "plain", "text", "mermaid", "unknown", "swift'; throw 1;",
    ] {
      #expect(try await engine.highlight("let x = \"<script> & 😀\"", language: language).isEmpty)
    }
    #expect(try await engine.highlight("", language: "swift").isEmpty)
  }

  @Test func utf16SpansPreserveEntitiesCRLFAndUnicode() async throws {
    let source = "// 😀 é İstanbul 日本語\r\nlet message = \"<script> &amp; \\\" café\"\r\n"
    let tokens = try await SyntaxHighlighter().highlight(source, language: "swift")
    assertValid(tokens, source: source)
    #expect(has(tokens, source: source, text: "<script> &amp;", kind: "string"))
    let originalBytes = Array(source.utf8)
    var reconstructed = ""
    var cursor = 0
    for token in tokens {
      reconstructed += (source as NSString).substring(
        with: NSRange(location: cursor, length: token.range.location - cursor))
      reconstructed += (source as NSString).substring(with: token.range)
      cursor = NSMaxRange(token.range)
    }
    reconstructed += (source as NSString).substring(from: cursor)
    #expect(Array(reconstructed.utf8) == originalBytes)
  }

  @Test func limitsCancellationAndResourceRelease() async throws {
    let engine = SyntaxHighlighter()
    await #expect(throws: SyntaxHighlightingError.resourceLimit) {
      try await engine.highlight(
        String(repeating: "a", count: SyntaxHighlighter.maximumLineCodeUnits + 1), language: "swift"
      )
    }
    await #expect(throws: SyntaxHighlightingError.resourceLimit) {
      try await engine.highlight(
        String(repeating: "let value = 1\n", count: 6000), language: "swift")
    }
    let task = Task { () throws -> [SyntaxToken] in
      await Task.yield()
      return try await engine.highlight("let value = 1", language: "swift")
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    let first = try await engine.highlight("let value = 1", language: "swift")
    await engine.releaseResources()
    #expect(try await engine.highlight("let value = 1", language: "swift") == first)
  }

  @Test func adversarialInputIsDataAndFailureDoesNotPoisonEngine() async throws {
    let engine = SyntaxHighlighter()
    // Executing this as JavaScript would throw and destroy the grammar global.
    let payload = "globalThis.hljs = null; throw new Error('document source executed');"
    let spans = try await engine.highlight(payload, language: "javascript")
    assertValid(spans, source: payload)
    #expect(!spans.isEmpty)
    let malformed = [
      ("swift", "/* /* /* unterminated 🧑🏽‍💻 é"),
      ("swift", "let raw = " + String(repeating: "#", count: 800) + "\"unterminated"),
      ("html", "<script><img src=x onerror=\"alert(1)\">&lt;\u{0}"),
      ("json", "{\"\\uD800\": [true, null, 1e9999999"),
      ("tsx", "const x = <A<T> title={\"<>&\"}>{/* unterminated"),
    ]
    for (language, source) in malformed {
      assertValid(try await engine.highlight(source, language: language), source: source)
    }
    await #expect(throws: SyntaxHighlightingError.resourceLimit) {
      try await engine.highlight(String(repeating: "\"", count: 70_000), language: "swift")
    }
    #expect(
      try await engine.highlight("let stillAvailable = true", language: "swift").contains {
        $0.kind == "keyword"
      })
  }

  @Test func themesAreValidDistinctAndPaired() throws {
    #expect(CodeTheme.all.count == 9)
    #expect(Set(CodeTheme.all.map(\.id)).count == CodeTheme.all.count)
    #expect(CodeTheme.all.contains { $0.name == "Darcula" })
    for theme in CodeTheme.all {
      #expect(theme.isValid)
      #expect(try JSONDecoder().decode(CodeTheme.self, from: JSONEncoder().encode(theme)) == theme)
      #expect(theme.color(for: "unknown") == theme.foreground)
      #expect(theme.color(for: "title.function.invoke") != theme.foreground)
      if let pair = theme.pairedThemeID {
        let other = theme.matchingAppearance(dark: !theme.isDark)
        #expect(other.id == pair && other.isDark != theme.isDark)
        #expect(other.pairedThemeID == theme.id)
      }
    }
    #expect(
      !CodeTheme(
        id: "bad", name: "Bad", background: "url(evil)", foreground: "#FFFFFF", colors: [:]
      ).isValid)
    #expect(CodeTheme.theme(id: "missing").id == "one-dark")
  }

  private func has(_ tokens: [SyntaxToken], source: String, text: String, kind: String) -> Bool {
    tokens.contains {
      $0.kind.hasPrefix(kind) && (source as NSString).substring(with: $0.range).contains(text)
    }
  }

  private func assertValid(_ tokens: [SyntaxToken], source: String) {
    var end = 0
    for token in tokens {
      #expect(token.range.location >= end)
      #expect(token.range.length > 0)
      #expect(NSMaxRange(token.range) <= source.utf16.count)
      #expect(Range(token.range, in: source) != nil)
      end = NSMaxRange(token.range)
    }
  }
}
