import AppKit
import MarkUpCore
import SwiftUI
import Testing

@testable import MarkUp

@MainActor
struct ReaderAnnotationUndoTests {
  @Test func focusedReaderRoutesUndoToDurableAnnotationsAfterRenderingUpdates() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MarkUp-ReaderUndo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let documentURL = directory.appendingPathComponent("reader.md")
    let source = "# Reader undo\n\nBefore the selected 96 and a distinctive ending after it.\n"
    let originalBytes = Data(source.utf8)
    try originalBytes.write(to: documentURL)
    let store = try AnnotationStore(directory: directory.appendingPathComponent("annotations"))
    let session = ReaderSession(url: documentURL, source: "", annotationStore: store)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let content = NSView(frame: window.contentLayoutRect)
    let hosting = NSHostingView(rootView: UndoReaderHost(session: session))
    hosting.frame = content.bounds
    hosting.autoresizingMask = [.width, .height]
    content.addSubview(hosting)
    window.contentView = content
    window.makeKeyAndOrderFront(nil)
    defer {
      session.close()
      window.close()
      try? FileManager.default.removeItem(at: directory)
    }
    try await waitUntil { session.rendered != nil && session.textView != nil && !session.loading }
    let text = try #require(session.textView as? ReaderTextView)
    try await makeKey(window)
    #expect(window.makeFirstResponder(text))
    try #require(NSApp.keyWindow === window)
    #expect(window.firstResponder === text)
    #expect(text.undoManager === session.annotationUndoManager)
    let canonical = try #require(session.rendered?.attributedString.string)
    let selection = (canonical as NSString).range(of: "96")
    text.setSelectedRange(selection)
    session.selection = selection
    session.addAnnotation(.highlightYellow)
    try await waitUntil { session.annotations.count == 1 && session.resolvedAnnotations.count == 1 }
    try await waitUntil { await store.count == 1 }
    let mark = try #require(session.annotations.first)
    let documentID = mark.documentID

    // Recoloring and replacing text storage must never put a native text edit above the mark.
    session.render()
    try await waitUntil {
      session.resolvedAnnotations.count == 1
        && (text.textStorage?.attribute(
          .backgroundColor, at: selection.location, effectiveRange: nil)
          as? NSColor) != nil
    }
    try await makeKey(window)
    #expect(window.makeFirstResponder(text))
    try #require(NSApp.keyWindow === window)
    #expect(window.firstResponder === text)
    #expect(ReaderUndoRouting.manager(for: session) === session.annotationUndoManager)
    #expect(ReaderUndoRouting.manager(for: session)?.canUndo == true)
    ReaderUndoRouting.undo(in: session)  // The actual Edit menu/Cmd+Z command path.
    try await waitUntil { session.annotations.isEmpty }
    try await waitUntil { await store.snapshot(documentID: documentID).annotations.isEmpty }
    #expect(ReaderUndoRouting.manager(for: session)?.canRedo == true)
    #expect(text.string == canonical)

    ReaderUndoRouting.redo(in: session)
    try await waitUntil { session.annotations.map(\.id) == [mark.id] }
    try await waitUntil { await store.snapshot(documentID: documentID).annotations == [mark] }
    #expect(text.string == canonical)
    #expect(session.source == source)
    #expect(try Data(contentsOf: documentURL) == originalBytes)

    // Search/other editable controls must keep text undo and never fall through to marks.
    let field = NSTextField(frame: NSRect(x: 16, y: 16, width: 240, height: 28))
    field.stringValue = "Initial query"
    content.addSubview(field)
    try await makeKey(window)
    #expect(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.allowsUndo = true
    try #require(NSApp.keyWindow === window)
    #expect(window.firstResponder === editor)
    #expect(editor.isFieldEditor && editor.isEditable)
    let editorUndo = try #require(editor.undoManager)
    #expect(editorUndo !== session.annotationUndoManager)
    editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
    editor.insertText("Search query", replacementRange: editor.selectedRange())
    editor.breakUndoCoalescing()
    #expect(editor.string == "Search query")
    #expect(editorUndo.canUndo)
    #expect(ReaderUndoRouting.manager(for: session) === editorUndo)
    #expect(ReaderUndoRouting.manager(for: nil) === editorUndo)
    #expect(ReaderUndoRouting.manager(for: session) !== session.annotationUndoManager)
    ReaderUndoRouting.undo(in: session)
    #expect(editor.string == "Initial query")
    #expect(editorUndo.canRedo)
    ReaderUndoRouting.redo(in: nil)
    #expect(editor.string == "Search query")
    #expect(session.annotations.map(\.id) == [mark.id])
    #expect(window.makeFirstResponder(text))
    field.removeFromSuperview()

    // Clear All must invalidate the same manager even while the reader remains mounted/focused.
    _ = try await store.clearAll()
    try await waitUntil {
      session.annotations.isEmpty && !session.annotationUndoManager.canUndo
        && !session.annotationUndoManager.canRedo
    }
    #expect(try Data(contentsOf: documentURL) == originalBytes)
  }

  private func makeKey(_ window: NSWindow) async throws {
    // Activation is asynchronous. Acquiring the key window before didBecomeActive
    // can be discarded by AppKit while another app is still active.
    NSApp.activate()
    try await waitUntil { NSApp.isActive }
    try #require(NSApp.isActive, "The test host must be active before command routing")
    try #require(window.canBecomeKey)
    window.makeKeyAndOrderFront(nil)
    window.makeKey()
    try await waitUntil { NSApp.keyWindow === window }
    try #require(NSApp.keyWindow === window, "The native test window must own command routing")
  }

  private func waitUntil(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await predicate()), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await predicate(), "Reader annotation routing did not reach the expected durable state")
  }
}

private struct UndoReaderHost: View {
  let session: ReaderSession
  var body: some View {
    let _ = session.renderedRevision
    NativeReader(session: session, preferences: ReaderPreferences())
      .onAppear { session.start() }
      .onDisappear { session.close() }
  }
}
