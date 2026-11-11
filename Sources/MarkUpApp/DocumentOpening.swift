import AppKit
import UniformTypeIdentifiers

/// Where a document chosen from the File menu appears relative to the current reader window.
enum DocumentPlacement {
  case replaceCurrent
  case newTab
  case newWindow
}

@MainActor
enum DocumentOpener {
  static func choose(_ placement: DocumentPlacement) {
    // Capture the reader window before the open panel takes key status.
    let anchor = readerWindow()
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.markdown]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      MainActor.assumeIsolated { open(url, placement: placement, anchor: anchor) }
    }
  }

  static func open(_ url: URL, placement: DocumentPlacement, anchor: NSWindow?) {
    let anchorWasTabbed = anchor?.tabbedWindows != nil
    NSDocumentController.shared.openDocument(withContentsOf: url, display: true) {
      document, alreadyOpen, error in
      MainActor.assumeIsolated {
        ReaderCommandState.shared.refreshRecentDocuments()
        if let error {
          NSApp.presentError(error)
          return
        }
        // An already open document is only brought forward; never close or move its window.
        guard let document, !alreadyOpen else { return }
        Task { @MainActor in
          guard let window = await window(of: document) else { return }
          place(window, placement, anchor: anchor, anchorWasTabbed: anchorWasTabbed)
        }
      }
    }
  }

  private static func place(
    _ window: NSWindow, _ placement: DocumentPlacement, anchor: NSWindow?, anchorWasTabbed: Bool
  ) {
    let sharesAnchorGroup = anchor.map { window.tabbedWindows?.contains($0) == true } ?? false
    switch placement {
    case .newWindow:
      // The system tabbing preference may have merged the window; detach it.
      if (window.tabbedWindows?.count ?? 0) > 1 { window.moveTabToNewWindow(nil) }
    case .newTab:
      guard let anchor, anchor !== window else { break }
      if !sharesAnchorGroup { anchor.addTabbedWindow(window, ordered: .above) }
    case .replaceCurrent:
      guard let anchor, anchor !== window else { break }
      if anchorWasTabbed || sharesAnchorGroup {
        // Take the current tab's position rather than the end of the tab bar.
        if sharesAnchorGroup { anchor.tabGroup?.removeWindow(window) }
        anchor.addTabbedWindow(window, ordered: .above)
      } else {
        window.setFrame(anchor.frame, display: true)
      }
      window.makeKeyAndOrderFront(nil)
      anchor.performClose(nil)
      return
    }
    window.makeKeyAndOrderFront(nil)
  }

  private static func readerWindow() -> NSWindow? {
    [NSApp.keyWindow, NSApp.mainWindow].lazy.compactMap { $0 }.first {
      NSDocumentController.shared.document(for: $0) != nil
    }
  }

  /// SwiftUI may attach the document's window controller after the open completion runs.
  private static func window(of document: NSDocument) async -> NSWindow? {
    for _ in 0..<40 {
      if let window = document.windowControllers.lazy.compactMap(\.window).first { return window }
      do { try await Task.sleep(for: .milliseconds(25)) } catch { return nil }
    }
    return nil
  }
}

/// DocumentGroup always inserts AppKit's Open… and Open Recent items. MarkUp provides its own
/// placement-aware Open… and a working Open Recent, so hide the system duplicates whenever
/// SwiftUI rebuilds the File menu. Hidden items also stop matching key equivalents.
@MainActor
enum SystemFileMenuCleanup {
  private static var observers: [NSObjectProtocol] = []

  static func install() {
    guard observers.isEmpty else { return }
    for name in [
      NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification,
      NSMenu.didBeginTrackingNotification,
    ] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
          MainActor.assumeIsolated { apply() }
        })
    }
    apply()
  }

  static func apply() {
    for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
      for item in menu.items where !item.isHidden && isSystemDuplicate(item) {
        item.isHidden = true
      }
    }
  }

  static func isSystemDuplicate(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(NSDocumentController.openDocument(_:)) { return true }
    if item.title == "NSMenuItem" { return true }
    return item.submenu?.items.contains {
      $0.action == #selector(NSDocumentController.clearRecentDocuments(_:))
    } == true
  }
}

@MainActor
enum AboutPanel {
  static let website = URL(string: "https://bgo.dev")!
  static let repository = URL(string: "https://github.com/bgoktugozdemir-dev/MarkUp")!
  static let author = "Göktuğ Özdemir"

  static var appName: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "MarkUp"
  }

  static func show() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
  }

  static func credits() -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let base: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
      .foregroundColor: NSColor.secondaryLabelColor,
      .paragraphStyle: paragraph,
    ]
    let byline = String(format: localized("Developed by %@"), author)
    let text = NSMutableAttributedString(string: byline, attributes: base)
    let authorRange = (byline as NSString).range(of: author)
    if authorRange.location != NSNotFound {
      text.addAttribute(.link, value: website, range: authorRange)
    }
    text.append(NSAttributedString(string: "\n", attributes: base))
    var link = base
    link[.link] = repository
    text.append(NSAttributedString(string: localized("Source Code on GitHub"), attributes: link))
    return text
  }
}
