import AppKit
import MarkUpCore

/// Ephemeral selection uses the same conservative evidence as durable annotations. Work runs
/// off the UI actor; a later user selection or document snapshot always supersedes its result.
@MainActor final class ReaderSelectionRestorer {
  private var pending: Task<Void, Never>?
  private var generation = 0

  func cancel() {
    generation += 1
    pending?.cancel()
    pending = nil
  }

  @discardableResult
  func restore(
    _ selection: NSRange, from previousText: String, in textView: NSTextView,
    isCurrent: @escaping @MainActor () -> Bool = { true }
  ) -> Task<Void, Never>? {
    cancel()
    guard selection.length > 0 else { return nil }
    let expected = generation
    let currentText = textView.string
    let resolver = Task.detached(priority: .userInitiated) { () -> NSRange? in
      guard !Task.isCancelled,
        let anchor = try? TextAnchor.capture(in: previousText, range: selection)
      else { return nil }
      guard !Task.isCancelled else { return nil }
      guard case .resolved(let range) = AnchorResolver.resolve(anchor, in: currentText) else {
        return nil
      }
      return Task.isCancelled ? nil : range
    }
    let task = Task { [weak self, weak textView] in
      let range = await withTaskCancellationHandler {
        await resolver.value
      } onCancel: {
        resolver.cancel()
      }
      guard !Task.isCancelled, let self, expected == generation,
        let textView, isCurrent(), textView.string == currentText, let range
      else { return }
      textView.setSelectedRange(range)
    }
    pending = task
    return task
  }
}
