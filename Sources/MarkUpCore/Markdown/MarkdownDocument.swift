import Foundation

/// Immutable, Sendable projection of the parser's tree. No parser nodes cross an actor boundary.
public struct MarkdownDocument: Sendable {
  public var source: String
  public var blocks: [MarkdownBlock]
  public var headings: [MarkdownHeading]
  public var plainText: String
}

public enum MarkdownBlockKind: String, Sendable {
  case paragraph, heading, code, quote, list, listItem, table, thematicBreak, alert, html, metadata,
    footnote
}

public enum MarkdownAlert: String, Sendable, CaseIterable {
  case note = "NOTE"
  case tip = "TIP"
  case important = "IMPORTANT"
  case warning = "WARNING"
  case caution = "CAUTION"
}

public struct SourceSpan: Sendable, Equatable {
  public var startLine: Int
  public var startColumn: Int
  public var endLine: Int
  public var endColumn: Int
}

public struct MarkdownBlock: Sendable, Identifiable {
  public var id: String
  public var kind: MarkdownBlockKind
  public var inlines: [MarkdownInline] = []
  public var children: [MarkdownBlock] = []
  public var code: String?
  public var language: String?
  public var table: MarkdownTable?
  public var headingLevel: Int?
  public var anchor: String?
  public var sourceRange: SourceSpan?
  public var alert: MarkdownAlert?
  public var orderedStart: Int?
  public var taskChecked: Bool?
  public var footnoteLabel: String?

  public var plainText: String {
    if let code { return code }
    if let table {
      return table.rows.map { $0.map { $0.map(\.plainText).joined() }.joined(separator: "\t") }
        .joined(separator: "\n")
    }
    return ([inlines.map(\.plainText).joined()] + children.map(\.plainText))
      .filter { !$0.isEmpty }.joined(separator: "\n")
  }
}

public indirect enum MarkdownInline: Sendable {
  case text(String)
  case emphasis([Self])
  case strong([Self])
  case strikethrough([Self])
  case code(String)
  case link(text: [Self], destination: String)
  case image(alt: String, source: String)
  case softBreak, hardBreak
  case html(String)

  public var plainText: String {
    switch self {
    case .text(let text), .code(let text), .html(let text): return text
    case .emphasis(let children), .strong(let children), .strikethrough(let children):
      return children.map(\.plainText).joined()
    case .link(let children, _): return children.map(\.plainText).joined()
    case .image(let alt, _): return alt
    case .softBreak: return " "
    case .hardBreak: return "\n"
    }
  }
}

public enum TableAlignment: String, Sendable { case left, center, right }

public struct MarkdownTable: Sendable {
  public var rows: [[[MarkdownInline]]]
  public var alignments: [TableAlignment]
  public var headerRowCount: Int
}

public struct MarkdownHeading: Sendable, Identifiable {
  public var id: String
  public var level: Int
  public var title: String
  public var blockID: String
}

public enum MarkdownParseError: Error, Sendable { case tooLarge, tooComplex }
