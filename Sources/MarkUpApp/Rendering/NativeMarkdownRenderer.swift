import AppKit
import MarkUpCore

extension NSAttributedString.Key {
  static let markupBlockID = Self("MarkUp.blockID")
  static let markupAnchor = Self("MarkUp.anchor")
  static let markupImageSource = Self("MarkUp.imageSource")
  static let markupImageAlt = Self("MarkUp.imageAlt")
  static let markupCodeLanguage = Self("MarkUp.codeLanguage")
  static let markupTableHeader = Self("MarkUp.tableHeader")
  static let markupTableColumn = Self("MarkUp.tableColumn")
  static let markupInlineCode = Self("MarkUp.inlineCode")
}

struct RenderedBlock: Identifiable {
  var id: String
  var range: NSRange
  var kind: MarkdownBlockKind
}

struct RenderedDocument {
  var attributedString: NSAttributedString
  var blocks: [RenderedBlock]
}

/// Produces one native text flow, so selections and PDF text can span every Markdown block.
/// AppKit fonts/colors/tables are intentionally created only on the main actor; parsing and tokens are not.
@MainActor
final class NativeMarkdownRenderer {
  private struct FontKey: Hashable {
    var name: String
    var size: Double
    var mono: Bool
    var bold: Bool
    var weight: String
  }

  private var output = NSMutableAttributedString()
  private var rendered: [RenderedBlock] = []
  private var preferences = ReaderPreferences()
  private var tokens: [String: [SyntaxToken]] = [:]
  private var theme = CodeTheme.theme(id: "github-light")
  private var fonts: [FontKey: NSFont] = [:]

  func render(
    document: MarkdownDocument, preferences: ReaderPreferences,
    tokens: [String: [SyntaxToken]]
  ) -> RenderedDocument {
    // Fonts are immutable; reuse them only within this render so system font changes and
    // subsequent typography preferences always get a fresh resolution.
    fonts.removeAll(keepingCapacity: true)
    self.preferences = preferences
    self.tokens = tokens
    let selected = CodeTheme.theme(id: preferences.codeThemeID)
    let dark: Bool =
      switch preferences.appearance {
      case .light: false
      case .dark: true
      case .system:
        (NSApp.keyWindow?.effectiveAppearance ?? NSApp.effectiveAppearance).bestMatch(from: [
          .darkAqua, .aqua,
        ]) == .darkAqua
      }
    self.theme = preferences.automaticTheme ? selected.matchingAppearance(dark: dark) : selected
    output = NSMutableAttributedString()
    rendered = []
    for block in document.blocks { append(block, depth: 0) }
    return RenderedDocument(
      attributedString: output.copy() as! NSAttributedString, blocks: rendered)
  }

  private var bodyFont: NSFont {
    font(
      preferences.bodyFont, size: preferences.bodySize * preferences.zoom,
      weight: preferences.bodyWeight ?? .regular)
  }
  private var codeFont: NSFont {
    font(preferences.codeFont, size: preferences.codeSize * preferences.zoom, mono: true)
  }

  private func font(
    _ name: String, size: Double, mono: Bool = false, bold: Bool = false,
    weight: TextWeight = .regular
  ) -> NSFont {
    let key = FontKey(name: name, size: size, mono: mono, bold: bold, weight: weight.rawValue)
    if let cached = fonts[key] { return cached }
    let selectedWeight: NSFont.Weight =
      switch weight {
      case .regular: .regular
      case .medium: .medium
      case .semibold: .semibold
      case .bold: .bold
      }
    let fallback =
      mono
      ? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : selectedWeight)
      : NSFont.systemFont(ofSize: size, weight: bold ? .bold : selectedWeight)
    let selected = name == "System" ? fallback : NSFont(name: name, size: size) ?? fallback
    let descriptor = selected.fontDescriptor.addingAttributes([
      .traits: [NSFontDescriptor.TraitKey.weight: selectedWeight.rawValue]
    ])
    let weighted = NSFont(descriptor: descriptor, size: size) ?? selected
    let result =
      bold ? NSFontManager.shared.convert(weighted, toHaveTrait: .boldFontMask) : weighted
    fonts[key] = result
    return result
  }

  private func style(depth: Int = 0) -> NSMutableParagraphStyle {
    let value = NSMutableParagraphStyle()
    value.lineSpacing = preferences.lineSpacing * preferences.zoom
    value.paragraphSpacing = preferences.paragraphSpacing * preferences.zoom
    value.headIndent = Double(depth) * 22 * preferences.zoom
    value.firstLineHeadIndent = value.headIndent
    value.lineBreakMode = .byWordWrapping
    return value
  }

  private func base(depth: Int = 0) -> [NSAttributedString.Key: Any] {
    [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style(depth: depth)]
  }

  private func append(_ block: MarkdownBlock, depth: Int, listMarker: String? = nil) {
    let start = output.length
    var attributes = base(depth: depth)
    attributes[.markupBlockID] = block.id
    if let anchor = block.anchor { attributes[.markupAnchor] = anchor }
    switch block.kind {
    case .paragraph, .heading, .footnote:
      if block.kind == .heading {
        let level = min(6, max(1, block.headingLevel ?? 1))
        attributes[.font] = font(
          preferences.headingFont,
          size: preferences.headingSizes[level - 1] * preferences.zoom,
          weight: preferences.headingWeight ?? .bold)
        let paragraph = style(depth: depth)
        paragraph.paragraphSpacingBefore = level == 1 ? 16 : 10
        paragraph.headerLevel = level
        attributes[.paragraphStyle] = paragraph
      }
      if block.kind == .footnote, let label = block.footnoteLabel {
        output.append(NSAttributedString(string: "[\(label)] ", attributes: attributes))
      }
      if let listMarker {
        output.append(NSAttributedString(string: listMarker + " ", attributes: attributes))
      }
      output.append(inlines(block.inlines, attributes: attributes))
      newline(attributes)
    case .code, .metadata:
      let code = block.code ?? ""
      attributes[.font] = codeFont
      attributes[.foregroundColor] = color(theme.foreground)
      attributes[.backgroundColor] = color(theme.background)
      attributes[.markupCodeLanguage] = block.language ?? "plaintext"
      let paragraph = style(depth: depth)
      paragraph.lineSpacing = 2 * preferences.zoom
      paragraph.lineBreakMode = preferences.wrapCode ? .byCharWrapping : .byClipping
      attributes[.paragraphStyle] = paragraph
      if block.kind == .metadata {
        let label = preferences.language == .tr ? "Belge üstverisi" : "Document metadata"
        output.append(NSAttributedString(string: label + "\n", attributes: base(depth: depth)))
      }
      let codeStart = output.length
      output.append(NSAttributedString(string: code, attributes: attributes))
      for token in tokens[block.id] ?? [] {
        guard token.range.location >= 0, token.range.length >= 0,
          token.range.location <= (code as NSString).length,
          token.range.length <= (code as NSString).length - token.range.location
        else { continue }
        output.addAttribute(
          .foregroundColor, value: color(theme.color(for: token.kind)),
          range: NSRange(location: codeStart + token.range.location, length: token.range.length))
      }
      if !code.hasSuffix("\n") { newline(attributes) }
      // Structural separator belongs to the block, but is never part of the original code copy payload.
      newline(base(depth: depth))
    case .quote, .alert:
      let accent: NSColor
      if let alert = block.alert {
        let symbols: [MarkdownAlert: String] = [
          .note: "ⓘ", .tip: "☀", .important: "◆", .warning: "⚠", .caution: "⛔",
        ]
        let names: [MarkdownAlert: String] = [
          .note: "NOT", .tip: "İPUCU", .important: "ÖNEMLİ", .warning: "UYARI", .caution: "DİKKAT",
        ]
        let label = preferences.language == .tr ? names[alert] ?? alert.rawValue : alert.rawValue
        accent = alertColor(alert)
        var titleAttributes = attributes
        titleAttributes[.foregroundColor] = accent
        titleAttributes[.font] = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
        output.append(
          NSAttributedString(
            string: "\(symbols[alert] ?? "ⓘ") \(label)\n", attributes: titleAttributes))
      } else {
        accent = .secondaryLabelColor
      }
      for child in block.children { append(child, depth: depth + 1) }
      if output.length > start {
        output.enumerateAttribute(
          .backgroundColor, in: NSRange(location: start, length: output.length - start)
        ) { value, range, _ in
          if value == nil {
            output.addAttribute(
              .backgroundColor, value: accent.withAlphaComponent(0.08), range: range)
          }
        }
      }
    case .list:
      for (index, item) in block.children.enumerated() {
        let marker =
          item.taskChecked.map { $0 ? "☑" : "☐" }
          ?? block.orderedStart.map { "\($0 + index)." } ?? "•"
        append(item, depth: depth, listMarker: marker)
      }
    case .listItem:
      for (index, child) in block.children.enumerated() {
        append(child, depth: depth + 1, listMarker: index == 0 ? listMarker : nil)
      }
    case .table:
      if let table = block.table { appendTable(table, blockID: block.id, depth: depth) }
    case .thematicBreak:
      attributes[.foregroundColor] = NSColor.separatorColor
      output.append(
        NSAttributedString(string: "────────────────────────\n", attributes: attributes))
    case .html:
      output.append(safeHTML(block.code ?? "", attributes: attributes))
      newline(attributes)
    }
    let range = NSRange(location: start, length: output.length - start)
    if range.length > 0 {
      if block.anchor != nil {
        output.addAttribute(.markupAnchor, value: block.anchor!, range: range)
      }
      rendered.append(RenderedBlock(id: block.id, range: range, kind: block.kind))
    }
  }

  private func appendTable(_ data: MarkdownTable, blockID: String, depth: Int) {
    let columns = data.rows.map(\.count).max() ?? 0
    guard columns > 0 else { return }
    let table = NSTextTable()
    table.numberOfColumns = columns
    table.layoutAlgorithm = .fixedLayoutAlgorithm
    table.collapsesBorders = true
    table.setValue(100, type: .percentageValueType, for: .width)
    for (rowIndex, row) in data.rows.enumerated() {
      for column in 0..<columns {
        let cell = NSTextTableBlock(
          table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
        cell.setValue(100 / Double(columns), type: .percentageValueType, for: .width)
        cell.setWidth(7 * preferences.zoom, type: .absoluteValueType, for: .padding)
        cell.setWidth(0.5, type: .absoluteValueType, for: .border)
        cell.setBorderColor(.separatorColor)
        if rowIndex < data.headerRowCount { cell.backgroundColor = .quaternaryLabelColor }
        var attributes = base(depth: depth)
        attributes[.markupBlockID] = blockID
        let paragraph = style()
        paragraph.textBlocks = [cell]
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = 0
        switch data.alignments.indices.contains(column) ? data.alignments[column] : .left {
        case .left: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }
        attributes[.paragraphStyle] = paragraph
        if rowIndex < data.headerRowCount {
          attributes[.font] = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
          attributes[.markupTableHeader] = true
        }
        if row.indices.contains(column) {
          output.append(inlines(row[column], attributes: attributes))
        }
        newline(attributes)
      }
    }
    newline(base(depth: depth))
  }

  private func inlines(_ values: [MarkdownInline], attributes: [NSAttributedString.Key: Any])
    -> NSAttributedString
  {
    let result = NSMutableAttributedString()
    var htmlAttributes = attributes
    for value in values {
      switch value {
      case .text(let text):
        result.append(NSAttributedString(string: text, attributes: htmlAttributes))
      case .code(let code):
        var attrs = htmlAttributes
        attrs[.font] = font(preferences.codeFont, size: bodyFont.pointSize * 0.9, mono: true)
        attrs[.foregroundColor] = NSColor(name: nil) { appearance in
          appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedRed: 1, green: 0.55, blue: 0.58, alpha: 1)
            : NSColor(calibratedRed: 0.72, green: 0.13, blue: 0.18, alpha: 1)
        }
        attrs[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.08)
        attrs[.markupInlineCode] = true
        result.append(NSAttributedString(string: code, attributes: attrs))
      case .emphasis(let children), .strong(let children):
        var attrs = htmlAttributes
        let font = attrs[.font] as? NSFont ?? bodyFont
        let trait: NSFontTraitMask
        if case .strong = value { trait = .boldFontMask } else { trait = .italicFontMask }
        attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: trait)
        result.append(inlines(children, attributes: attrs))
      case .strikethrough(let children):
        var attrs = htmlAttributes
        attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        result.append(inlines(children, attributes: attrs))
      case .link(let children, let destination):
        var attrs = htmlAttributes
        // No resources are fetched here. The text-view delegate validates user-activated destinations.
        attrs[.link] = destination
        attrs[.foregroundColor] = NSColor.linkColor
        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        result.append(inlines(children, attributes: attrs))
      case .image(let alt, let source):
        result.append(imagePlaceholder(alt: alt, source: source, attributes: htmlAttributes))
      case .softBreak: result.append(NSAttributedString(string: " ", attributes: htmlAttributes))
      case .hardBreak: result.append(NSAttributedString(string: "\n", attributes: htmlAttributes))
      case .html(let html):
        if !applySafeTag(html, current: &htmlAttributes, original: attributes) {
          result.append(safeHTML(html, attributes: htmlAttributes))
        }
      }
    }
    return result
  }

  private func imagePlaceholder(
    alt: String, source: String, attributes: [NSAttributedString.Key: Any]
  ) -> NSAttributedString {
    var attrs = attributes
    attrs[.markupImageSource] = source
    attrs[.markupImageAlt] = alt
    attrs[.foregroundColor] = NSColor.secondaryLabelColor
    let fallback = preferences.language == .tr ? "Görsel" : "Image"
    // TextKit recognizes attachments only on an object-replacement glyph. Keep that glyph
    // present before loading as well, so resource completion never shifts annotation indices.
    // The adjacent label remains available to selection, copying and accessibility.
    return NSAttributedString(
      string: "\u{FFFC}[\(alt.isEmpty ? fallback : alt)]", attributes: attrs)
  }

  /// Safe subset is rendered directly; unsupported tags remain visible source. No WebKit/HTML importer.
  private func safeHTML(_ html: String, attributes: [NSAttributedString.Key: Any])
    -> NSAttributedString
  {
    let result = NSMutableAttributedString()
    guard let tags = try? NSRegularExpression(pattern: #"<[^>]{0,4096}>"#) else {
      return NSAttributedString(string: html, attributes: attributes)
    }
    let source = html as NSString
    var current = attributes
    var cursor = 0
    for match in tags.matches(in: html, range: NSRange(location: 0, length: source.length)) {
      result.append(
        NSAttributedString(
          string: decodeEntities(
            source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
          ), attributes: current))
      let tag = source.substring(with: match.range)
      let lower = tag.lowercased()
      if lower.range(of: #"^<br\s*/?>$"#, options: .regularExpression) != nil {
        result.append(NSAttributedString(string: "\n", attributes: current))
      } else if lower.hasPrefix("<img "), let image = htmlImage(tag) {
        result.append(imagePlaceholder(alt: image.alt, source: image.source, attributes: current))
      } else if !applySafeTag(tag, current: &current, original: attributes) {
        result.append(NSAttributedString(string: tag, attributes: current))
      }
      cursor = NSMaxRange(match.range)
    }
    result.append(
      NSAttributedString(
        string: decodeEntities(source.substring(from: cursor)), attributes: current))
    return result
  }

  private func applySafeTag(
    _ tag: String, current: inout [NSAttributedString.Key: Any],
    original: [NSAttributedString.Key: Any]
  ) -> Bool {
    switch tag.lowercased() {
    case "<kbd>":
      current[.font] = codeFont
      current[.backgroundColor] = NSColor.quaternaryLabelColor
    case "<sub>":
      current[.baselineOffset] = -3 * preferences.zoom
      current[.font] = bodyFont.withSize(bodyFont.pointSize * 0.8)
    case "<sup>":
      current[.baselineOffset] = 6 * preferences.zoom
      current[.font] = bodyFont.withSize(bodyFont.pointSize * 0.8)
    case "<summary>":
      current[.font] = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
    // Expanded native fallback keeps every detail selectable.
    case "<details>", "<details open>": break
    case "</kbd>", "</sub>", "</sup>", "</summary>", "</details>": current = original
    default: return false
    }
    return true
  }

  private func htmlImage(_ tag: String) -> (alt: String, source: String)? {
    guard
      let regex = try? NSRegularExpression(
        pattern: #"(?i)\b(src|alt)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#)
    else { return nil }
    let ns = tag as NSString
    var attributes: [String: String] = [:]
    for match in regex.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
      let key = ns.substring(with: match.range(at: 1)).lowercased()
      for index in 2...4 where match.range(at: index).location != NSNotFound {
        attributes[key] = decodeEntities(ns.substring(with: match.range(at: index)))
      }
    }
    guard let source = attributes["src"], !source.isEmpty else { return nil }
    return (attributes["alt"] ?? "", source)
  }

  private func decodeEntities(_ value: String) -> String {
    value.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&amp;", with: "&")
  }

  private func newline(_ attributes: [NSAttributedString.Key: Any]) {
    output.append(NSAttributedString(string: "\n", attributes: attributes))
  }

  private func color(_ hex: String) -> NSColor {
    let raw = UInt32(hex.dropFirst(), radix: 16) ?? 0
    return NSColor(
      srgbRed: Double((raw >> 16) & 255) / 255, green: Double((raw >> 8) & 255) / 255,
      blue: Double(raw & 255) / 255, alpha: 1)
  }

  private func alertColor(_ alert: MarkdownAlert) -> NSColor {
    switch alert {
    case .note: .systemBlue
    case .tip: .systemGreen
    case .important: .systemPurple
    case .warning: .systemOrange
    case .caution: .systemRed
    }
  }
}
