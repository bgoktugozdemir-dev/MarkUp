import CryptoKit
import Foundation
import Markdown
import cmark_gfm

public actor MarkdownParser {
  public init() {}

  public func parse(_ source: String) throws -> MarkdownDocument {
    guard source.utf8.count <= 16 * 1024 * 1024 else { throw MarkdownParseError.tooLarge }
    try Task.checkCancellation()
    var builder = Builder(source: source)
    let prepared = builder.extractFrontmatter()
    try Self.validateStructure(prepared)
    let tree = Document(parsing: prepared, options: [.disableSmartOpts])
    var blocks = try tree.children.map { try builder.block($0, depth: 0) }
    if let metadata = builder.metadata { blocks.insert(metadata, at: 0) }
    // The supported footnote extension is interpreted only in prose nodes, never inside code or HTML.
    builder.collectFootnotes(blocks)
    blocks = blocks.map { builder.resolveFootnotes($0) }
    return MarkdownDocument(
      source: source, blocks: blocks, headings: builder.headings,
      plainText: blocks.map(\.plainText).joined(separator: "\n\n"))
  }

  /// The dependency's Swift converter is recursive. Inspect cmark's tree iteratively first so an
  /// untrusted nesting bomb is rejected before recursive Swift conversion or projection can run.
  private static func validateStructure(_ source: String) throws {
    guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else {
      throw MarkdownParseError.tooComplex
    }
    defer { cmark_parser_free(parser) }
    source.withCString { cmark_parser_feed(parser, $0, source.utf8.count) }
    guard let document = cmark_parser_finish(parser) else { throw MarkdownParseError.tooComplex }
    defer { cmark_node_free(document) }
    var node = document
    var depth = 0
    var count = 0
    while true {
      count += 1
      if count % 1024 == 0 { try Task.checkCancellation() }
      guard depth <= 48, count <= 250_000 else { throw MarkdownParseError.tooComplex }
      if let child = cmark_node_first_child(node) {
        node = child
        depth += 1
        continue
      }
      while cmark_node_next(node) == nil {
        guard let parent = cmark_node_parent(node) else { return }
        node = parent
        depth -= 1
      }
      node = cmark_node_next(node)!
    }
  }
}

private struct Builder {
  let source: String
  var headings: [MarkdownHeading] = []
  var metadata: MarkdownBlock?
  var identifiers: [String: Int] = [:]
  var anchors = Set<String>()
  var footnoteLabels = Set<String>()
  var nodeCount = 0

  mutating func extractFrontmatter() -> String {
    let lines = source.components(separatedBy: "\n")
    guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
      let closing = lines.dropFirst().prefix(4096).firstIndex(where: {
        ["---", "..."].contains($0.trimmingCharacters(in: .whitespacesAndNewlines))
      })
    else { return source }
    let content = lines[1..<closing].joined(separator: "\n")
    metadata = MarkdownBlock(
      id: identity("metadata", content), kind: .metadata,
      code: content, language: "yaml",
      sourceRange: SourceSpan(startLine: 1, startColumn: 1, endLine: closing + 1, endColumn: 4))
    // Retain original line numbers while preventing frontmatter from becoming a setext heading.
    return Array(repeating: "", count: closing + 1).joined(separator: "\n") + "\n"
      + lines.dropFirst(closing + 1).joined(separator: "\n")
  }

  mutating func identity(_ kind: String, _ content: String) -> String {
    let digest = SHA256.hash(data: Data((kind + "\u{0}" + content).utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    let occurrence = identifiers[digest, default: 0]
    identifiers[digest] = occurrence + 1
    return "\(digest)-\(occurrence)"
  }

  mutating func block(_ node: any Markup, depth: Int) throws -> MarkdownBlock {
    try Task.checkCancellation()
    nodeCount += 1
    guard depth <= 32, nodeCount <= 250_000 else { throw MarkdownParseError.tooComplex }
    var result = MarkdownBlock(id: "", kind: .paragraph)
    if let range = node.range {
      result.sourceRange = SourceSpan(
        startLine: range.lowerBound.line, startColumn: range.lowerBound.column,
        endLine: range.upperBound.line, endColumn: range.upperBound.column)
    }
    switch node {
    case let heading as Heading:
      result.kind = .heading
      result.headingLevel = heading.level
      result.inlines = try inlineChildren(heading, depth: depth)
      let title = result.inlines.map(\.plainText).joined()
      let base = slug(title)
      var anchor = base
      var duplicate = 0
      while anchors.contains(anchor) {
        duplicate += 1
        anchor = "\(base)-\(duplicate)"
      }
      anchors.insert(anchor)
      result.anchor = anchor
    case let code as CodeBlock:
      result.kind = .code
      result.code = code.code
      result.language = code.language?.split(whereSeparator: \.isWhitespace).first.map(String.init)
    case let paragraph as Paragraph:
      result.inlines = try inlineChildren(paragraph, depth: depth)
      if case .text(let first)? = result.inlines.first,
        let marker = first.range(of: #"^\[\^([^\]\s]+)\]:\s*"#, options: .regularExpression)
      {
        let prefix = String(first[marker])
        result.kind = .footnote
        result.footnoteLabel = String(prefix.dropFirst(2).prefix(while: { $0 != "]" }))
        result.anchor = "fn-" + (result.footnoteLabel ?? "")
        result.inlines[0] = .text(String(first[marker.upperBound...]))
      }
    case let quote as BlockQuote:
      result.kind = .quote
      result.children = try quote.children.map { try block($0, depth: depth + 1) }
      if var first = result.children.first, first.kind == .paragraph,
        case .text(let marker)? = first.inlines.first
      {
        // GitHub requires the marker to occupy its own first line of a blockquote.
        let trimmed = marker.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[!"), trimmed.hasSuffix("]"),
          let alert = MarkdownAlert(rawValue: String(trimmed.dropFirst(2).dropLast())),
          first.inlines.count == 1 || isBreak(first.inlines[1])
        {
          result.kind = .alert
          result.alert = alert
          first.inlines.removeFirst()
          if first.inlines.first.map(isBreak) == true { first.inlines.removeFirst() }
          if first.inlines.isEmpty {
            result.children.removeFirst()
          } else {
            result.children[0] = first
          }
        }
      }
    case let list as OrderedList:
      result.kind = .list
      result.orderedStart = Int(clamping: list.startIndex)
      result.children = try list.children.map { try block($0, depth: depth + 1) }
    case let list as UnorderedList:
      result.kind = .list
      result.children = try list.children.map { try block($0, depth: depth + 1) }
    case let item as ListItem:
      result.kind = .listItem
      result.taskChecked = item.checkbox.map { $0 == .checked }
      result.children = try item.children.map { try block($0, depth: depth + 1) }
    case let table as Table:
      result.kind = .table
      let header = try table.head.children.map { try inlineChildren($0, depth: depth + 1) }
      let rows = try table.body.children.map { row in
        try row.children.map { try inlineChildren($0, depth: depth + 1) }
      }
      result.table = MarkdownTable(
        rows: [header] + rows,
        alignments: table.columnAlignments.map {
          switch $0 {
          case .center: .center
          case .right: .right
          default: .left
          }
        }, headerRowCount: 1)
    case is ThematicBreak: result.kind = .thematicBreak
    case let html as HTMLBlock:
      result.kind = .html
      result.code = html.rawHTML  // Deliberately no HTML execution or document import.
    default:
      result.children = try node.children.map { try block($0, depth: depth + 1) }
    }
    let signature =
      result.plainText + "|" + (result.language ?? "") + "|" + (result.alert?.rawValue ?? "")
      + "|" + (result.headingLevel.map(String.init) ?? "") + "|"
      + String(describing: result.inlines)
      + "|" + (result.orderedStart.map(String.init) ?? "") + "|"
      + String(describing: result.taskChecked)
      + "|" + String(describing: result.table?.rows) + "|"
      + String(describing: result.table?.alignments)
      + "|" + result.children.map { String($0.id.prefix(64)) }.joined(separator: ":")
    result.id = identity(result.kind.rawValue, signature)
    if result.kind == .heading {
      headings.append(
        MarkdownHeading(
          id: result.anchor ?? result.id, level: result.headingLevel ?? 1,
          title: result.inlines.map(\.plainText).joined(), blockID: result.id))
    }
    return result
  }

  func isBreak(_ inline: MarkdownInline) -> Bool {
    switch inline {
    case .softBreak, .hardBreak: true
    default: false
    }
  }

  mutating func inlineChildren(_ node: any Markup, depth: Int) throws -> [MarkdownInline] {
    try node.children.flatMap { try inline($0, depth: depth + 1) }
  }

  mutating func inline(_ node: any Markup, depth: Int) throws -> [MarkdownInline] {
    nodeCount += 1
    guard depth <= 32, nodeCount <= 250_000 else { throw MarkdownParseError.tooComplex }
    switch node {
    case let text as Text: return [.text(text.string)]
    case let code as InlineCode: return [.code(code.code)]
    case let emphasis as Emphasis: return [.emphasis(try inlineChildren(emphasis, depth: depth))]
    case let strong as Strong: return [.strong(try inlineChildren(strong, depth: depth))]
    case let strike as Strikethrough:
      return [.strikethrough(try inlineChildren(strike, depth: depth))]
    case let link as Link:
      return [
        .link(text: try inlineChildren(link, depth: depth), destination: link.destination ?? "")
      ]
    case let image as Image: return [.image(alt: image.plainText, source: image.source ?? "")]
    case is SoftBreak: return [.softBreak]
    case is LineBreak: return [.hardBreak]
    case let html as InlineHTML: return [.html(html.rawHTML)]
    default: return try inlineChildren(node, depth: depth)
    }
  }

  func slug(_ title: String) -> String {
    let allowed = CharacterSet.letters.union(.decimalDigits).union(.nonBaseCharacters)
    let scalars = title.lowercased().precomposedStringWithCanonicalMapping.unicodeScalars.filter {
      allowed.contains($0) || CharacterSet.whitespaces.contains($0) || $0 == "-" || $0 == "_"
    }
    let result = String(String.UnicodeScalarView(scalars)).replacingOccurrences(
      of: #"\s"#, with: "-", options: .regularExpression)
    return result.isEmpty ? "section" : result
  }

  mutating func collectFootnotes(_ blocks: [MarkdownBlock]) {
    for block in blocks {
      if let label = block.footnoteLabel { footnoteLabels.insert(label) }
      collectFootnotes(block.children)
    }
  }

  func resolveFootnotes(_ original: MarkdownBlock) -> MarkdownBlock {
    var block = original
    block.inlines = references(block.inlines)
    block.children = block.children.map(resolveFootnotes)
    if var table = block.table {
      table.rows = table.rows.map { $0.map(references) }
      block.table = table
    }
    return block
  }

  func references(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
    inlines.flatMap { inline -> [MarkdownInline] in
      switch inline {
      case .text(let text):
        guard let regex = try? NSRegularExpression(pattern: #"\[\^([^\]\s]+)\]"#) else {
          return [inline]
        }
        let ns = text as NSString
        var output: [MarkdownInline] = []
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
          let label = ns.substring(with: match.range(at: 1))
          guard footnoteLabels.contains(label) else { continue }
          output.append(
            .text(
              ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
          output.append(.link(text: [.text("[\(label)]")], destination: "#fn-\(label)"))
          cursor = NSMaxRange(match.range)
        }
        output.append(.text(ns.substring(from: cursor)))
        return output
      case .emphasis(let values): return [.emphasis(references(values))]
      case .strong(let values): return [.strong(references(values))]
      case .strikethrough(let values): return [.strikethrough(references(values))]
      default: return [inline]
      }
    }
  }
}
