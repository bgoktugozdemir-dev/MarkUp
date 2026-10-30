import AppKit
import CoreText
import Foundation
import MarkUpCore
import PDFKit
import Testing

@testable import MarkUp

@MainActor
struct RenderingTests {
  @Test func nativeFlowPreservesSelectableProseCodeAndTables() async throws {
    let document = try await MarkdownParser().parse(
      """
      # A heading

      Prose **strong** and `inline`.

      ```swift
      let value = "original source"
      ```

      | Left | Right |
      |:-----|------:|
      | **bold** | ![one](one.png) ![two](two.png) |
      """)
    let rendered = NativeMarkdownRenderer().render(
      document: document, preferences: ReaderPreferences(), tokens: [:])
    let text = rendered.attributedString
    #expect(text.string.contains("Prose strong and inline."))
    #expect(text.string.contains("let value = \"original source\""))
    #expect(rendered.blocks.contains { $0.kind == .table })
    var tables = 0
    var images = 0
    text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) {
      value, _, _ in
      if (value as? NSParagraphStyle)?.textBlocks.first is NSTextTableBlock { tables += 1 }
    }
    text.enumerateAttribute(.markupImageSource, in: NSRange(location: 0, length: text.length)) {
      value, _, _ in
      if value is String { images += 1 }
    }
    #expect(tables >= 4)
    #expect(images == 2)
    #expect(!text.string.contains("Copy code"))
  }

  @Test func htmlSubsetNeverImportsOrExecutesHTML() async throws {
    let document = try await MarkdownParser().parse(
      """
      Press <kbd>Return</kbd>, H<sub>2</sub>O and x<sup>2</sup>.<br>Next line.

      <details><summary>More</summary>Expanded content.</details>

      <script src="https://example.org/no-request.js">doNotExecute()</script>
      """)
    let rendered = NativeMarkdownRenderer().render(
      document: document, preferences: ReaderPreferences(), tokens: [:])
    let text = rendered.attributedString.string
    #expect(text.contains("Press Return, H2O and x2.\nNext line."))
    #expect(text.contains("MoreExpanded content."))
    #expect(text.contains("<script src="))
    #expect(text.contains("doNotExecute()"))
  }

  @Test func unicodeCodeAndDocumentEndSurviveMultiPagePDF() async throws {
    let source =
      "# PDF validation\n\n日本語 Türkçe café 😀\n\n"
      + (0..<60).map { index in
        "## Section \(index)\n\nA selectable **paragraph**.\n\n```swift\nlet number = \(index)\n```\n\n| A | B |\n|---|---|\n| one | two |\n\n"
      }.joined() + "DOCUMENT-END-VERIFIED\n"
    let document = try await MarkdownParser().parse(source)
    let rendered = NativeMarkdownRenderer().render(
      document: document, preferences: ReaderPreferences(), tokens: [:])
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".pdf")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try await PDFExporter().export(rendered: rendered, to: temporary, options: PDFOptions())
    let pdf = try #require(PDFDocument(url: temporary))
    let extracted = try #require(pdf.string)
    #expect(pdf.pageCount > 1)
    #expect(extracted.contains("日本語"))
    #expect(extracted.contains("Türkçe"))
    #expect(extracted.contains("let number = 59"))
    #expect(extracted.contains("DOCUMENT-END-VERIFIED"))
    #expect(pdf.outlineRoot?.numberOfChildren == 61)
    let headings = Set(document.headings.map(\.title))
    for index in 0..<pdf.pageCount {
      let lastLine =
        (pdf.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: "\n").last ?? ""
      #expect(!headings.contains(lastLine), "A heading should remain with following content")
    }
  }

  @Test func longCodeWrapsOnExportAndLetterLandscapeIsCorrect() async throws {
    let code = "let " + String(repeating: "longIdentifier", count: 100) + " = 1\nCODE-END"
    let document = try await MarkdownParser().parse("```swift\n" + code + "\n```")
    var preferences = ReaderPreferences()
    preferences.wrapCode = false
    let rendered = NativeMarkdownRenderer().render(
      document: document, preferences: preferences, tokens: [:])
    var options = PDFOptions()
    options.paper = .letter
    options.landscape = true
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".pdf")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try await PDFExporter().export(rendered: rendered, to: temporary, options: options)
    let pdf = try #require(PDFDocument(url: temporary))
    #expect(pdf.string?.contains("CODE-END") == true)
    #expect(pdf.page(at: 0)?.bounds(for: .mediaBox).size == NSSize(width: 792, height: 612))
  }

  @Test func invalidExportLeavesExistingDestinationUntouched() async throws {
    let document = try await MarkdownParser().parse("Content")
    let rendered = NativeMarkdownRenderer().render(
      document: document, preferences: ReaderPreferences(), tokens: [:])
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".pdf")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let original = Data("existing content".utf8)
    try original.write(to: temporary)
    var options = PDFOptions()
    options.margin = .nan
    await #expect(throws: PDFExportError.self) {
      try await PDFExporter().export(rendered: rendered, to: temporary, options: options)
    }
    #expect(try Data(contentsOf: temporary) == original)
  }

  @Test func tallTableRowsFlowAcrossPagesWithRepeatedColumnMeaning() async throws {
    let source =
      "| Description | Status |\n|---|---|\n| "
      + String(repeating: "Long cell content ", count: 1500)
      + "ROW-END | done |\n\nTABLE-END"
    let document = try await MarkdownParser().parse(source)
    let rendered = NativeMarkdownRenderer().render(
      document: document, preferences: ReaderPreferences(), tokens: [:])
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".pdf")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try await PDFExporter().export(rendered: rendered, to: temporary, options: PDFOptions())
    let pdf = try #require(PDFDocument(url: temporary))
    #expect(pdf.pageCount > 1)
    #expect(pdf.string?.contains("ROW-END") == true)
    #expect(pdf.string?.contains("Status: done") == true)
    #expect(pdf.string?.contains("TABLE-END") == true)
    #expect(pdf.page(at: 1)?.string?.contains("Description") == true)
  }

  @Test func exportPreparationPreservesImagesSyntaxAndAnnotationPrivacyAtUnitZoom() async throws {
    let document = try await MarkdownParser().parse(
      "Visible words. ![asset](local.png)\n\n```swift\nlet answer = 42\n```")
    let code = try #require(document.blocks.first { $0.kind == .code })
    let tokens = [code.id: [SyntaxToken(range: NSRange(location: 0, length: 3), kind: "keyword")]]
    var preferences = ReaderPreferences()
    preferences.zoom = 2
    preferences.codeThemeID = "one-dark"
    let rendered = NativeMarkdownRenderer().render(
      document: document, preferences: preferences, tokens: tokens)
    let screen = NSMutableAttributedString(attributedString: rendered.attributedString)
    let imageRange = (screen.string as NSString).range(of: "\u{FFFC}[asset]")
    let attachment = NSTextAttachment()
    let image = NSImage(size: NSSize(width: 40, height: 20))
    attachment.image = image
    screen.addAttribute(
      .attachment, value: attachment, range: NSRange(location: imageRange.location, length: 1))
    let range = (screen.string as NSString).range(of: "Visible words.")
    let annotation = TextAnnotation(
      documentID: UUID(), anchor: try TextAnchor.capture(in: screen.string, range: range),
      style: .highlightYellow)
    let current = RenderedDocument(attributedString: screen, blocks: rendered.blocks)
    let plain = PDFContentPreparation.prepare(
      document: document, current: current, preferences: preferences,
      tokens: tokens, annotations: [annotation], resolved: [annotation.id: range],
      options: PDFOptions())
    #expect(
      plain.attributedString.attribute(.attachment, at: imageRange.location, effectiveRange: nil)
        is NSTextAttachment)
    #expect(
      plain.attributedString.attribute(.backgroundColor, at: range.location, effectiveRange: nil)
        == nil)
    #expect(
      (plain.attributedString.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)?
        .pointSize == CGFloat(preferences.bodySize))
    let codeRange = (plain.attributedString.string as NSString).range(of: "let answer")
    let keywordColor =
      plain.attributedString.attribute(
        .foregroundColor, at: codeRange.location, effectiveRange: nil) as? NSColor
    let proseColor =
      plain.attributedString.attribute(.foregroundColor, at: range.location, effectiveRange: nil)
      as? NSColor
    #expect(keywordColor != proseColor)
    var markedOptions = PDFOptions()
    markedOptions.includeAnnotations = true
    markedOptions.currentAppearance = true
    let marked = PDFContentPreparation.prepare(
      document: document, current: current, preferences: preferences,
      tokens: tokens, annotations: [annotation], resolved: [annotation.id: range],
      options: markedOptions)
    #expect(
      marked.attributedString.attribute(.backgroundColor, at: range.location, effectiveRange: nil)
        is NSColor)
    #expect(
      (marked.attributedString.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)?
        .pointSize == CGFloat(preferences.bodySize))
  }

  @Test func automaticCodeThemePairsToExplicitAppearanceAndRespectsOptOut() async throws {
    let document = try await MarkdownParser().parse("```swift\nlet value = 1\n```")
    var preferences = ReaderPreferences()
    preferences.codeThemeID = "github-light"
    preferences.appearance = .dark
    preferences.automaticTheme = true
    let dark = NativeMarkdownRenderer().render(
      document: document, preferences: preferences, tokens: [:])
    preferences.appearance = .light
    let light = NativeMarkdownRenderer().render(
      document: document, preferences: preferences, tokens: [:])
    preferences.appearance = .dark
    preferences.automaticTheme = false
    let fixed = NativeMarkdownRenderer().render(
      document: document, preferences: preferences, tokens: [:])
    let darkColor =
      dark.attributedString.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
    let lightColor =
      light.attributedString.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
    let fixedColor =
      fixed.attributedString.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
    #expect(darkColor != lightColor)
    #expect(fixedColor == lightColor)
  }

  @Test func stableImageMarkersBecomeRealNativeAttachmentGlyphsAndPDFImages() async throws {
    let document = try await MarkdownParser().parse(
      "![Native red sample](sample.png)\n\n<img src=\"sample.png\" alt=\"HTML sample\">\n")
    let unloaded = NativeMarkdownRenderer().render(
      document: document, preferences: ReaderPreferences(), tokens: [:])
    let canonical = unloaded.attributedString.string
    let loaded = NSMutableAttributedString(attributedString: unloaded.attributedString)
    var markers: [Int] = []
    let image = NSImage(size: NSSize(width: 40, height: 20))
    image.lockFocus()
    NSColor.red.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 40, height: 20)).fill()
    image.unlockFocus()
    loaded.enumerateAttribute(.markupImageSource, in: NSRange(location: 0, length: loaded.length)) {
      value, range, _ in
      guard value is String else { return }
      #expect((canonical as NSString).character(at: range.location) == 0xFFFC)
      markers.append(range.location)
      let attachment = NSTextAttachment()
      attachment.image = image
      loaded.addAttribute(
        .attachment, value: attachment, range: NSRange(location: range.location, length: 1))
    }
    #expect(markers.count == 2)
    #expect(loaded.string == canonical)
    #expect(
      canonical.replacingOccurrences(of: "\u{FFFC}", with: "").contains("[Native red sample]"))
    let storage = NSTextStorage(attributedString: loaded)
    let manager = NSLayoutManager()
    let container = NSTextContainer(containerSize: NSSize(width: 500, height: 1000))
    storage.addLayoutManager(manager)
    manager.addTextContainer(container)
    manager.ensureLayout(for: container)
    for marker in markers {
      let glyph = manager.glyphIndexForCharacter(at: marker)
      #expect(manager.attachmentSize(forGlyphAt: glyph) == NSSize(width: 40, height: 20))
    }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".pdf")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try await PDFExporter().export(
      rendered: RenderedDocument(attributedString: loaded, blocks: unloaded.blocks), to: temporary,
      options: PDFOptions())
    let pdf = try #require(PDFDocument(url: temporary))
    let page = try #require(pdf.page(at: 0)?.pageRef)
    let width = 600
    let height = 850
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    pixels.withUnsafeMutableBytes { bytes in
      let context = CGContext(
        data: bytes.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.setFillColor(NSColor.white.cgColor)
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.drawPDFPage(page)
    }
    var redPixels = 0
    for offset in stride(from: 0, to: pixels.count, by: 4) {
      if pixels[offset] > 200 && pixels[offset + 1] < 60 && pixels[offset + 2] < 60 {
        redPixels += 1
      }
    }
    #expect(
      redPixels >= 1200,
      "The exported PDF must contain both actual red images, not only attachment metadata or alt labels"
    )
    #expect(pdf.string?.contains("Native red sample") == true)
  }

  @Test(arguments: [AppLanguage.en, .tr])
  func englishAndTurkishShapingPreservesMixedLatinTextAndSourceAttributes(language: AppLanguage)
    async throws
  {
    let source =
      "# Mixed Latin i İ ı\n\nASCII i — dotted İ — dotless ı. i İ ı\n\n| Description i İ ı | Value |\n|---|---|\n| Native i İ ı | source |\n\nMIXED-LATIN-END"
    let document = try await MarkdownParser().parse(source)
    var preferences = ReaderPreferences()
    preferences.language = language
    let rendered = NativeMarkdownRenderer().render(
      document: document, preferences: preferences, tokens: [:])
    let marked = NSMutableAttributedString(attributedString: rendered.attributedString)
    let shapingLanguage = NSAttributedString.Key(kCTLanguageAttributeName as String)
    marked.addAttribute(
      shapingLanguage, value: language.rawValue, range: NSRange(location: 0, length: marked.length))
    let original = NSAttributedString(attributedString: marked)
    let sourceFont = try #require(marked.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    let originalFontName = sourceFont.fontName
    let originalFontSize = sourceFont.pointSize
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".pdf")
    defer { try? FileManager.default.removeItem(at: destination) }
    try await PDFExporter().export(
      rendered: RenderedDocument(attributedString: marked, blocks: rendered.blocks),
      to: destination, options: PDFOptions())
    let pdf = try #require(PDFDocument(url: destination))
    let extracted = try #require(pdf.string)
    #expect(extracted.contains("Mixed Latin i İ ı"))
    #expect(extracted.contains("ASCII i — dotted İ — dotless ı. i İ ı"))
    #expect(extracted.contains("Description i İ ı"))
    #expect(extracted.contains("Native i İ ı"))
    #expect(extracted.contains("MIXED-LATIN-END"))
    #expect(marked.isEqual(to: original))
    #expect(
      marked.attribute(shapingLanguage, at: 0, effectiveRange: nil) as? String == language.rawValue)
    #expect(
      (marked.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontName == originalFontName
    )
    #expect(
      (marked.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
        == originalFontSize)
    #expect(document.source == source)
  }

  @Test func repeatedRendererPreservesDistinctFontRolesAndAppliesChangedTypography() async throws {
    let document = try await MarkdownParser().parse(
      "# Heading sample\n\nBody sample.\n\n```swift\nlet code = 1\n```")
    let renderer = NativeMarkdownRenderer()
    var preferences = ReaderPreferences()
    preferences.bodyFont = "System"
    preferences.headingFont = "System"
    preferences.codeFont = "System"
    preferences.bodySize = 16
    preferences.codeSize = 16
    preferences.headingSizes[0] = 16
    preferences.bodyWeight = .regular
    preferences.headingWeight = .bold
    let first = renderer.render(document: document, preferences: preferences, tokens: [:])
    func font(in result: RenderedDocument, at text: String) throws -> NSFont {
      let range = (result.attributedString.string as NSString).range(of: text)
      #expect(range.location != NSNotFound)
      return try #require(
        result.attributedString.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
      )
    }
    let firstBody = try font(in: first, at: "Body sample")
    let firstCode = try font(in: first, at: "let code")
    let firstHeading = try font(in: first, at: "Heading sample")
    #expect(firstBody.pointSize == 16 && firstCode.pointSize == 16 && firstHeading.pointSize == 16)
    #expect(!firstBody.fontDescriptor.symbolicTraits.contains(.monoSpace))
    #expect(firstCode.fontDescriptor.symbolicTraits.contains(.monoSpace))
    #expect(!firstBody.fontDescriptor.symbolicTraits.contains(.bold))
    #expect(firstHeading.fontDescriptor.symbolicTraits.contains(.bold))
    preferences.bodySize = 20
    preferences.codeSize = 12
    preferences.headingSizes[0] = 24
    preferences.zoom = 1.5
    preferences.bodyWeight = .bold
    preferences.headingWeight = .regular
    let second = renderer.render(document: document, preferences: preferences, tokens: [:])
    let secondBody = try font(in: second, at: "Body sample")
    let secondCode = try font(in: second, at: "let code")
    let secondHeading = try font(in: second, at: "Heading sample")
    #expect(secondBody.pointSize == 30)
    #expect(secondCode.pointSize == 18)
    #expect(secondHeading.pointSize == 36)
    #expect(secondBody.fontDescriptor.symbolicTraits.contains(.bold))
    #expect(!secondHeading.fontDescriptor.symbolicTraits.contains(.bold))
    #expect(secondCode.fontDescriptor.symbolicTraits.contains(.monoSpace))
    #expect(second.attributedString.string == first.attributedString.string)
    #expect(second.blocks.map(\.id) == first.blocks.map(\.id))
  }
}
