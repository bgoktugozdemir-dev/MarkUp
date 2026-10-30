import AppKit
import MarkUpCore

@MainActor
enum PDFContentPreparation {
  static func prepare(
    document: MarkdownDocument, current: RenderedDocument, preferences: ReaderPreferences,
    tokens: [String: [SyntaxToken]], annotations: [TextAnnotation],
    resolved: [UUID: NSRange], options: PDFOptions
  ) -> RenderedDocument {
    var exportPreferences = preferences
    exportPreferences.zoom = 1
    exportPreferences.wrapCode = true
    if !options.currentAppearance {
      exportPreferences.appearance = .light
      exportPreferences.codeThemeID = "github-light"
      exportPreferences.automaticTheme = false
    }
    let fresh = NativeMarkdownRenderer().render(
      document: document, preferences: exportPreferences, tokens: tokens)
    let text = NSMutableAttributedString(attributedString: fresh.attributedString)
    // Screen zoom and resource loading never change canonical text. Transfer only resource
    // attachments, never selection/search overlays or screen annotation presentation.
    let sameText = current.attributedString.string == text.string
    if sameText {
      current.attributedString.enumerateAttribute(
        .attachment, in: NSRange(location: 0, length: current.attributedString.length)
      ) { value, range, _ in
        guard let attachment = value as? NSTextAttachment, valid(range, length: text.length) else {
          return
        }
        text.addAttribute(.attachment, value: attachment, range: range)
      }
    }
    if options.includeAnnotations, sameText {
      let source = text.string as NSString
      for annotation in annotations {
        guard let range = resolved[annotation.id], valid(range, length: text.length),
          source.substring(with: range) == annotation.anchor.exactText,
          source.rangeOfComposedCharacterSequences(for: range) == range
        else { continue }
        if annotation.style == .underline {
          text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        } else {
          let color: NSColor =
            switch annotation.style {
            case .highlightGreen: .systemGreen
            case .highlightBlue: .systemBlue
            default: .systemYellow
            }
          text.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.3), range: range)
        }
      }
    }
    return RenderedDocument(attributedString: text, blocks: fresh.blocks)
  }

  private static func valid(_ range: NSRange, length: Int) -> Bool {
    range.location >= 0 && range.length > 0 && range.location <= length
      && range.length <= length - range.location
  }
}
