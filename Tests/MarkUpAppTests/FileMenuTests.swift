import AppKit
import Testing

@testable import MarkUp

@MainActor
struct FileMenuTests {
  @Test func onlySystemOpenItemsAreTreatedAsDuplicates() {
    let systemOpen = NSMenuItem(
      title: "Open…", action: #selector(NSDocumentController.openDocument(_:)),
      keyEquivalent: "o")
    let systemRecent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
    systemRecent.submenu = NSMenu(title: "Open Recent")
    systemRecent.submenu?.addItem(
      withTitle: "Clear Menu",
      action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
    let untitled = NSMenuItem(title: "NSMenuItem", action: nil, keyEquivalent: "")
    #expect(SystemFileMenuCleanup.isSystemDuplicate(systemOpen))
    #expect(SystemFileMenuCleanup.isSystemDuplicate(systemRecent))
    #expect(SystemFileMenuCleanup.isSystemDuplicate(untitled))

    let appRecent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
    appRecent.submenu = NSMenu(title: "Open Recent")
    appRecent.submenu?.addItem(withTitle: "Clear Recent Documents", action: nil, keyEquivalent: "")
    #expect(!SystemFileMenuCleanup.isSystemDuplicate(appRecent))
    #expect(!SystemFileMenuCleanup.isSystemDuplicate(NSMenuItem.separator()))
    #expect(
      !SystemFileMenuCleanup.isSystemDuplicate(
        NSMenuItem(title: "Close", action: nil, keyEquivalent: "w")))
  }

  @Test func aboutCreditsLinkWebsiteAndRepository() {
    let credits = AboutPanel.credits()
    var links: [URL] = []
    credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) {
      value, _, _ in
      if let url = value as? URL { links.append(url) }
    }
    #expect(links == [URL(string: "https://bgo.dev")!, AboutPanel.repository])
  }
}
