import MarkUpCore
import SwiftUI

struct AnnotationRecoveryView: View {
  let session: ReaderSession
  @Environment(\.dismiss) private var dismiss
  @State private var selected: AnnotationDocumentSummary?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(localized("Recover Annotations")).font(.title2.bold())
      Text(
        localized(
          "If a file was replaced while MarkUp was closed, its old marks remain separate. Choose their previous document only if you recognize it."
        )
      )
      .foregroundStyle(.secondary)
      List(session.recoveryDocuments, id: \.id) { item in
        Button {
          selected = item
        } label: {
          HStack {
            Image(systemName: "doc.text")
            Text(item.identity.canonicalURL.lastPathComponent)
            Spacer()
            Text("\(item.annotationCount)").monospacedDigit()
          }.padding(.vertical, 4)
        }.buttonStyle(.plain)
      }
      if session.recoveryDocuments.isEmpty {
        Text(localized("No other saved annotations are available."))
      }
      HStack {
        Spacer()
        Button(localized("Done")) { dismiss() }
      }
    }.padding(24).frame(width: 520, height: 420)
      .confirmationDialog(
        localized("Move these annotations to the current document?"),
        isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })
      ) {
        Button(localized("Recover Annotations")) {
          if let selected { session.recoverAnnotations(from: selected.id) }
          dismiss()
        }
        Button(localized("Cancel"), role: .cancel) { selected = nil }
      } message: {
        Text(
          localized(
            "Only trustworthy text matches will be shown. Other marks stay recoverable. The source files are not changed."
          ))
      }
  }
}
