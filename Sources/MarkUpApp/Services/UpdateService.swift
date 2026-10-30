import AppKit
import Observation
import Sparkle

/// The sole Sparkle boundary. A future App Store target excludes this file and its package/entitlements.
@MainActor @Observable final class UpdateService {
  static let shared = UpdateService()
  @ObservationIgnored private var controller: SPUStandardUpdaterController?
  @ObservationIgnored private var changes: NSKeyValueObservation?
  private(set) var automaticChecks = false

  private init() {
    guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
      let url = URL(string: feed), url.scheme == "https", url.host != nil,
      !feed.contains("$("),
      let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
      Data(base64Encoded: key)?.count == 32
    else { return }
    controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    changes = controller?.updater.observe(
      \.automaticallyChecksForUpdates, options: [.initial, .new]
    ) { [weak self] _, _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        automaticChecks = controller?.updater.automaticallyChecksForUpdates ?? false
      }
    }
  }

  var isConfigured: Bool { controller != nil }

  func check() {
    guard let controller else {
      let alert = NSAlert()
      alert.messageText = localized("Updates are not configured in this development build.")
      alert.informativeText = localized(
        "The owner must configure the signed update feed and public key before distributing MarkUp."
      )
      alert.addButton(withTitle: localized("OK"))
      alert.runModal()
      return
    }
    guard controller.updater.canCheckForUpdates else { return }
    controller.checkForUpdates(nil)
  }

  func setAutomaticChecks(_ enabled: Bool) {
    controller?.updater.automaticallyChecksForUpdates = enabled
    automaticChecks = controller?.updater.automaticallyChecksForUpdates ?? false
    // Install/relaunch always uses Sparkle's verified native user flow. Never silently install.
    controller?.updater.automaticallyDownloadsUpdates = false
  }
}
