import Foundation
import Testing

@testable import MarkUpCore

struct MarkdownTests {
  private func parse(_ source: String) async throws -> MarkdownDocument {
    try await MarkdownParser().parse(source)
  }

  @Test func commonMarkAndGFMRemainStructured() async throws {
    let document = try await parse(
      """
      Title
      =====

      A *small* **strong** ~~old~~ `inline` [link][ref].

      [ref]: https://example.org/docs

      3. one
         - nested
      4. two

      - [x] finished
      - [ ] pending

      ---
      """)
    #expect(document.headings.first?.title == "Title")
    #expect(document.blocks.contains { $0.kind == .thematicBreak })
    let lists = document.blocks.filter { $0.kind == .list }
    #expect(lists.first?.orderedStart == 3)
    #expect(lists.first?.children.first?.children.contains { $0.kind == .list } == true)
    #expect(lists.last?.children.map(\.taskChecked) == [true, false])
    #expect(document.plainText.contains("small strong old inline link."))
  }

  @Test func allFiveAlertsPreserveNestedBlocks() async throws {
    for alert in MarkdownAlert.allCases {
      let document = try await parse(
        """
        > [!\(alert.rawValue)]
        > A **formatted** [link](https://example.org).
        >
        > Second paragraph.
        >
        > - a list
        >   - nested
        >
        > ```suggestion
        > let change = "source only"
        > ```
        """)
      let block = try #require(document.blocks.first)
      #expect(block.kind == .alert)
      #expect(block.alert == alert)
      #expect(!block.plainText.contains("[!"))
      #expect(block.children.contains { $0.kind == .list })
      #expect(block.children.last?.kind == .code)
      #expect(block.children.last?.language == "suggestion")
      #expect(block.children.last?.code == "let change = \"source only\"\n")
      #expect(block.plainText.contains("Second paragraph."))
    }
  }

  @Test func alertMarkersAreOnlyRecognizedSemantically() async throws {
    let document = try await parse(
      """
      > An ordinary quote mentioning [!NOTE].

      > [!TIP] text on the marker line remains ordinary.

      ```md
      > [!WARNING]
      > source
      ```

      > ```suggestion
      > [!CAUTION]
      > ```
      """)
    #expect(document.blocks.map(\.kind) == [.quote, .quote, .code, .quote])
    #expect(document.blocks.last?.children.first?.code == "[!CAUTION]\n")
  }

  @Test func tableHandlesEscapesInlineFormattingAndImages() async throws {
    let document = try await parse(
      """
      | Left | Middle | Right | Fourth | Fifth | Sixth |
      | :--- | :----: | ----: | ------ | ----- | ----- |
      | A\\|B | `x\\|y` | [link](https://example.org) | **bold** | ![one](images/one.png) ![two](images/two.png) | 終わり |
      """)
    let table = try #require(document.blocks.first?.table)
    #expect(table.alignments.prefix(3) == [.left, .center, .right])
    #expect(table.rows.count == 2)
    #expect(table.rows[1][0].map(\.plainText).joined() == "A|B")
    #expect(table.rows[1][1].map(\.plainText).joined() == "x|y")
    #expect(
      table.rows[1][4].filter {
        if case .image = $0 { return true }
        return false
      }.count == 2)
    #expect(table.rows[1].count == 6)
  }

  @Test func unicodeDuplicateAnchorsAndCodeTitles() async throws {
    let document = try await parse(
      """
      # Türkçe 日本語 `src/<User>.swift` 👩🏽‍💻
      # Türkçe 日本語 `src/<User>.swift` 👩🏽‍💻
      # repeated
      # repeated-1
      # repeated
      # Cafe\u{301}
      # Café
      """)
    #expect(Set(document.headings.map(\.id)).count == 7)
    #expect(document.headings[0].id.contains("türkçe-日本語"))
    #expect(document.headings[0].title.contains("src/<User>.swift"))
    #expect(document.headings[1].id == document.headings[0].id + "-1")
    #expect(document.headings[4].id == "repeated-2")
    #expect(document.headings[6].id == "café-1")
  }

  @Test func identifiersSurviveUnrelatedInsertionAndDifferentiateDuplicates() async throws {
    let original = try await parse(
      "First paragraph.\n\nUnchanged **content**.\n\nRepeated.\n\nRepeated.")
    let updated = try await parse(
      "# New heading\n\nFirst paragraph.\n\nUnchanged **content**.\n\nRepeated.\n\nRepeated.")
    #expect(original.blocks.map(\.id) == updated.blocks.dropFirst().map(\.id))
    #expect(original.blocks[2].id != original.blocks[3].id)
  }

  @Test func frontmatterAndFootnotesNeverRewriteCode() async throws {
    let document = try await parse(
      """
      ---
      title: "A title"
      tags: [native, local]
      ---
      # Heading

      A useful note[^ref].

      [^ref]: This is *footnote* content.
          Continuation line.

      ```text
      [^ref]: not a footnote
      > [!WARNING]
      ```
      """)
    #expect(document.blocks.first?.kind == .metadata)
    #expect(document.blocks.first?.language == "yaml")
    #expect(document.blocks[1].sourceRange?.startLine == 5)
    let footnote = try #require(document.blocks.first { $0.kind == .footnote })
    #expect(footnote.footnoteLabel == "ref")
    #expect(footnote.plainText.contains("footnote content."))
    let paragraph = try #require(document.blocks.first { $0.kind == .paragraph })
    #expect(
      paragraph.inlines.contains {
        if case .link(_, "#fn-ref") = $0 { return true }
        return false
      })
    #expect(document.blocks.last?.code == "[^ref]: not a footnote\n> [!WARNING]\n")
  }

  @Test func unsupportedHTMLAndMermaidStayVisibleSource() async throws {
    let source = "<script>alert('never execute')</script>\n\n```mermaid\ngraph TD; A-->B\n```\n"
    let document = try await parse(source)
    #expect(document.source == source)
    #expect(document.blocks.first?.kind == .html)
    #expect(document.blocks.first?.code == "<script>alert('never execute')</script>\n")
    #expect(document.blocks.last?.language == "mermaid")
    #expect(document.plainText.contains("graph TD; A-->B"))
  }

  @Test func adversarialDepthFailsWithoutLosingActorUsability() async throws {
    let parser = MarkdownParser()
    let deep = String(repeating: "> ", count: 180) + "nested"
    await #expect(throws: MarkdownParseError.self) { try await parser.parse(deep) }
    let normal = try await parser.parse("# Still usable")
    #expect(normal.headings.first?.title == "Still usable")
  }

  @Test func cancellationAndSizeLimitsAreExplicit() async throws {
    let parser = MarkdownParser()
    let task = Task { try await parser.parse(String(repeating: "A", count: 1_000_000)) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    await #expect(throws: MarkdownParseError.self) {
      try await parser.parse(String(repeating: "a", count: 16 * 1024 * 1024 + 1))
    }
  }

  @Test func stressDocumentKeepsEndAndHeadingCount() async throws {
    let source = (0..<10_000).map { $0 % 100 == 0 ? "# Section \($0 / 100)" : "Line \($0) — 日本語 😀" }
      .joined(separator: "\n\n")
    let document = try await parse(source)
    #expect(document.headings.count == 100)
    #expect(document.plainText.hasSuffix("Line 9999 — 日本語 😀"))
  }
}
