import AppKit
import MarkUpCore
import Observation
import SwiftUI

@MainActor @Observable final class ReaderSession {
  var url: URL?
  var source: String
  var document: MarkdownDocument?
  var rendered: RenderedDocument?
  var loading = false
  var error: String?
  var status: String?
  var search = ""
  var showSearch = false
  var matches: [NSRange] = []
  var matchIndex = 0
  var selection = NSRange(location: 0, length: 0)
  var annotations: [TextAnnotation] = []
  var unresolved: [TextAnnotation] = []
  var resolvedAnnotations: [UUID: NSRange] = [:]
  var showAnnotations = false
  var showRecovery = false
  var recoveryDocuments: [AnnotationDocumentSummary] = []
  var remoteAllowed = false
  var exportPresented = false
  var exportTask: Task<Void, Never>?
  var exportProgress: PDFExportProgress?
  var renderedRevision = 0
  var viewport = CGRect.zero
  var documentHeight = 1.0
  let minimap = MinimapTiles()
  weak var textView: NSTextView?
  let annotationUndoManager = UndoManager()
  let grants = AccessGrants()
  let images = ImageLoader()
  private let loader = DocumentLoader()
  private let parser = MarkdownParser()
  private let highlighter = SyntaxHighlighter()
  private let watcher = FileWatcher()
  private var work: Task<Void, Never>?
  private var observation: Task<Void, Never>?
  private var generation = 0
  private(set) var tokens: [String: [SyntaxToken]] = [:]
  private var documentID: UUID?
  private var annotationEpoch: UInt64 = 0
  private var annotationRefreshGeneration = 0
  private var closed = false
  private var started = false
  @ObservationIgnored private var readingLocation: (character: Int, blocks: [RenderedBlock])?
  var isClosed: Bool { closed }
  private var layoutGeneration = 0
  private var anchorWork: Task<Void, Never>?
  private var imageWork: Task<Void, Never>?
  @ObservationIgnored private var resourceCleanup: Task<Void, Never>?
  private let anchorWorker = AnnotationResolverWorker()
  private let injectedAnnotationStore: AnnotationStore?
  @ObservationIgnored private lazy var annotationHistory = makeAnnotationHistory()

  private func makeAnnotationHistory() -> AnnotationHistory {
    let injectedStore = injectedAnnotationStore
    let storeProvider: @MainActor () async throws -> AnnotationStore = {
      if let injectedStore { return injectedStore }
      return try await Services.shared.annotationStore()
    }
    let history = AnnotationHistory(
      actionName: localized("Annotations"),
      persist: { change, epoch in
        let store = try await storeProvider()
        switch change {
        case .insert(let mark): try await store.restore(mark, expectedEpoch: epoch)
        case .remove(let mark): _ = try await store.remove(id: mark.id, expectedEpoch: epoch)
        }
      },
      snapshot: { documentID in
        guard let store = try? await storeProvider() else { return nil }
        return await store.snapshot(documentID: documentID)
      },
      changed: { [weak self] marks, epoch in
        guard let self, !closed else { return }
        annotations = marks
        annotationEpoch = epoch
        resolveAnnotations()
        renderedRevision += 1
      },
      failed: { [weak self] in
        guard let self, !closed else { return }
        error = localized(
          "Annotation storage could not be updated. Your documents were not changed.")
      })
    history.undoManager = annotationUndoManager
    return history
  }

  init(url: URL?, source: String, annotationStore: AnnotationStore? = nil) {
    self.url = url
    self.source = source
    injectedAnnotationStore = annotationStore
  }

  private func annotationStoreForSession() async throws -> AnnotationStore {
    if let injectedAnnotationStore { return injectedAnnotationStore }
    return try await Services.shared.annotationStore()
  }

  func start() {
    guard !started else { return }
    started = true
    closed = false
    annotationHistory.undoManager = annotationUndoManager
    grants.restore()
    remoteAllowed = AppSettings.shared.value.allowRemoteImages
    if let url {
      watcher.watch(url) { [weak self] in
        guard let self else { return }
        self.url = watcher.currentURL
        reload(observedChange: watcher.observedReplacement)
      }
    }
    reload()
    observation = Task { [weak self] in
      guard let store = try? await self?.annotationStoreForSession() else { return }
      for await change in await store.changes() {
        guard !Task.isCancelled, let self, !closed else { break }
        if change.epoch != annotationEpoch {
          annotationEpoch = change.epoch
          annotations = []
          resolvedAnnotations = [:]
          unresolved = []
          annotationHistory.synchronize(
            documentID: documentID, annotations: [], epoch: change.epoch)
          renderedRevision += 1
          annotationUndoManager.removeAllActions()
        }
        if change.documentID == nil || change.documentID == documentID {
          await refreshAnnotations()
        }
      }
    }
  }

  func close() {
    guard !closed else { return }
    savePosition()
    closed = true
    started = false
    exportTask?.cancel()
    exportTask = nil
    PerformanceTrace.close(ObjectIdentifier(self))
    generation += 1
    work?.cancel()
    work = nil
    observation?.cancel()
    observation = nil
    anchorWork?.cancel()
    anchorWork = nil
    imageWork?.cancel()
    imageWork = nil
    annotationHistory.close()
    watcher.close()
    grants.close()
    minimap.disable()
    (textView as? ReaderTextView)?.releaseDocumentResources()
    textView = nil
    readingLocation = nil
    if url != nil { source = "" }
    document = nil
    rendered = nil
    tokens = [:]
    annotations = []
    resolvedAnnotations = [:]
    unresolved = []
    matches = []
    resourceCleanup = Task { [images, highlighter] in
      await images.close()
      await highlighter.releaseResources()
    }
  }

  func reload(observedChange: Bool = false) {
    generation += 1
    PerformanceTrace.begin(ObjectIdentifier(self), reload: document != nil)
    let expected = generation
    let fileURL = url
    let inMemorySource = source
    let continuingID = documentID
    let pendingCleanup = resourceCleanup
    work?.cancel()
    loading = true
    work = Task { [weak self] in
      guard let self else { return }
      do {
        // A retained view may restart immediately after closing. Finish that prior resource
        // teardown before a new image/highlighting job can use the same actors.
        await pendingCleanup?.value
        try Task.checkCancellation()
        guard !closed, expected == generation else { return }
        let loaded: LoadedDocument
        if let fileURL {
          loaded = try await loader.read(fileURL)
        } else {
          loaded = LoadedDocument(source: inMemorySource, identity: nil)
        }
        try Task.checkCancellation()
        let parsed = try await parser.parse(loaded.source)
        var newTokens: [String: [SyntaxToken]] = [:]
        for block in flattened(parsed.blocks) where block.kind == .code {
          try Task.checkCancellation()
          if let cached = tokens[block.id] {
            newTokens[block.id] = cached
          } else {
            newTokens[block.id] =
              (try? await highlighter.highlight(block.code ?? "", language: block.language)) ?? []
          }
        }
        guard expected == generation, !Task.isCancelled, !closed else { return }
        var newID: UUID?
        var snapshot: AnnotationSnapshot?
        var snapshotHistoryRevision: Int?
        var recovery = false
        if let identity = loaded.identity {
          do {
            let store = try await annotationStoreForSession()
            try Task.checkCancellation()
            newID = try await store.documentID(
              for: identity,
              continuing: observedChange ? continuingID : nil, observedReplacement: observedChange)
            if let newID {
              snapshotHistoryRevision = annotationHistory.revision
              snapshot = await store.snapshot(documentID: newID)
            }
            recovery = await store.recovery != nil
          } catch is CancellationError { throw CancellationError() } catch {
            recovery = true
            newID = nil
            snapshot = nil
          }
        }
        // Publish source, identity and marks as one generation only after every suspension.
        guard expected == generation, !Task.isCancelled, !closed else { return }
        documentID = newID
        annotationRefreshGeneration += 1
        if let snapshot, snapshot.epoch >= annotationEpoch {
          annotations = snapshot.annotations
          annotationEpoch = snapshot.epoch
        } else {
          annotations = []
        }
        resolvedAnnotations = [:]
        source = loaded.source
        document = parsed
        tokens = newTokens
        annotationHistory.synchronize(
          documentID: newID, annotations: annotations, epoch: annotationEpoch,
          expectedRevision: snapshotHistoryRevision)
        error =
          recovery
          ? localized(
            "Annotation storage needs recovery. Existing recovery data has been preserved; adding marks is disabled."
          ) : nil
        loading = false
        render()
      } catch is CancellationError {} catch {
        guard expected == generation, !closed else { return }
        loading = false
        self.error = localized(
          "The file could not be read. Check its location, encoding, and access permissions. The last readable version is kept."
        )
      }
    }
  }

  func render() {
    guard let document else { return }
    layoutGeneration += 1
    let next = NativeMarkdownRenderer().render(
      document: document, preferences: AppSettings.shared.value, tokens: tokens)
    if next.attributedString.string != rendered?.attributedString.string {
      resolvedAnnotations = [:]
      unresolved = []
    }
    rendered = next
    renderedRevision += 1
    find()
    resolveAnnotations()
    imageWork?.cancel()
    let expected = generation
    imageWork = Task { [weak self] in await self?.loadImages(expected: expected) }
  }

  func refreshAnnotations() async {
    annotationRefreshGeneration += 1
    let refresh = annotationRefreshGeneration
    let contentGeneration = generation
    let historyRevision = annotationHistory.revision
    guard let documentID, let store = try? await annotationStoreForSession() else { return }
    let snapshot = await store.snapshot(documentID: documentID)
    guard refresh == annotationRefreshGeneration, contentGeneration == generation,
      documentID == self.documentID, !closed, snapshot.epoch >= annotationEpoch
    else { return }
    annotationHistory.synchronize(
      documentID: documentID, annotations: snapshot.annotations, epoch: snapshot.epoch,
      expectedRevision: historyRevision)
    AppSettings.shared.storageCount = await store.count
  }

  private func resolveAnnotations() {
    guard let text = rendered?.attributedString.string else { return }
    anchorWork?.cancel()
    anchorWork = nil
    let marks = annotations
    guard !marks.isEmpty else {
      // A fresh, unmarked document needs neither a full-text digest nor another native layout.
      // Existing painted/recovery state still gets an explicit clear publication.
      if !resolvedAnnotations.isEmpty || !unresolved.isEmpty {
        resolvedAnnotations = [:]
        unresolved = []
        renderedRevision += 1
      }
      return
    }
    let expectedLayout = layoutGeneration
    let expectedEpoch = annotationEpoch
    anchorWork = Task { [weak self] in
      guard let self else { return }
      do {
        let results = try await anchorWorker.resolve(marks.map(\.anchor), text: text)
        guard !Task.isCancelled, !closed, expectedLayout == layoutGeneration,
          expectedEpoch == annotationEpoch
        else { return }
        var ranges: [UUID: NSRange] = [:]
        var missing: [TextAnnotation] = []
        for (mark, result) in zip(marks, results) {
          if case .resolved(let range) = result {
            ranges[mark.id] = range
          } else {
            missing.append(mark)
          }
        }
        guard ranges != resolvedAnnotations || missing != unresolved else { return }
        resolvedAnnotations = ranges
        unresolved = missing
        renderedRevision += 1
      } catch {}
    }
  }

  func addAnnotation(_ style: AnnotationStyle) {
    guard let text = rendered?.attributedString.string, documentID != nil, selection.length > 0
    else { return }
    let range = selection
    do {
      annotationHistory.insert(anchor: try TextAnchor.capture(in: text, range: range), style: style)
    } catch {
      self.error = localized(
        "The annotation could not be saved. Select complete characters and try again.")
    }
  }

  func removeAnnotation(_ annotation: TextAnnotation) { annotationHistory.remove(annotation) }

  func loadRecoveryDocuments() {
    Task {
      guard let store = try? await annotationStoreForSession() else { return }
      recoveryDocuments = await store.documents().filter {
        $0.id != documentID && $0.annotationCount > 0
      }
      showRecovery = true
    }
  }

  func recoverAnnotations(from previousID: UUID) {
    guard let documentID else { return }
    let epoch = annotationEpoch
    Task {
      do {
        let store = try await annotationStoreForSession()
        try await store.transferAnnotations(from: previousID, to: documentID, expectedEpoch: epoch)
        await refreshAnnotations()
      } catch {
        self.error = localized(
          "Annotations could not be recovered. The saved marks have been kept.")
      }
    }
  }

  func find() {
    matches = []
    guard let text = rendered?.attributedString.string as NSString?, !search.isEmpty else { return }
    var range = NSRange(location: 0, length: text.length)
    while range.length > 0, matches.count < 10000 {
      let match = text.range(
        of: search, options: [.caseInsensitive, .diacriticInsensitive], range: range)
      guard match.location != NSNotFound else { break }
      matches.append(match)
      range = NSRange(location: NSMaxRange(match), length: text.length - NSMaxRange(match))
    }
    matchIndex = min(matchIndex, max(0, matches.count - 1))
  }

  func nextMatch(_ direction: Int) {
    guard !matches.isEmpty else { return }
    matchIndex = (matchIndex + direction + matches.count) % matches.count
    jump(matches[matchIndex])
  }
  func jump(_ range: NSRange) {
    textView?.scrollRangeToVisible(range)
    textView?.setSelectedRange(range)
  }
  func jumpToHeading(_ anchor: String) {
    if let heading = document?.headings.first(where: { $0.id == anchor }),
      let block = rendered?.blocks.first(where: { $0.id == heading.blockID })
    {
      jump(block.range)
      return
    }
    guard let text = rendered?.attributedString else { return }
    var target: NSRange?
    text.enumerateAttribute(.markupAnchor, in: NSRange(location: 0, length: text.length)) {
      value, range, stop in
      if value as? String == anchor {
        target = range
        stop.pointee = true
      }
    }
    if let target { jump(target) }
  }
  func zoom(_ delta: Double) {
    AppSettings.shared.value.zoom = min(3, max(0.5, AppSettings.shared.value.zoom + delta))
  }

  func openLink(_ raw: String) {
    if raw.hasPrefix("#") {
      jumpToHeading(String(raw.dropFirst()).removingPercentEncoding ?? String(raw.dropFirst()))
      return
    }
    if let external = ResourcePolicy.externalURL(raw) {
      NSWorkspace.shared.open(external)
      return
    }
    guard let url,
      let target = ResourcePolicy.localURL(raw, relativeTo: url, grantedRoots: grants.roots)
    else {
      error = localized(
        "This link is unavailable or needs folder access. Use Grant Folder Access to choose its containing folder."
      )
      return
    }
    guard ["md", "markdown"].contains(target.pathExtension.lowercased()) else {
      error = localized("Only Markdown documents and HTTP(S) links can be opened.")
      return
    }
    var components = URLComponents(url: target, resolvingAgainstBaseURL: false)
    let fragment = components?.fragment
    components?.fragment = nil
    guard let file = components?.url else { return }
    if let fragment { UserDefaults.standard.set(fragment, forKey: "pendingFragment:\(file.path)") }
    NSDocumentController.shared.openDocument(withContentsOf: file, display: true) {
      [weak self] _, _, failure in
      guard failure != nil else { return }
      Task { @MainActor [weak self] in
        guard let self, !isClosed else { return }
        error = localized(
          "This link is unavailable or needs folder access. Use Grant Folder Access to choose its containing folder."
        )
      }
    }
  }

  func grantFolder() { if grants.grantFolder() { reload() } }
  func loadRemoteImages() {
    remoteAllowed = true
    let expected = generation
    Task { await loadImages(expected: expected) }
  }

  func clearCaches() {
    generation += 1
    work?.cancel()
    tokens.removeAll()
    imageWork?.cancel()
    Task { [weak self] in
      guard let self else { return }
      await images.clear()
      await highlighter.releaseResources()
      guard !closed else { return }
      reload()
    }
  }

  private func loadImages(expected: Int) async {
    guard expected == generation, !closed, !Task.isCancelled, let url, let rendered else { return }
    let expectedLayout = layoutGeneration
    var entries: [(String, NSRange)] = []
    rendered.attributedString.enumerateAttribute(
      .markupImageSource, in: NSRange(location: 0, length: rendered.attributedString.length)
    ) { value, range, _ in
      if let source = value as? String { entries.append((source, range)) }
    }
    // Allocate an attributed copy only after a real attachment has decoded successfully.
    // Missing/blocked images keep their original accessible placeholders and layout identity.
    var mutable: NSMutableAttributedString?
    var cellImageCounts: [ObjectIdentifier: Int] = [:]
    for (_, range) in entries {
      if let paragraph = rendered.attributedString.attribute(
        .paragraphStyle, at: range.location, effectiveRange: nil)
        as? NSParagraphStyle,
        let cell = paragraph.textBlocks.first as? NSTextTableBlock
      {
        cellImageCounts[ObjectIdentifier(cell), default: 0] += 1
      }
    }
    var decodedBytes = 0.0
    var unavailable = 0
    // Replace from the end so text ranges before each attachment remain valid.
    for (raw, range) in entries.prefix(64).reversed() {
      guard expected == generation, expectedLayout == layoutGeneration, !Task.isCancelled else {
        return
      }
      do {
        let data = try await images.load(
          raw, document: url, roots: grants.roots, remoteAllowed: remoteAllowed)
        guard expected == generation, expectedLayout == layoutGeneration, !Task.isCancelled,
          let image = NSImage(data: data)
        else { return }
        let estimate = image.size.width * image.size.height * 4
        guard estimate.isFinite, decodedBytes + estimate <= 32 * 1024 * 1024 else {
          unavailable += 1
          continue
        }
        decodedBytes += estimate
        let attachment = NSTextAttachment()
        image.accessibilityDescription =
          rendered.attributedString.attribute(
            .markupImageAlt, at: range.location, effectiveRange: nil) as? String
        var maxWidth = min(AppSettings.shared.value.contentWidth - 60, 600)
        if let paragraph = rendered.attributedString.attribute(
          .paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
          let cell = paragraph.textBlocks.first as? NSTextTableBlock
        {
          let count = max(1, cellImageCounts[ObjectIdentifier(cell)] ?? 1)
          let cellWidth = max(
            40,
            (AppSettings.shared.value.contentWidth - 100) / Double(cell.table.numberOfColumns) - 20)
          maxWidth = min(maxWidth, max(20, cellWidth / Double(count) - 20))
        }
        let scale = min(1, maxWidth / max(1, image.size.width))
        image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        attachment.image = image
        // Keep canonical text and indices stable: attach the image to the placeholder's first glyph.
        if range.length > 0 {
          if mutable == nil {
            mutable = NSMutableAttributedString(attributedString: rendered.attributedString)
          }
          mutable?.addAttribute(
            .attachment, value: attachment, range: NSRange(location: range.location, length: 1))
        }
      } catch {
        // Accessible placeholder remains visible.
        unavailable += 1
      }
    }
    guard expected == generation, expectedLayout == layoutGeneration, !closed, !Task.isCancelled
    else { return }
    if let mutable {
      self.rendered = RenderedDocument(attributedString: mutable, blocks: rendered.blocks)
      renderedRevision += 1
    }
    if unavailable > 0 || entries.count > 64 {
      status = localized("Some images need access or are missing, unsupported, or too large.")
    } else if status
      == localized("Some images need access or are missing, unsupported, or too large.")
    {
      status = nil
    }
  }

  func openExternalEditor() {
    guard let url else { return }
    guard let data = AppSettings.shared.value.externalEditorBookmark else {
      error = localized("Choose an external editor in Settings first.")
      return
    }
    var stale = false
    do {
      let editor = try URL(
        resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
        bookmarkDataIsStale: &stale)
      guard !stale else { throw ImageFailure.denied }
      let scope = editor.startAccessingSecurityScopedResource()
      NSWorkspace.shared.open(
        [url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()
      ) { _, _ in
        if scope { editor.stopAccessingSecurityScopedResource() }
      }
    } catch { self.error = localized("Choose an external editor again in Settings.") }
  }

  /// Keep a cheap in-memory snapshot while mounted. Resolving the semantic block and writing
  /// defaults happen only at close, independently of SwiftUI's view-dismantling order.
  func captureReadingLocation(character: Int, blocks: [RenderedBlock]) {
    guard !closed else { return }
    readingLocation = (character, blocks)
  }

  func savePosition() {
    guard let url, let location = readingLocation,
      let block = location.blocks.semanticReadingBlock(at: location.character)
    else { return }
    let offset = min(
      max(0, location.character - block.range.location), max(0, block.range.length - 1))
    UserDefaults.standard.set(
      ["block": block.id, "offset": offset], forKey: "position:\(url.path)")
  }

  func restorePosition() {
    guard let url else { return }
    if let fragment = UserDefaults.standard.string(forKey: "pendingFragment:\(url.path)") {
      UserDefaults.standard.removeObject(forKey: "pendingFragment:\(url.path)")
      jumpToHeading(fragment)
    } else {
      let key = "position:\(url.path)"
      let stored = UserDefaults.standard.dictionary(forKey: key)
      let id = stored?["block"] as? String ?? UserDefaults.standard.string(forKey: key)
      guard let id, let block = rendered?.blocks.first(where: { $0.id == id }),
        let textView, let layout = textView.layoutManager, let container = textView.textContainer
      else { return }
      let offset = min(max(0, stored?["offset"] as? Int ?? 0), max(0, block.range.length - 1))
      let character = block.range.location + offset
      let caret = NSRange(location: character, length: 0)
      // Native first-responder activation may happen after restoration and reveals its caret.
      // Move that empty caret too, otherwise AppKit scrolls the initial index zero back into view.
      textView.setSelectedRange(caret)
      selection = caret
      textView.scrollRangeToVisible(caret)
      let glyph = layout.glyphIndexForCharacter(at: character)
      guard glyph < layout.numberOfGlyphs else { return }
      let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      textView.scroll(NSPoint(x: 0, y: max(0, line.minY + textView.textContainerOrigin.y)))
    }
  }

  private func flattened(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
    blocks.flatMap { [$0] + flattened($0.children) }
  }
}

private actor AnnotationResolverWorker {
  func resolve(_ anchors: [TextAnchor], text: String) throws -> [AnchorResolution] {
    try AnchorResolver.resolveAll(anchors, in: text)
  }
}
