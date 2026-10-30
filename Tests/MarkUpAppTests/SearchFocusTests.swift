import AppKit
import SwiftUI
import Testing

@testable import MarkUp

@MainActor
struct SearchFocusTests {
  @Test func mountedSearchTakesNativeFocusAndRepeatedFindRefocusesIt() async throws {
    let previousWindow = NSApp.keyWindow
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 760, height: 540),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let hosting = NSHostingView(
      rootView: ReaderView(url: nil, source: "# Search\n\nFind this passage."))
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    defer {
      findReader(in: hosting)?.session?.close()
      window.close()
      previousWindow?.makeKeyAndOrderFront(nil)
    }
    try await waitUntil { findReader(in: hosting) != nil }
    let reader = try #require(findReader(in: hosting))
    let session = try #require(reader.session)
    window.makeFirstResponder(reader)
    session.showSearch = true
    NotificationCenter.default.post(name: .requestDocumentSearchFocus, object: session)
    try await waitUntil { (window.firstResponder as? NSTextView)?.isFieldEditor == true }
    let editor = try #require(window.firstResponder as? NSTextView)
    editor.insertText("passage", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await waitUntil { session.search == "passage" && session.matches.count == 1 }
    #expect(session.matches.count == 1)

    // Cmd+F must work again after clicking the document while search stays visible.
    window.makeFirstResponder(reader)
    NotificationCenter.default.post(name: .requestDocumentSearchFocus, object: session)
    try await waitUntil { (window.firstResponder as? NSTextView)?.isFieldEditor == true }

    // A pending mount request must not steal focus after the bar is dismissed.
    NotificationCenter.default.post(name: .requestDocumentSearchFocus, object: session)
    session.showSearch = false
    try await Task.sleep(for: .milliseconds(120))
    #expect(window.firstResponder === reader)
  }

  private func findReader(in root: NSView) -> ReaderTextView? {
    if let reader = root as? ReaderTextView { return reader }
    for child in root.subviews {
      if let reader = findReader(in: child) { return reader }
    }
    return nil
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !predicate(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(predicate(), "Mounted native search field did not receive focus or update its binding")
  }
}
