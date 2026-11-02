import MarkUpCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  static let markdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

struct MarkdownFile: FileDocument {
  static var readableContentTypes: [UTType] { [.markdown] }
  init(configuration: ReadConfiguration) throws {
    if let size = configuration.file.fileAttributes[FileAttributeKey.size.rawValue] as? NSNumber,
      size.uint64Value > UInt64(DocumentInput.maximumBytes)
    {
      throw ReaderInputLocalization.error("This file is larger than the 16 MiB reading limit.")
    }
    guard let data = configuration.file.regularFileContents else {
      throw ReaderInputLocalization.error("This item is not a regular Markdown file.")
    }
    // DocumentGroup may retain closed document boxes. Validate its input, but keep no
    // source payload here: the viewer's scoped loader already reads the file URL itself.
    do { _ = try DocumentInput.decode(data) } catch let failure as DocumentInputError {
      let key: String =
        switch failure {
        case .tooLarge: "This file is larger than the 16 MiB reading limit."
        case .invalidEncoding: "This file is not valid UTF-8 or UTF-16 text."
        case .binaryInput: "This file looks like binary data. Choose a Markdown text file."
        }
      throw ReaderInputLocalization.error(key)
    }
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    throw CocoaError(.fileWriteNoPermission)  // Viewer never serializes or writes source documents.
  }
}

private enum ReaderInputLocalization {
  static func error(_ key: String) -> NSError {
    let language =
      (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first == "tr"
      ? "tr" : "en"
    let bundle =
      Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    return NSError(
      domain: "com.bgoktugozdemir.MarkUp.input", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: bundle.localizedString(forKey: key, value: key, table: nil)
      ])
  }
}

@main struct MarkUpApp: App {
  @State private var settings = AppSettings.shared
  init() {
    PerformanceTrace.launch()
    // Observe launch without acquiring a document controller before SwiftUI installs its own.
    _ = ReaderCommandState.shared
    UserDefaults.standard.set(
      [AppSettings.shared.value.language.rawValue], forKey: "AppleLanguages")
    NSWindow.allowsAutomaticWindowTabbing = true
    _ = UpdateService.shared
  }
  var body: some Scene {
    DocumentGroup(viewing: MarkdownFile.self) { configuration in
      Group {
        if let url = configuration.fileURL {
          ReaderView(url: url, source: "")
        } else {
          ContentUnavailableView(
            localized("No readable content"), systemImage: "doc.text",
            description: Text(localized("Open a Markdown file to begin.")))
        }
      }
      .preferredColorScheme(settings.colorScheme)
      .environment(\.locale, Locale(identifier: settings.value.language.rawValue))
    }
    .commands { ReaderCommands() }
    Window(localized("Welcome to MarkUp"), id: "welcome") {
      WelcomeView().preferredColorScheme(settings.colorScheme)
    }.defaultSize(width: 640, height: 460)
    Settings {
      SettingsView()
        .preferredColorScheme(settings.colorScheme)
        .environment(\.locale, Locale(identifier: settings.value.language.rawValue))
    }
  }
}

private struct SessionFocusKey: FocusedValueKey { typealias Value = ReaderSession }
extension FocusedValues {
  var readerSession: ReaderSession? {
    get { self[SessionFocusKey.self] }
    set { self[SessionFocusKey.self] = newValue }
  }
}

struct ReaderCommands: Commands {
  @FocusedValue(\.readerSession) private var session
  @State private var settings = AppSettings.shared
  @State private var commandState = ReaderCommandState.shared

  private var activeUndoManager: UndoManager? {
    // Native UndoManager is KVO-based. These observed reader values invalidate command
    // validation after annotation commands, clear/recovery, and search editing/focus changes.
    _ = session?.annotations
    _ = session?.renderedRevision
    _ = session?.selection
    _ = session?.search
    _ = session?.showSearch
    _ = commandState.revision
    return ReaderUndoRouting.manager(for: session)
  }

  private var recentDocuments: [URL] {
    _ = commandState.revision
    return commandState.recentDocuments
  }

  var body: some Commands {
    CommandGroup(after: .appInfo) {
      Button(localized("Check for Updates…")) { UpdateService.shared.check() }
    }
    CommandGroup(replacing: .newItem) {}
    CommandGroup(after: .newItem) {
      Menu(localized("Open Recent")) {
        ForEach(recentDocuments, id: \.self) { url in
          Button(url.lastPathComponent) {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) {
              _, _, error in
              Task { @MainActor in
                ReaderCommandState.shared.refreshRecentDocuments()
                if let error { NSApp.presentError(error) }
              }
            }
          }.help(url.path)
        }
        Divider()
        Button(localized("Clear Recent Documents")) {
          NSDocumentController.shared.clearRecentDocuments(nil)
          commandState.refreshRecentDocuments()
        }.disabled(recentDocuments.isEmpty)
      }
      Button(localized("Close")) { NSApp.keyWindow?.performClose(nil) }
        .keyboardShortcut("w")
    }
    CommandGroup(replacing: .undoRedo) {
      Button(localized("Undo")) { ReaderUndoRouting.undo(in: session) }
        .keyboardShortcut("z")
        .disabled(activeUndoManager?.canUndo != true)
      Button(localized("Redo")) { ReaderUndoRouting.redo(in: session) }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(activeUndoManager?.canRedo != true)
    }
    CommandGroup(replacing: .saveItem) {
      Button(localized("Export PDF…")) { session?.exportPresented = true }.keyboardShortcut(
        "e", modifiers: [.command, .shift]
      ).disabled(session == nil)
      Button(localized("Reload")) { session?.reload() }.keyboardShortcut("r").disabled(
        session == nil)
      Button(localized("Open in External Editor")) { session?.openExternalEditor() }.disabled(
        session == nil)
      Button(localized("Grant Folder Access…")) { session?.grantFolder() }.disabled(session == nil)
    }
    CommandGroup(replacing: .printItem) {
      Button(localized("Print…")) { session?.printDocument() }.keyboardShortcut("p").disabled(
        session == nil)
    }
    CommandGroup(after: .textEditing) {
      Button(localized("Find…")) {
        guard let session else { return }
        session.showSearch = true
        NotificationCenter.default.post(name: .requestDocumentSearchFocus, object: session)
      }.keyboardShortcut("f").disabled(
        session == nil)
      Button(localized("Find Next")) { session?.nextMatch(1) }.keyboardShortcut("g").disabled(
        session == nil)
      Button(localized("Find Previous")) { session?.nextMatch(-1) }.keyboardShortcut(
        "g", modifiers: [.command, .shift]
      ).disabled(session == nil)
    }
    CommandMenu(localized("Reading")) {
      Button(localized("Zoom In")) { session?.zoom(0.1) }.keyboardShortcut("+")
      Button(localized("Zoom Out")) { session?.zoom(-0.1) }.keyboardShortcut("-")
      Button(localized("Actual Size")) { settings.value.zoom = 1 }.keyboardShortcut("0")
      Divider()
      Toggle(localized("Show minimap"), isOn: $settings.value.showMinimap).keyboardShortcut(
        "m", modifiers: [.command, .option])
      Toggle(localized("Show outline"), isOn: $settings.value.showOutline).keyboardShortcut(
        "o", modifiers: [.command, .option])
      Toggle(localized("Wrap code"), isOn: $settings.value.wrapCode)
      Button(localized("Load Remote Images")) { session?.loadRemoteImages() }.disabled(
        session == nil)
    }
    CommandMenu(localized("Annotations")) {
      Button(localized("Highlight Yellow")) { session?.addAnnotation(.highlightYellow) }
        .keyboardShortcut(
          "h", modifiers: [.command, .shift])
      Button(localized("Highlight Green")) { session?.addAnnotation(.highlightGreen) }
      Button(localized("Highlight Blue")) { session?.addAnnotation(.highlightBlue) }
      Button(localized("Underline")) { session?.addAnnotation(.underline) }.keyboardShortcut(
        "u", modifiers: [.command, .shift])
      Button(localized("Show Annotations")) { session?.showAnnotations.toggle() }
    }
  }
}

/// DocumentGroup's standard Edit commands validate the NSDocument manager, while the
/// reader deliberately owns a separate annotation history. Route its commands explicitly.
/// An editable field editor keeps its native text history; it never undoes personal marks.
@MainActor
enum ReaderUndoRouting {
  static func manager(for session: ReaderSession?) -> UndoManager? {
    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
      editor.isEditable, !(editor is ReaderTextView)
    {
      return editor.undoManager
    }
    guard let session, !session.isClosed else { return nil }
    return session.annotationUndoManager
  }

  static func undo(in session: ReaderSession?) {
    guard let manager = manager(for: session), manager.canUndo else { return }
    manager.undo()
  }

  static func redo(in session: ReaderSession?) {
    guard let manager = manager(for: session), manager.canRedo else { return }
    manager.redo()
  }
}

/// App-lifetime native command validation. Undo grouping and focus events can complete after
/// a SwiftUI binding changes; observe their actual notifications rather than polling a window.
@MainActor @Observable
final class ReaderCommandState {
  static let shared = ReaderCommandState()
  var revision = 0
  private(set) var recentDocuments: [URL] = []
  @ObservationIgnored private var didFinishLaunching = false
  @ObservationIgnored private var observers: [NSObjectProtocol] = []

  private init() {
    let notifications: [Notification.Name] = [
      .NSUndoManagerDidOpenUndoGroup, .NSUndoManagerDidCloseUndoGroup,
      .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
      NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
      NSApplication.didBecomeActiveNotification,
      NSText.didBeginEditingNotification, NSText.didEndEditingNotification,
    ]
    for name in notifications {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in
          MainActor.assumeIsolated {
            self?.revision += 1
            if name == NSWindow.didBecomeKeyNotification
              || name == NSApplication.didBecomeActiveNotification
            {
              Task { @MainActor [weak self] in self?.refreshRecentDocuments() }
            }
          }
        })
    }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
      ) { [weak self] _ in
        // SwiftUI installs its PlatformDocumentController during willFinishLaunching.
        // Acquiring shared before that corrupts its document-class initialization.
        Task { @MainActor in self?.startAfterLaunch() }
      })
  }

  private func startAfterLaunch() {
    guard !didFinishLaunching else { return }
    didFinishLaunching = true
    refreshRecentDocuments()
  }

  func refreshRecentDocuments() {
    guard didFinishLaunching else { return }
    let current = NSDocumentController.shared.recentDocumentURLs
    if current != recentDocuments { recentDocuments = current }
  }
}

struct WelcomeView: View {
  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "doc.richtext").font(.system(size: 56)).foregroundStyle(.blue)
      Text("MarkUp").font(.largeTitle.bold())
      Text(localized("A calm place for Markdown.")).font(.title3).foregroundStyle(.secondary)
      Button(localized("Open Markdown…")) { NSDocumentController.shared.openDocument(nil) }
        .buttonStyle(.borderedProminent).controlSize(.large)
      Text(localized("Drop a .md or .markdown file here, or press ⌘O."))
        .foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
      .dropDestination(for: URL.self) { urls, _ in
        for url in urls
        where url.isFileURL && ["md", "markdown"].contains(url.pathExtension.lowercased()) {
          NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in
          }
        }
        return !urls.isEmpty
      }
  }
}

struct ReaderView: View {
  @State private var session: ReaderSession
  @State private var settings = AppSettings.shared
  @FocusState private var searchFocused: Bool
  @State private var searchFocusRequest = 0
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme

  init(url: URL?, source: String) {
    _session = State(initialValue: ReaderSession(url: url, source: source))
  }

  private struct PanelRoom: Equatable {
    var outline = true
    var minimap = true
  }
  @State private var room = PanelRoom()

  /// Panels float over the reader, so each is offered only when it fits beside the text.
  private func updateRoom(width: CGFloat) {
    let text = max(180, min(CGFloat(settings.value.contentWidth), width - 64))
    let margin = (width - text) / 2
    let next = PanelRoom(outline: margin >= 222, minimap: margin >= 138)
    guard next != room else { return }
    room = next
    session.minimapVisible = next.minimap
    (session.textView as? ReaderTextView)?.geometryChanged?()
  }

  @ViewBuilder private var readerContent: some View {
    if session.rendered != nil {
      NativeReader(session: session, preferences: settings.value)
    } else if session.loading {
      ProgressView(localized("Loading document…")).frame(
        maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ContentUnavailableView(
        localized("No readable content"), systemImage: "doc.text",
        description: Text(localized("Open a Markdown file to begin.")))
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      if session.showSearch { searchBar }
      if let error = session.error {
        HStack {
          Image(systemName: "exclamationmark.triangle")
          Text(error).font(.callout)
          Spacer()
          Button(localized("Retry")) { session.reload() }
          Button(localized("Dismiss")) { session.error = nil }
        }
        .padding(10).background(.orange.opacity(0.12)).accessibilityElement(children: .combine)
      }
      HStack(spacing: 0) {
        GeometryReader { proxy in
          readerContent
            .frame(width: proxy.size.width, height: proxy.size.height)
            .overlay(alignment: .leading) {
              if settings.value.showOutline, room.outline, session.rendered != nil { outline }
            }
            .overlay(alignment: .trailing) {
              if settings.value.showMinimap, room.minimap, session.rendered != nil {
                // Leave the reader's overlay scroller uncovered.
                MinimapView(session: session).frame(width: 112).padding(.trailing, 14)
              }
            }
            .onAppear { updateRoom(width: proxy.size.width) }
            .onChange(of: proxy.size.width) { _, width in updateRoom(width: width) }
            .onChange(of: settings.value.contentWidth) { _, _ in
              updateRoom(width: proxy.size.width)
            }
        }
        if session.showAnnotations { annotationPanel }
      }
      HStack {
        if session.loading { ProgressView().controlSize(.small) }
        Text(session.status ?? session.url?.lastPathComponent ?? "MarkUp").lineLimit(1)
        Spacer()
        if session.imagesNeedFolderAccess {
          Button(localized("Grant Folder Access…")) { session.grantFolder() }
        }
        if !session.unresolved.isEmpty {
          Button(localizedCount("unmatched_annotation_count", session.unresolved.count)) {
            session.showAnnotations = true
          }
        }
        Text("\(Int(settings.value.zoom * 100))%")
        #if DEBUG
          Text("DEV").font(.caption2.weight(.heavy)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.orange, in: Capsule())
            .help(localized("Test build: separate from the installed MarkUp and its data"))
        #endif
      }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 6)
    }
    .frame(minWidth: session.showAnnotations ? 730 : 500, minHeight: 360)
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        Button {
          settings.value.showOutline.toggle()
        } label: {
          Label(localized("Outline"), systemImage: "list.bullet.indent")
        }
        .disabled(!room.outline)
        .help(
          room.outline ? localized("Outline") : localized("Widen the window to show this panel"))
        Button {
          settings.value.showMinimap.toggle()
        } label: {
          Label(localized("Minimap"), systemImage: "sidebar.right")
        }
        .disabled(!room.minimap)
        .help(
          room.minimap ? localized("Minimap") : localized("Widen the window to show this panel"))
      }
      ToolbarItemGroup {
        Button {
          session.showSearch.toggle()
        } label: {
          Label(localized("Find"), systemImage: "magnifyingglass")
        }
        Button {
          session.zoom(-0.1)
        } label: {
          Label(localized("Zoom Out"), systemImage: "textformat.size.smaller")
        }
        Button {
          session.zoom(0.1)
        } label: {
          Label(localized("Zoom In"), systemImage: "textformat.size.larger")
        }
        Picker(localized("View Mode"), selection: $session.showSource) {
          Label(localized("Preview"), systemImage: "eye").tag(false)
          Label(localized("Source"), systemImage: "chevron.left.forwardslash.chevron.right")
            .tag(true)
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .help(localized("View Mode"))
        Menu {
          Button(localized("Highlight Yellow")) { session.addAnnotation(.highlightYellow) }
          Button(localized("Highlight Green")) { session.addAnnotation(.highlightGreen) }
          Button(localized("Highlight Blue")) { session.addAnnotation(.highlightBlue) }
          Button(localized("Underline")) { session.addAnnotation(.underline) }
          Button(localized("Show Annotations")) { session.showAnnotations.toggle() }
        } label: {
          Label(localized("Annotations"), systemImage: "highlighter")
        }
        Button {
          session.exportPresented = true
        } label: {
          Label(localized("Export PDF"), systemImage: "square.and.arrow.up")
        }
      }
    }
    .focusedSceneValue(\.readerSession, session)
    .onAppear { session.start() }
    .onDisappear { session.close() }
    .onChange(of: settings.value.renderingRelevant) { _, _ in session.render() }
    .onChange(of: session.showSource) { _, _ in session.render() }
    .onChange(of: colorScheme) { _, _ in session.render() }
    .onChange(of: session.search) { _, _ in
      session.find()
      if let range = session.matches.first { session.jump(range) }
    }
    .onChange(of: session.showSearch) { _, show in
      if !show { searchFocused = false }
    }
    .task(id: session.showSearch) {
      guard !session.showSearch else { return }
      // SwiftUI removes the field editor after onChange. Restore native reading focus
      // only after that unmount; reopening search or closing the window cancels this task.
      do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
      guard !session.showSearch, !session.isClosed, !Task.isCancelled,
        let text = session.textView
      else { return }
      text.window?.makeFirstResponder(text)
    }
    .onReceive(
      NotificationCenter.default.publisher(for: .requestDocumentSearchFocus, object: session)
    ) { _ in
      searchFocusRequest += 1
    }
    .onReceive(NotificationCenter.default.publisher(for: .clearRenderingCache)) { _ in
      session.clearCaches()
    }
    .sheet(isPresented: $session.exportPresented) { PDFOptionsView(session: session) }
    .sheet(isPresented: $session.showRecovery) { AnnotationRecoveryView(session: session) }
    .dropDestination(for: URL.self) { urls, _ in
      for url in urls
      where url.isFileURL && ["md", "markdown"].contains(url.pathExtension.lowercased()) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
      }
      return !urls.isEmpty
    }
  }

  private var searchBar: some View {
    HStack {
      TextField(localized("Find in document"), text: $session.search).textFieldStyle(.roundedBorder)
        .focused($searchFocused)
        .onSubmit { session.nextMatch(1) }
        .task(id: searchFocusRequest) {
          // The native text field must mount before SwiftUI can make its field editor
          // first responder. Repeated Cmd+F also refocuses an already visible search.
          searchFocused = false
          do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
          guard session.showSearch, !Task.isCancelled else { return }
          searchFocused = true
        }
      Text("\(session.matches.isEmpty ? 0 : session.matchIndex + 1) / \(session.matches.count)")
        .monospacedDigit()
      Button {
        session.nextMatch(-1)
      } label: {
        Image(systemName: "chevron.up")
      }.accessibilityLabel(localized("Find Previous"))
      Button {
        session.nextMatch(1)
      } label: {
        Image(systemName: "chevron.down")
      }.accessibilityLabel(localized("Find Next"))
      Button(localized("Done")) { session.showSearch = false }
    }.padding(10)
  }
  private var outline: some View {
    List(session.document?.headings ?? [], id: \.id) { heading in
      Button {
        session.jumpToHeading(heading.id)
      } label: {
        Text(heading.title).lineLimit(2).padding(.leading, CGFloat(heading.level - 1) * 10)
      }.buttonStyle(.plain).accessibilityLabel("H\(heading.level): \(heading.title)")
    }.listStyle(.sidebar).frame(width: 210).accessibilityLabel(localized("Heading outline"))
  }
  private var annotationPanel: some View {
    VStack(alignment: .leading) {
      HStack {
        Text(localized("Annotations")).font(.headline)
        Spacer()
        Button {
          session.showAnnotations = false
        } label: {
          Image(systemName: "xmark")
        }.accessibilityLabel(localized("Close"))
      }.padding()
      if session.annotations.isEmpty {
        Text(localized("Select text to highlight or underline it.")).foregroundStyle(.secondary)
          .padding()
      }
      Button(localized("Recover Annotations…")) { session.loadRecoveryDocuments() }.padding(
        .horizontal)
      List(session.annotations) { annotation in
        VStack(alignment: .leading, spacing: 6) {
          Text(annotation.anchor.exactText).lineLimit(4)
          if session.unresolved.contains(where: { $0.id == annotation.id }) {
            Label(
              localized("Unmatched — preserved for recovery"), systemImage: "exclamationmark.circle"
            )
            .font(.caption)
          }
          Button(localized("Remove"), role: .destructive) { session.removeAnnotation(annotation) }
        }
      }
    }.frame(width: 230)
  }
}

extension Notification.Name {
  static let requestDocumentSearchFocus = Notification.Name("MarkUp.requestDocumentSearchFocus")
}

extension ReaderPreferences {
  /// Panel visibility and access settings never change the rendered document.
  var renderingRelevant: ReaderPreferences {
    var copy = self
    copy.showMinimap = false
    copy.showOutline = false
    copy.allowRemoteImages = false
    copy.externalEditorBookmark = nil
    return copy
  }
}
