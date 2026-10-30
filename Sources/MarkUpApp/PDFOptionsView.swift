import AppKit
import MarkUpCore
import SwiftUI

struct PDFOptionsView: View {
  let session: ReaderSession
  @Environment(\.dismiss) private var dismiss
  @State private var options = PDFOptions()
  @State private var cancellationRequested = false
  private var processing: Bool { session.exportTask != nil }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(localized(processing ? "Preparing Document" : "Export PDF")).font(.title2.bold())
      Form {
        Picker(localized("Paper"), selection: $options.paper) {
          Text("A4").tag(PDFOptions.Paper.a4)
          Text(localized("Letter")).tag(PDFOptions.Paper.letter)
        }
        Toggle(localized("Landscape"), isOn: $options.landscape)
        HStack {
          Text(localized("Margins (points)"))
          Slider(value: $options.margin, in: 18...90, step: 1)
            .accessibilityLabel(localized("Margins (points)"))
          Text("\(Int(options.margin))")
        }
        Toggle(localized("Use current appearance"), isOn: $options.currentAppearance)
        Toggle(localized("Include personal annotations"), isOn: $options.includeAnnotations)
        Text(localized("Annotations are excluded by default. Exported text remains selectable."))
          .font(
            .caption
          ).foregroundStyle(.secondary)
      }
      .disabled(processing)
      if let progress = session.exportProgress {
        if let total = progress.total, total > 0 {
          ProgressView(value: Double(progress.completed), total: Double(total))
        } else {
          ProgressView().controlSize(.small)
        }
        Text(cancellationRequested ? localized("Cancelling…") : progressText(progress)).font(
          .caption
        )
        .foregroundStyle(.secondary)
      }
      if let status = session.status { Text(status).font(.caption).foregroundStyle(.secondary) }
      HStack {
        Spacer()
        Button(localized("Cancel")) {
          if processing {
            cancellationRequested = true
            session.exportTask?.cancel()
          } else {
            dismiss()
          }
        }.keyboardShortcut(.cancelAction).disabled(cancellationRequested)
        Button(localized("Export…")) { session.exportPDF(options: options) }.keyboardShortcut(
          .defaultAction
        ).disabled(processing)
      }
    }.padding(24).frame(width: 460)
      .interactiveDismissDisabled(processing)
      .onChange(of: processing) { _, active in if !active { cancellationRequested = false } }
  }

  private func progressText(_ progress: PDFExportProgress) -> String {
    switch progress.stage {
    case .preparing: localized("Preparing document…")
    case .paginating: "\(localized("Paginating document…")) \(progress.completed)"
    case .navigation: localized("Preparing PDF links…")
    case .drawing:
      "\(localized("Rendering PDF pages…")) \(progress.completed)/\(progress.total ?? 0)"
    case .writing: localized("Saving PDF…")
    }
  }
}

extension ReaderSession {
  func exportPDF(options: PDFOptions) {
    guard exportTask == nil, !isClosed else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.nameFieldStringValue =
      (url?.deletingPathExtension().lastPathComponent ?? localized("Document")) + ".pdf"
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    guard
      destination.resolvingSymlinksInPath().standardizedFileURL
        != url?.resolvingSymlinksInPath().standardizedFileURL
    else {
      error = localized(
        "Choose a different destination. The Markdown source cannot be overwritten.")
      return
    }
    status = nil
    exportProgress = PDFExportProgress(stage: .preparing, completed: 0, total: nil)
    exportTask = Task { [weak self] in
      guard let self, !isClosed else { return }
      defer {
        exportTask = nil
        exportProgress = nil
      }
      do {
        try await PDFExporter.checkpoint()
        guard let output = exportContent(options: options) else { return }
        try await PDFExporter().export(rendered: output, to: destination, options: options) {
          [weak self] progress in
          guard let self, !isClosed, !Task.isCancelled else { return }
          exportProgress = progress
        }
        guard !isClosed else { return }
        status = localized("PDF exported.")
        exportPresented = false
      } catch is CancellationError {
        if !isClosed { status = localized("PDF export cancelled.") }
      } catch {
        guard !isClosed else { return }
        self.error = localized("PDF export failed. Check the destination and available disk space.")
        status = self.error
      }
    }
  }

  func printDocument() {
    guard exportTask == nil, !isClosed else { return }
    let options = PDFOptions()
    status = nil
    exportPresented = true
    exportProgress = PDFExportProgress(stage: .preparing, completed: 0, total: nil)
    exportTask = Task { [weak self] in
      guard let self, !isClosed else { return }
      defer {
        exportTask = nil
        exportProgress = nil
      }
      do {
        try await PDFExporter.checkpoint()
        guard let output = exportContent(options: options) else { return }
        let submitted = try await PDFExporter().print(rendered: output, options: options) {
          [weak self] progress in
          guard let self, !isClosed, !Task.isCancelled else { return }
          exportProgress = progress
        }
        guard !isClosed else { return }
        status = localized(submitted ? "Print job submitted." : "Printing cancelled.")
        exportPresented = false
      } catch is CancellationError {
        if !isClosed { status = localized("Printing cancelled.") }
      } catch {
        guard !isClosed else { return }
        self.error = localized("Printing failed. Try exporting a PDF instead.")
        status = self.error
      }
    }
  }

  private func exportContent(options: PDFOptions) -> RenderedDocument? {
    guard let document, let rendered else { return nil }
    return PDFContentPreparation.prepare(
      document: document, current: rendered,
      preferences: AppSettings.shared.value, tokens: tokens, annotations: annotations,
      resolved: resolvedAnnotations, options: options)
  }
}
