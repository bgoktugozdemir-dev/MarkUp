import AppKit
import MarkUpCore
import Testing

@testable import MarkUp

@MainActor
struct CodeBlockControlsTests {
  private struct Reader {
    let view: ReaderTextView
    let layout: CodeLayoutManager
    let container: CodeTextContainer
    let controls: CodeBlockController
    let rendered: RenderedDocument
    let window: NSWindow
  }

  private func reader(_ source: String, codeSize: Double = 13) async throws -> Reader {
    let document = try await MarkdownParser().parse(source)
    var preferences = ReaderPreferences()
    preferences.wrapCode = false
    preferences.lineNumbers = false
    preferences.codeSize = codeSize
    let rendered = NativeMarkdownRenderer().render(
      document: document, preferences: preferences, tokens: [:])
    let storage = NSTextStorage()
    let layout = CodeLayoutManager()
    layout.backgroundLayoutEnabled = false
    storage.addLayoutManager(layout)
    let container = CodeTextContainer(size: NSSize(width: 360, height: 100_000))
    container.lineFragmentPadding = 0
    layout.addTextContainer(container)
    let view = ReaderTextView(
      frame: CGRect(x: 0, y: 0, width: 424, height: 700), textContainer: container)
    view.isEditable = false
    view.isSelectable = true
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.textContainerInset = NSSize(width: 32, height: 60)
    container.widthTracksTextView = false
    let window = NSWindow(
      contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: view.frame)
    scroll.hasVerticalScroller = true
    scroll.documentView = view
    window.contentView = scroll
    window.makeFirstResponder(view)
    let controls = CodeBlockController(textView: view)
    view.codeControls = controls
    container.codeControls = controls
    layout.codeControls = controls
    let display = NSMutableAttributedString(attributedString: rendered.attributedString)
    controls.prepare(display, rendered: rendered, document: document, preferences: preferences)
    storage.setAttributedString(display)
    view.fitDocument()
    controls.updateFrames()
    return Reader(
      view: view, layout: layout, container: container, controls: controls, rendered: rendered,
      window: window)
  }

  @Test func horizontalCodeUsesNativeHitTestingAndContinuousCopy() async throws {
    let code =
      "let example = \"" + String(repeating: "native_selection_", count: 24)
      + "\"\nprint(example)\n"
    let reader = try await reader(
      "Before the code block.\n\n```swift\n" + code + "```\n\nAfter the code block.\n")
    defer { reader.window.close() }
    let record = try #require(reader.controls.records.first)
    #expect(record.original == code)
    #expect(record.contentWidth > reader.container.size.width)
    reader.controls.setScroll(record.id, fraction: 0.5)
    #expect(reader.view.textContainerOrigin.x == reader.view.textContainerInset.width)
    let glyph = reader.layout.glyphIndexForCharacter(at: record.range.location)
    let fragment = reader.layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    #expect(fragment.minX < 0)
    let hit = reader.layout.characterIndex(
      for: CGPoint(x: record.gutter + 5, y: fragment.midY),
      in: reader.container, fractionOfDistanceBetweenInsertionPoints: nil)
    #expect(hit > record.range.location + 10)
    let canonical = reader.view.string as NSString
    let start = canonical.range(of: "Before").location
    let end = canonical.range(of: "After").location + 5
    let selection = NSRange(location: start, length: end - start)
    reader.view.setSelectedRange(selection)
    let pasteboard = NSPasteboard.withUniqueName()
    #expect(reader.view.writeSelection(to: pasteboard, types: reader.view.writablePasteboardTypes))
    #expect(pasteboard.string(forType: .string) == canonical.substring(with: selection))
    let unwrappedHeight = record.frame.height
    let measured = reader.controls.geometryMeasurementCount
    for _ in 0..<20 { reader.controls.updateFrames() }
    reader.controls.setScroll(record.id, fraction: 0.75)
    #expect(reader.controls.geometryMeasurementCount == measured)
    reader.controls.toggleWrap(record.id, enabled: true)
    #expect(reader.controls.geometryMeasurementCount > measured)
    #expect(record.frame.height > unwrappedHeight)
    #expect(reader.view.selectedRange() == selection)
    reader.controls.toggleNumbers(record.id, enabled: true)
    #expect(record.gutter >= 42)
    #expect(reader.view.string == reader.rendered.attributedString.string)
    #expect(record.headerFrame.minY >= 0)
  }

  @Test func tabsDoNotForceUnwrappedCodeToWrap() async throws {
    let code = String(repeating: "\t", count: 100) + "END\n"
    let reader = try await reader("```swift\n" + code + "```", codeSize: 8)
    defer { reader.window.close() }
    let record = try #require(reader.controls.records.first)
    let first = reader.layout.glyphIndexForCharacter(at: record.range.location)
    let last = reader.layout.glyphIndexForCharacter(at: record.range.location + 100)
    #expect(
      reader.layout.lineFragmentRect(forGlyphAt: first, effectiveRange: nil).minY
        == reader.layout.lineFragmentRect(forGlyphAt: last, effectiveRange: nil).minY)
    #expect(record.contentWidth > reader.container.size.width)
    reader.controls.setScroll(record.id, fraction: 1)
    let endFragment = reader.layout.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
    let endX = endFragment.minX + reader.layout.location(forGlyphAt: last).x
    #expect(endX >= record.gutter && endX < reader.container.size.width)
  }

  @Test func tableScrollUsesOneTextStorageAndDoesNotMutateExportTables() async throws {
    let source =
      "Before.\n\n| A | B | C | D | E | HEADER-F |\n|---|---|---|---|---|---|\n| one | two | three | four | five | six |\n\nAfter."
    let reader = try await reader(source)
    defer { reader.window.close() }
    let record = try #require(reader.controls.records.first { $0.kind == .table })
    #expect(record.contentWidth >= 960)
    reader.controls.setScroll(record.id, fraction: 1)
    let finalCell = (reader.view.string as NSString).range(of: "HEADER-F").location
    let glyph = reader.layout.glyphIndexForCharacter(at: finalCell)
    let fragment = reader.layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    let x = fragment.minX + reader.layout.location(forGlyphAt: glyph).x
    #expect(x >= 0 && x < reader.container.size.width)
    #expect(reader.view.string == reader.rendered.attributedString.string)
    let originalStyle =
      reader.rendered.attributedString.attribute(
        .paragraphStyle, at: record.range.location, effectiveRange: nil) as? NSParagraphStyle
    let displayStyle =
      reader.view.textStorage?.attribute(
        .paragraphStyle, at: record.range.location, effectiveRange: nil) as? NSParagraphStyle
    let original = try #require(originalStyle?.textBlocks.first as? NSTextTableBlock)
    let display = try #require(displayStyle?.textBlocks.first as? NSTextTableBlock)
    #expect(original.table !== display.table)
    reader.container.size.width = 1200
    reader.controls.containerDidResize()
    reader.view.sizeToFit()
    reader.controls.updateFrames()
    #expect(record.offset == 0)
    #expect(record.contentWidth >= 1200)
  }

  @Test func plainCopyKeepsImageAltAndOmitsOnlyImageObjectMarkers() async throws {
    let reader = try await reader("An image ![accessible label](missing.png) and code `\u{FFFC}`.")
    defer { reader.window.close() }
    reader.view.setSelectedRange(NSRange(location: 0, length: reader.view.string.utf16.count))
    let pasteboard = NSPasteboard.withUniqueName()
    #expect(reader.view.writeSelection(to: pasteboard, types: reader.view.writablePasteboardTypes))
    let copied = try #require(pasteboard.string(forType: .string))
    #expect(copied.contains("[accessible label]"))
    // Literal inline-code marker is preserved.
    #expect(copied.filter { $0 == "\u{FFFC}" }.count == 1)
  }

  @Test func narrowCodeHeaderUsesNonoverlappingOptionsMenu() async throws {
    let reader = try await reader("```swift\nlet value = 1\n```")
    defer { reader.window.close() }
    reader.container.size.width = 180
    reader.controls.containerDidResize()
    reader.view.sizeToFit()
    reader.controls.updateFrames()
    let header = try #require(
      reader.view.subviews.first { $0.subviews.contains { ($0 as? NSButton)?.title == "…" } })
    #expect(header.frame.width == 180)
    header.layoutSubtreeIfNeeded()
    let visible = header.subviews.filter { !$0.isHidden }
    let buttons = visible.compactMap { $0 as? NSButton }
    #expect(buttons.count == 2)  // Original-source Copy and the keyboard-accessible options menu.
    #expect(buttons.contains { $0.title == "…" && $0.action != nil })
    for (index, view) in visible.enumerated() {
      #expect(header.bounds.contains(view.frame))
      for other in visible.dropFirst(index + 1) { #expect(!view.frame.intersects(other.frame)) }
    }
  }

  @Test func codeHeaderTracksAppearanceAndFitsLocalizedLabels() async throws {
    let reader = try await reader("```swift\nlet value = 1\n```")
    defer { reader.window.close() }
    let header = try #require(
      reader.view.subviews.first { $0.subviews.contains { ($0 as? NSButton)?.title == "…" } })
    header.appearance = NSAppearance(named: .darkAqua)
    header.viewDidChangeEffectiveAppearance()
    let dark = try #require(header.layer?.backgroundColor)
    header.appearance = NSAppearance(named: .aqua)
    header.viewDidChangeEffectiveAppearance()
    let light = try #require(header.layer?.backgroundColor)
    #expect(dark != light)
    let checkboxes = header.subviews.compactMap { $0 as? NSButton }.filter {
      $0.title == localized("Wrap") || $0.title == localized("Lines")
    }
    #expect(checkboxes.count == 2)
    for checkbox in checkboxes { checkbox.title = "Satır numaraları" }
    header.frame.size.width = 600
    header.needsLayout = true
    header.layoutSubtreeIfNeeded()
    for checkbox in checkboxes {
      #expect(!checkbox.isHidden)
      #expect(checkbox.frame.width >= checkbox.fittingSize.width)
    }
  }

  @Test func textAccessibilityIncludesVisibleNativeCodeControls() async throws {
    let reader = try await reader("```swift\n" + String(repeating: "source", count: 100) + "\n```")
    defer { reader.window.close() }
    let children = reader.view.accessibilityChildren() ?? []
    let buttons = children.compactMap { $0 as? NSButton }
    #expect(buttons.contains { $0.title == localized("Copy") })
    #expect(buttons.contains { $0.title == localized("Wrap") })
    #expect(buttons.contains { $0.title == localized("Lines") })
    let copy = try #require(buttons.first { $0.title == localized("Copy") })
    let wrap = try #require(buttons.first { $0.title == localized("Wrap") })
    let scroller = try #require(children.compactMap { $0 as? NSScroller }.first)
    #expect(copy.accessibilityRole() == .button)
    #expect(copy.isAccessibilitySelectorAllowed(NSSelectorFromString("accessibilityPerformPress")))
    #expect(wrap.accessibilityRole() == .checkBox)
    #expect((wrap.accessibilityValue() as? NSNumber)?.intValue == 0)
    #expect(scroller.accessibilityRole() == .scrollBar)
    #expect(scroller.accessibilityPerformIncrement())
    #expect((scroller.accessibilityValue() as? NSNumber)?.doubleValue ?? 0 > 0)
    #expect(wrap.accessibilityPerformPress())
    #expect((wrap.accessibilityValue() as? NSNumber)?.intValue == 1)
    #expect(reader.controls.records.first?.wrap == true)
    #expect(wrap.accessibilityPerformPress())
    #expect(reader.controls.records.first?.wrap == false)
    #expect(children.compactMap { $0 as? NSTextField }.first?.accessibilityRole() == .staticText)
    reader.container.size.width = 180
    reader.controls.containerDidResize()
    reader.view.fitDocument()
    reader.controls.updateFrames()
    let compact = (reader.view.accessibilityChildren() ?? []).compactMap { $0 as? NSButton }
    #expect(compact.count == 2)
    #expect(compact.contains { $0.title == localized("Copy") })
    #expect(compact.contains { $0.title == "…" && $0.action != nil })
    #expect(compact.allSatisfy { $0.accessibilityRole() == .button })
    #expect(
      compact.allSatisfy {
        $0.isAccessibilitySelectorAllowed(NSSelectorFromString("accessibilityPerformPress"))
      })
    #expect(!compact.contains { $0.isHidden })
  }
}
