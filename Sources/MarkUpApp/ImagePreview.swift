import AppKit

/// A document-owned preview of an image that has already passed resource access and decoding.
/// This controller never resolves a URL, opens a file, or starts a network request.
@MainActor
final class ImagePreviewController: NSObject, @MainActor NSWindowDelegate {
  private var panel: NSPanel?
  private var imageView: NSImageView?

  func show(image: NSImage, alt: String) {
    guard image.size.width.isFinite, image.size.height.isFinite,
      image.size.width > 0, image.size.height > 0
    else { return }
    let label = alt.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = label.isEmpty ? localized("Image Preview") : String(label.prefix(512))
    let panel: NSPanel
    if let current = self.panel {
      panel = current
    } else {
      panel = ImagePreviewPanel(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      panel.isReleasedWhenClosed = false
      panel.appearance = NSApp.keyWindow?.effectiveAppearance
      panel.isFloatingPanel = false
      panel.hidesOnDeactivate = false
      panel.collectionBehavior = [.fullScreenAuxiliary]
      panel.contentMinSize = NSSize(width: 240, height: 160)
      panel.delegate = self
      let content = NSView()
      let view = NSImageView()
      view.translatesAutoresizingMaskIntoConstraints = false
      view.imageScaling = .scaleProportionallyUpOrDown
      view.imageAlignment = .alignCenter
      view.imageFrameStyle = .none
      view.isEditable = false
      view.allowsCutCopyPaste = true
      content.addSubview(view)
      NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
        view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
        view.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
        view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
      ])
      panel.contentView = content
      self.panel = panel
      imageView = view
    }
    panel.title = title
    imageView?.image = image
    imageView?.setAccessibilityLabel(label.isEmpty ? localized("Image Preview") : label)
    imageView?.toolTip = label.isEmpty ? nil : label
    if !panel.isVisible {
      let screen =
        NSApp.keyWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
      let available = NSSize(width: screen.width * 0.8, height: screen.height * 0.8)
      let scale = min(
        1, (available.width - 32) / image.size.width,
        (available.height - 32) / image.size.height)
      panel.setContentSize(
        NSSize(
          width: max(240, image.size.width * scale + 32),
          height: max(160, image.size.height * scale + 32)))
      panel.setFrameOrigin(
        NSPoint(
          x: screen.midX - panel.frame.width / 2, y: screen.midY - panel.frame.height / 2))
    }
    panel.makeKeyAndOrderFront(nil)
  }

  func close() {
    imageView?.image = nil
    panel?.close()
    panel = nil
    imageView = nil
  }

  func windowWillClose(_ notification: Notification) {
    // A user-closed preview releases its decoded content immediately. Its small native window
    // can be reused by the owning document until the view itself is dismantled.
    imageView?.image = nil
  }
}

@MainActor
private final class ImagePreviewPanel: NSPanel {
  override func cancelOperation(_ sender: Any?) { performClose(sender) }
}
