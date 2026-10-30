import AppKit
import Testing

@testable import MarkUp

@MainActor
struct ReaderSelectionRestorerTests {
  private let original =
    "A sufficiently detailed introduction before the selected words and a stable ending after them."

  @Test func insertionBeforeSelectionPreservesExactSelectedText() async throws {
    let selection = (original as NSString).range(of: "selected words")
    let view = NSTextView()
    view.string = "New introductory paragraph.\n\n" + original
    let restorer = ReaderSelectionRestorer()
    await restorer.restore(selection, from: original, in: view)?.value
    #expect(view.selectedRange() == (view.string as NSString).range(of: "selected words"))
  }

  @Test func ambiguousOrRemovedSelectionDoesNotGuessOffsets() async {
    let selection = (original as NSString).range(of: "selected words")
    for replacement in [
      original + "\n" + original,
      original.replacingOccurrences(of: "selected words", with: "replacement"),
    ] {
      let view = NSTextView()
      view.string = replacement
      let restorer = ReaderSelectionRestorer()
      await restorer.restore(selection, from: original, in: view)?.value
      #expect(view.selectedRange().length == 0)
    }
  }

  @Test func laterUserSelectionSupersedesPendingRestoration() async {
    let view = NSTextView()
    view.string = "New paragraph.\n" + original
    let restorer = ReaderSelectionRestorer()
    let task = restorer.restore(
      (original as NSString).range(of: "selected words"), from: original, in: view)
    restorer.cancel()
    let userSelection = NSRange(location: 0, length: 3)
    view.setSelectedRange(userSelection)
    await task?.value
    #expect(view.selectedRange() == userSelection)
  }

  @Test func replacementOrCloseRejectsPendingResult() async {
    let view = NSTextView()
    view.string = "New paragraph.\n" + original
    let restorer = ReaderSelectionRestorer()
    let task = restorer.restore(
      (original as NSString).range(of: "selected words"), from: original, in: view)
    view.string = "A newer document snapshot"
    await task?.value
    #expect(view.selectedRange().length == 0)
    view.string = "New paragraph.\n" + original
    await restorer.restore(
      (original as NSString).range(of: "selected words"), from: original,
      in: view, isCurrent: { false })?.value
    #expect(view.selectedRange().length == 0)
  }
}
