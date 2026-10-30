import AppKit
import Foundation
import OSLog

/// Opt-in numeric-only diagnostics. Never records source, filenames, paths, or annotation text.
@MainActor enum PerformanceTrace {
  private static let logger = Logger(
    subsystem: "com.bgoktugozdemir.MarkUp.performance", category: "reading")
  private static var launchTime = ProcessInfo.processInfo.systemUptime
  private static var firstLayout = true
  private static var openings: [ObjectIdentifier: (time: TimeInterval, operation: String)] = [:]
  private static var enabled: Bool {
    ProcessInfo.processInfo.environment["MARKUP_MEASURE"] == "1"
      || UserDefaults.standard.bool(forKey: "MarkUpMeasure")
  }

  static func launch() { launchTime = ProcessInfo.processInfo.systemUptime }
  static func begin(_ identity: ObjectIdentifier, reload: Bool) {
    guard enabled else { return }
    openings[identity] = (ProcessInfo.processInfo.systemUptime, reload ? "reload" : "open")
  }
  static func close(_ identity: ObjectIdentifier) { openings.removeValue(forKey: identity) }
  static func readyWhenMounted(
    _ identity: ObjectIdentifier, text: NSTextView, contentWidth: CGFloat
  ) {
    guard let expected = openings[identity]?.time else { return }
    Task { @MainActor [weak text] in
      // The representable's first update can precede its final native window/frame assignment.
      // This opt-in probe records settled mounted layout, rather than a zero-width first pass.
      for _ in 0..<500 {
        do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
        guard openings[identity]?.time == expected, let text else { return }
        guard let scroll = text.enclosingScrollView, let container = text.textContainer,
          text.window?.isVisible == true, scroll.contentSize.width > 0
        else { continue }
        let target = max(180, min(contentWidth, scroll.contentSize.width - 64))
        guard abs(container.size.width - target) < 0.5 else { continue }
        ready(identity, characters: text.string.utf16.count)
        return
      }
    }
  }
  static func ready(_ identity: ObjectIdentifier, characters: Int) {
    guard enabled, let measurement = openings.removeValue(forKey: identity) else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = (now - measurement.time) * 1000
    let launch = firstLayout ? (now - launchTime) * 1000 : -1
    firstLayout = false
    logger.notice(
      "operation=\(measurement.operation, privacy: .public) open_to_layout_ms=\(elapsed, privacy: .public) launch_to_first_layout_ms=\(launch, privacy: .public) characters=\(characters, privacy: .public)"
    )
  }
}
