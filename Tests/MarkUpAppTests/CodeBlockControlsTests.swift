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
    let document: MarkdownDocument
    let preferences: ReaderPreferences
    let window: NSWindow
  }

  private func reader(_ source: String, codeSize: Double = 13) async throws -> Reader {
    let document = try await MarkdownParser().parse(source)
    var preferences = ReaderPreferences()
    preferences.wrapCode = false
    preferences.lineNumbers = false
    preferences.codeSize = codeSize
    preferences.limitCodeHeight = true
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
      document: document, preferences: preferences, window: window)
  }

  @Test func codePanelsDoNotOverlapAdjacentParagraphs() async throws {
    for lineCount in [3, 25] {
      let code = (0..<lineCount).map { "let value\($0) = \($0)\n" }.joined()
      for separator in ["\n", "\n\n"] {
        let reader = try await reader("Before." + separator + "```swift\n" + code + "```\nAfter.")
        defer { reader.window.close() }
        let record = try #require(reader.controls.records.first)
        let source = reader.view.string as NSString
        let origin = reader.view.textContainerOrigin
        for (label, before) in [("Before.", true), ("After.", false)] {
          let characters = source.range(of: label)
          let glyphs = reader.layout.glyphRange(
            forCharacterRange: characters, actualCharacterRange: nil)
          let bounds = reader.layout.boundingRect(forGlyphRange: glyphs, in: reader.container)
            .offsetBy(dx: origin.x, dy: origin.y)
          if before {
            #expect(bounds.maxY <= record.panelFrame.minY)
          } else {
            #expect(bounds.minY >= record.panelFrame.maxY)
          }
        }
      }
    }
  }

  @Test func codePanelsDoNotOverlapHardBreaksOrEachOther() async throws {
    let code = (0..<25).map { "let value\($0) = \($0)\n" }.joined()
    let source =
      "### Heading\n\nFile: `path/to/file.swift`  \n(Details)  \nBefore.\n```swift\n"
      + code + "```\nAfter.\n```swift\n" + code + "```\nEnd."
    let reader = try await reader(source)
    defer { reader.window.close() }
    #expect(reader.controls.records.count == 2)
    let text = reader.view.string as NSString
    let origin = reader.view.textContainerOrigin
    for (index, label) in ["Before.", "After."].enumerated() {
      let glyphs = reader.layout.glyphRange(
        forCharacterRange: text.range(of: label), actualCharacterRange: nil)
      let bounds = reader.layout.boundingRect(forGlyphRange: glyphs, in: reader.container)
        .offsetBy(dx: origin.x, dy: origin.y)
      #expect(
        bounds.maxY <= reader.controls.records[index].panelFrame.minY,
        "Panel \(index), embedded: \(reader.controls.records[index].embedded), bounds: \(bounds), panel: \(reader.controls.records[index].panelFrame)"
      )
      if index > 0 { #expect(bounds.minY >= reader.controls.records[index - 1].panelFrame.maxY) }
    }
  }

  @Test(arguments: [1, 12, 50])
  func configuredRowLimitControlsFoldAndViewport(rows: Int) async throws {
    let reader = try await reader("```swift\n" + String(repeating: "value\n", count: 60) + "```")
    defer { reader.window.close() }
    var preferences = reader.preferences
    preferences.codeBlockVisibleRows = rows
    let display = NSMutableAttributedString(attributedString: reader.rendered.attributedString)
    reader.controls.prepare(
      display, rendered: reader.rendered, document: reader.document, preferences: preferences)
    reader.view.textStorage?.setAttributedString(display)
    reader.view.fitDocument()
    reader.controls.updateFrames()
    let record = try #require(reader.controls.records.first)
    #expect(record.embedded)
    #expect(record.limitedRows == rows)
    #expect(abs(record.viewportHeight - record.rowPitch * CGFloat(rows)) < 0.01)
    #expect(record.rowPitch > 1 && record.rowPitch < 40)
  }

  @Test(arguments: [1, 12, 50])
  func blocksFoldOnlyWhenTheyExceedTheConfiguredLimit(rows: Int) async throws {
    for extra in [0, 1] {
      let reader = try await reader(
        "```swift\n" + String(repeating: "value\n", count: rows + extra) + "```")
      defer { reader.window.close() }
      var preferences = reader.preferences
      preferences.codeBlockVisibleRows = rows
      let display = NSMutableAttributedString(attributedString: reader.rendered.attributedString)
      reader.controls.prepare(
        display, rendered: reader.rendered, document: reader.document, preferences: preferences)
      reader.view.textStorage?.setAttributedString(display)
      reader.view.fitDocument()
      reader.controls.updateFrames()
      #expect(reader.controls.records.first?.embedded == (extra == 1))
    }
  }

  @Test func globalFoldPreferenceOverridesManualBlockChoice() async throws {
    let reader = try await reader("```swift\n" + String(repeating: "value\n", count: 30) + "```")
    defer { reader.window.close() }
    let first = try #require(reader.controls.records.first)
    reader.controls.toggleLimit(first.id, enabled: false)
    var preferences = reader.preferences
    preferences.limitCodeHeight = false
    func refresh() {
      let display = NSMutableAttributedString(attributedString: reader.rendered.attributedString)
      reader.controls.prepare(
        display, rendered: reader.rendered, document: reader.document, preferences: preferences)
      reader.view.textStorage?.setAttributedString(display)
      reader.view.fitDocument()
      reader.controls.updateFrames()
    }
    refresh()
    #expect(reader.controls.records.first?.limited == false)
    preferences.limitCodeHeight = true
    refresh()
    #expect(reader.controls.records.first?.embedded == true)
    preferences.limitCodeHeight = false
    refresh()
    #expect(reader.controls.records.first?.limited == false)
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
    reader.container.size.width = 160
    reader.controls.containerDidResize()
    reader.view.sizeToFit()
    reader.controls.updateFrames()
    let header = try #require(
      reader.view.subviews.first { $0.subviews.contains { ($0 as? NSButton)?.title == "…" } })
    #expect(header.frame.width == 160)
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

  @Test func roundedPanelIntegratesPaddedCodeAndLocalizedIconControls() async throws {
    let reader = try await reader("Before the panel.\n\n```swift\nlet value = 1\n```\n\nAfter.")
    defer { reader.window.close() }
    let record = try #require(reader.controls.records.first)
    let header = try #require(
      reader.view.subviews.first { $0.identifier?.rawValue == "code-block-header" })
    header.layoutSubtreeIfNeeded()
    #expect(record.panelFrame.contains(record.headerFrame))
    #expect(record.headerFrame.maxY < record.frame.minY)
    #expect(record.panelFrame.maxY > record.frame.maxY + 14)
    let firstGlyph = reader.layout.glyphIndexForCharacter(at: record.range.location)
    let firstFragment = reader.layout.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
    #expect(firstFragment.minX >= record.indent + 16)
    #expect(record.scrollbarFrame.maxX <= record.panelFrame.maxX - 16)
    let before = (reader.view.string as NSString).range(of: "Before the panel.")
    let beforeGlyphs = reader.layout.glyphRange(
      forCharacterRange: before, actualCharacterRange: nil)
    let beforeRect = reader.layout.boundingRect(forGlyphRange: beforeGlyphs, in: reader.container)
    #expect(beforeRect.maxY + reader.view.textContainerOrigin.y <= record.panelFrame.minY)
    let buttons = header.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
    #expect(buttons.count == 4)
    for button in buttons {
      #expect(button.imagePosition == .imageOnly)
      #expect(button.image != nil)
      #expect(button.toolTip?.isEmpty == false)
      #expect(header.bounds.contains(button.frame))
      #expect(!button.isBordered)
    }
    let height = try #require(buttons.first { $0.identifier?.rawValue == "code-height" })
    #expect(!height.isEnabled)
    #expect(height.accessibilityLabel() == localized("Limit code height"))
    #expect(height.toolTip == localized("All code is already visible"))
    let toggles = buttons.filter { $0.title == localized("Wrap") || $0.title == localized("Lines") }
    #expect(toggles.count == 2)
    for toggle in toggles { toggle.title = "Satır numaraları için yerelleştirilmiş açıklama" }
    header.needsLayout = true
    header.layoutSubtreeIfNeeded()
    for (index, button) in buttons.enumerated() {
      #expect(button.frame.width == 26)
      for other in buttons.dropFirst(index + 1) { #expect(!button.frame.intersects(other.frame)) }
    }
  }

  @Test func screenPanelPreservesAnnotationPaintAndExportAttributes() async throws {
    let reader = try await reader("```swift\nlet markedValue = 1\n```")
    defer { reader.window.close() }
    let original = reader.rendered.attributedString.copy() as! NSAttributedString
    let range = (original.string as NSString).range(of: "markedValue")
    let marked = NSMutableAttributedString(attributedString: original)
    let paint = NSColor.systemYellow.withAlphaComponent(0.32)
    marked.addAttributes(
      [.backgroundColor: paint, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
    reader.controls.prepare(
      marked, rendered: reader.rendered, document: reader.document, preferences: reader.preferences)
    #expect(
      marked.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor
        == paint)
    #expect(
      marked.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int
        == NSUnderlineStyle.single.rawValue)
    let record = try #require(reader.controls.records.first)
    #expect(
      marked.attribute(.backgroundColor, at: record.range.location, effectiveRange: nil) == nil)
    #expect(reader.rendered.attributedString.isEqual(to: original))
    #expect(marked.string == original.string)
  }

  @Test(arguments: [false, true])
  func limitingHeightPreservesCanonicalCopyAndRevealsHiddenSelection(wrap: Bool) async throws {
    let code =
      (1...80).map { "line \($0)\tvalue 😀 İ 漢字 " + String(repeating: "long_value_", count: 8) }
      .joined(separator: "\n") + "\n"
    let reader = try await reader("Before.\n\n```swift\n" + code + "```\n\nAFTER-END\n")
    defer { reader.window.close() }
    let record = try #require(reader.controls.records.first)
    #expect(record.limited && !record.hiddenRanges.isEmpty)
    reader.controls.toggleLimit(record.id, enabled: false)
    let original = reader.rendered.attributedString.copy() as! NSAttributedString
    if wrap { reader.controls.toggleWrap(record.id, enabled: true) }
    let canonical = reader.view.string
    let expandedHeight = record.frame.height
    let after = (canonical as NSString).range(of: "AFTER-END")
    let afterGlyph = reader.layout.glyphIndexForCharacter(at: after.location)
    let expandedAfter = reader.layout.lineFragmentRect(forGlyphAt: afterGlyph, effectiveRange: nil)
    #expect(!record.limited)
    reader.controls.toggleLimit(record.id, enabled: true)
    let hidden = try #require(record.hiddenRanges.last)
    #expect(record.limited)
    #expect(record.frame.height < expandedHeight / 2)
    let foldedAfter = reader.layout.lineFragmentRect(forGlyphAt: afterGlyph, effectiveRange: nil)
    #expect(foldedAfter.minY < expandedAfter.minY / 2)
    #expect(record.embedded)
    #expect(foldedAfter.minY + reader.view.textContainerOrigin.y >= record.frame.maxY)
    let hit = reader.layout.characterIndex(
      for: NSPoint(x: 2, y: foldedAfter.midY), in: reader.container,
      fractionOfDistanceBetweenInsertionPoints: nil)
    #expect(hit >= after.location)
    #expect(reader.view.string == canonical)
    #expect(reader.rendered.attributedString.isEqual(to: original))
    reader.view.setSelectedRange(NSRange(location: 0, length: canonical.utf16.count))
    let pasteboard = NSPasteboard.withUniqueName()
    #expect(reader.view.writeSelection(to: pasteboard, types: reader.view.writablePasteboardTypes))
    #expect(pasteboard.string(forType: .string) == canonical)
    #expect(record.original == code)
    // The same callback used by search and native keyboard selection must scroll the short
    // view to hidden rows, including wrapped blocks, without expanding it.
    let selection = NSRange(location: NSMaxRange(hidden) - 5, length: 0)
    reader.view.setSelectedRange(selection)
    reader.controls.revealSelection(selection, previous: NSRange(location: 0, length: 0))
    #expect(record.limited && record.embedded)
    #expect((reader.controls.viewportOffset(record.id)?.y ?? 0) > 0)
    #expect(record.frame.height < expandedHeight / 2)
    #expect(reader.view.selectedRange() == selection)
    #expect(reader.view.string == canonical)
  }

  @Test func limitedStateSurvivesDisplayRefreshAndResizingWithoutChangingSource() async throws {
    let reader = try await reader(
      "```swift\n" + String(repeating: "print(\"stable\")\n", count: 100) + "```\n\nAfter.")
    defer { reader.window.close() }
    let id = try #require(reader.controls.records.first?.id)
    reader.controls.toggleLimit(id, enabled: true)
    let display = NSMutableAttributedString(attributedString: reader.rendered.attributedString)
    reader.controls.prepare(
      display, rendered: reader.rendered, document: reader.document, preferences: reader.preferences
    )
    reader.view.textStorage?.setAttributedString(display)
    reader.view.fitDocument()
    reader.controls.updateFrames()
    let record = try #require(reader.controls.records.first)
    #expect(record.id == id && record.limited && !record.hiddenRanges.isEmpty)
    reader.container.size.width = 240
    reader.controls.containerDidResize()
    reader.view.fitDocument()
    reader.controls.updateFrames()
    #expect(record.limited && !record.hiddenRanges.isEmpty)
    reader.controls.toggleLimit(id, enabled: false)
    #expect(!record.limited && record.hiddenRanges.isEmpty)
    #expect(reader.controls.hiddenRanges.isEmpty)
    #expect(reader.view.string == reader.rendered.attributedString.string)
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
    reader.container.size.width = 160
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
