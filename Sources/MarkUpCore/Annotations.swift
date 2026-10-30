import CryptoKit
import Darwin
import Foundation

public enum AnnotationError: Error, Equatable, Sendable {
  case invalidRange
  case emptySelection
  case staleEpoch
  case unknownDocument
  case invalidIdentityContinuation
  case unsupportedVersion(Int)
  case corruptStorage
  case recoveryRequired
}

public struct TextAnchor: Codable, Equatable, Sendable {
  public let exactText: String
  public let prefix: String
  public let suffix: String
  public let utf16Location: Int
  public let contentDigest: String

  public init(
    exactText: String, prefix: String, suffix: String, utf16Location: Int, contentDigest: String
  ) {
    self.exactText = exactText
    self.prefix = prefix
    self.suffix = suffix
    self.utf16Location = utf16Location
    self.contentDigest = contentDigest
  }

  public static func capture(in text: String, range: NSRange) throws -> TextAnchor {
    guard range.location >= 0, range.length > 0 else { throw AnnotationError.emptySelection }
    guard range.location <= text.utf16.count,
      range.length <= text.utf16.count - range.location,
      let swiftRange = Range(range, in: text),
      (text as NSString).rangeOfComposedCharacterSequences(for: range) == range
    else { throw AnnotationError.invalidRange }
    return TextAnchor(
      exactText: String(text[swiftRange]),
      prefix: String(text[..<swiftRange.lowerBound].suffix(48)),
      suffix: String(text[swiftRange.upperBound...].prefix(48)),
      utf16Location: range.location,
      contentDigest: digest(text)
    )
  }

  static func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

}

public enum AnchorResolution: Equatable, Sendable {
  case resolved(NSRange)
  case missing
  case ambiguous
}

public enum AnchorResolver {
  /// Reattaches only exact text with complete available context. Position never resolves ambiguity.
  public static func resolve(_ anchor: TextAnchor, in text: String) -> AnchorResolution {
    resolve(anchor, in: text, digest: TextAnchor.digest(text))
  }

  /// Resolve a document snapshot off the UI actor; compute its digest only once.
  public static func resolveAll(_ anchors: [TextAnchor], in text: String) throws
    -> [AnchorResolution]
  {
    let digest = TextAnchor.digest(text)
    return try anchors.map { anchor in
      try Task.checkCancellation()
      return resolve(anchor, in: text, digest: digest)
    }
  }

  private static func resolve(_ anchor: TextAnchor, in text: String, digest: String)
    -> AnchorResolution
  {
    guard !anchor.exactText.isEmpty, anchor.utf16Location >= 0 else { return .missing }
    let source = text as NSString
    let targetLength = anchor.exactText.utf16.count
    if anchor.contentDigest == digest,
      anchor.utf16Location <= source.length,
      targetLength <= source.length - anchor.utf16Location
    {
      let range = NSRange(location: anchor.utf16Location, length: targetLength)
      if source.substring(with: range) == anchor.exactText,
        Range(range, in: text) != nil,
        source.rangeOfComposedCharacterSequences(for: range) == range
      {
        return .resolved(range)
      }
    }
    var matches: [NSRange] = []
    var searchRange = text.startIndex..<text.endIndex
    while let candidate = text.range(of: anchor.exactText, options: .literal, range: searchRange) {
      let range = NSRange(candidate, in: text)
      if text[..<candidate.lowerBound].hasSuffix(anchor.prefix),
        text[candidate.upperBound...].hasPrefix(anchor.suffix),
        source.rangeOfComposedCharacterSequences(for: range) == range
      {
        matches.append(range)
        if matches.count > 1 { return .ambiguous }
      }
      guard candidate.lowerBound < text.endIndex else { break }
      searchRange = text.index(after: candidate.lowerBound)..<text.endIndex
    }
    guard let match = matches.first else { return .missing }
    // Without context, changed content does not provide sufficient evidence for reattachment.
    let meaningfulContext = (anchor.prefix + anchor.suffix).unicodeScalars.filter {
      CharacterSet.alphanumerics.contains($0)
    }.count
    guard meaningfulContext >= 12 else { return .ambiguous }
    return .resolved(match)
  }
}

public enum AnnotationStyle: String, Codable, CaseIterable, Sendable {
  case highlightYellow
  case highlightGreen
  case highlightBlue
  case underline
}

public struct TextAnnotation: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let documentID: UUID
  public let anchor: TextAnchor
  public let style: AnnotationStyle
  public let createdAt: Date

  public init(
    id: UUID = UUID(), documentID: UUID, anchor: TextAnchor, style: AnnotationStyle,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.documentID = documentID
    self.anchor = anchor
    self.style = style
    self.createdAt = createdAt
  }
}

public struct AnnotationDocumentIdentity: Codable, Equatable, Sendable {
  /// Include both the volume identity and file resource identity. Never use path or text here.
  public let resourceIdentifier: String?
  public let canonicalURL: URL

  public init(resourceIdentifier: String?, canonicalURL: URL) {
    self.resourceIdentifier = resourceIdentifier
    self.canonicalURL = canonicalURL.standardizedFileURL
  }
}

public struct AnnotationSnapshot: Equatable, Sendable {
  public let epoch: UInt64
  public let annotations: [TextAnnotation]
}

public struct AnnotationChange: Sendable {
  public let epoch: UInt64
  /// Nil means every open document must refresh (including after Clear All).
  public let documentID: UUID?
}

public struct AnnotationRecovery: Equatable, Sendable {
  public let reason: String
  public let preservedFile: URL
}

public struct AnnotationDocumentSummary: Equatable, Sendable, Identifiable {
  public let id: UUID
  public let identity: AnnotationDocumentIdentity
  public let annotationCount: Int
}

/// Serializes durable mutation. No method suspends between epoch validation and atomic persistence.
public actor AnnotationStore {
  private struct DocumentRecord: Codable {
    let id: UUID
    var identity: AnnotationDocumentIdentity
  }

  private struct Envelope: Codable {
    var version = 1
    var epoch: UInt64 = 0
    var documents: [DocumentRecord] = []
    var annotations: [TextAnnotation] = []
  }

  private let directory: URL
  private let storageURL: URL
  private var state: Envelope
  private var observers: [UUID: AsyncStream<AnnotationChange>.Continuation] = [:]
  public private(set) var recovery: AnnotationRecovery?

  public init(directory: URL? = nil) throws {
    let base: URL
    if let directory {
      base = directory
    } else {
      base = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true
      )
      .appendingPathComponent("MarkUp", isDirectory: true)
      .appendingPathComponent("Annotations", isDirectory: true)
    }
    self.directory = base
    storageURL = base.appendingPathComponent("annotations.json")
    try FileManager.default.createDirectory(
      at: base, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
    state = Envelope()
    if FileManager.default.fileExists(atPath: storageURL.path) {
      do {
        let size = try storageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64 * 1024 * 1024 else { throw AnnotationError.corruptStorage }
        let bytes = try Data(contentsOf: storageURL)
        let loaded = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard loaded.version == 1 else { throw AnnotationError.unsupportedVersion(loaded.version) }
        guard Set(loaded.documents.map(\.id)).count == loaded.documents.count,
          Set(loaded.annotations.map(\.id)).count == loaded.annotations.count,
          loaded.annotations.allSatisfy({ annotation in
            loaded.documents.contains { $0.id == annotation.documentID }
          })
        else { throw AnnotationError.corruptStorage }
        state = loaded
      } catch {
        let preserved = base.appendingPathComponent("recovery-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: storageURL, to: preserved)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: preserved.path)
        recovery = AnnotationRecovery(
          reason: error is DecodingError ? "corruptStorage" : String(describing: error),
          preservedFile: preserved)
      }
    }
  }

  public func documentID(
    for identity: AnnotationDocumentIdentity, continuing existingID: UUID? = nil,
    observedReplacement: Bool = false
  ) throws -> UUID {
    try ensureWritable()
    if let existingID {
      guard let index = state.documents.firstIndex(where: { $0.id == existingID }) else {
        throw AnnotationError.unknownDocument
      }
      let previous = state.documents[index].identity
      let sameResource =
        identity.resourceIdentifier != nil
        && identity.resourceIdentifier == previous.resourceIdentifier
      let sameObservedPath = observedReplacement && previous.canonicalURL == identity.canonicalURL
      guard sameResource || sameObservedPath else {
        throw AnnotationError.invalidIdentityContinuation
      }
      var next = state
      next.documents[index].identity = identity
      try commit(next)
      return existingID
    }
    if let resource = identity.resourceIdentifier,
      let record = state.documents.first(where: { $0.identity.resourceIdentifier == resource })
    {
      if record.identity != identity {
        var next = state
        if let index = next.documents.firstIndex(where: { $0.id == record.id }) {
          next.documents[index].identity = identity
        }
        try commit(next)
      }
      return record.id
    }
    let id = UUID()
    var next = state
    next.documents.append(DocumentRecord(id: id, identity: identity))
    try commit(next)
    return id
  }

  public func snapshot(documentID: UUID) -> AnnotationSnapshot {
    AnnotationSnapshot(
      epoch: state.epoch, annotations: state.annotations.filter { $0.documentID == documentID })
  }

  /// Includes records that no longer match an opened file, so the UI can offer explicit recovery.
  public func documents() -> [AnnotationDocumentSummary] {
    state.documents.map { record in
      AnnotationDocumentSummary(
        id: record.id, identity: record.identity,
        annotationCount: state.annotations.filter { $0.documentID == record.id }.count)
    }
  }

  /// Only call after explicit user confirmation. Resolved paint ranges must still be revalidated.
  public func transferAnnotations(
    from sourceID: UUID, to destinationID: UUID, expectedEpoch: UInt64
  ) throws {
    try validate(documentID: sourceID, expectedEpoch: expectedEpoch)
    try validate(documentID: destinationID, expectedEpoch: expectedEpoch)
    guard sourceID != destinationID else { return }
    var next = state
    next.annotations = next.annotations.map { annotation in
      guard annotation.documentID == sourceID else { return annotation }
      return TextAnnotation(
        id: annotation.id, documentID: destinationID, anchor: annotation.anchor,
        style: annotation.style, createdAt: annotation.createdAt)
    }
    try commit(next)
    publish(nil)
  }

  @discardableResult
  public func add(
    documentID: UUID, anchor: TextAnchor, style: AnnotationStyle, expectedEpoch: UInt64
  ) throws -> TextAnnotation {
    try validate(documentID: documentID, expectedEpoch: expectedEpoch)
    guard !anchor.exactText.isEmpty, anchor.utf16Location >= 0 else {
      throw AnnotationError.invalidRange
    }
    let annotation = TextAnnotation(documentID: documentID, anchor: anchor, style: style)
    var next = state
    next.annotations.append(annotation)
    try commit(next)
    publish(documentID)
    return annotation
  }

  @discardableResult
  public func remove(id: UUID, expectedEpoch: UInt64) throws -> TextAnnotation? {
    try ensureWritable()
    guard expectedEpoch == state.epoch else { throw AnnotationError.staleEpoch }
    guard let annotation = state.annotations.first(where: { $0.id == id }) else { return nil }
    var next = state
    next.annotations.removeAll { $0.id == id }
    try commit(next)
    publish(annotation.documentID)
    return annotation
  }

  /// Undo is an epoch-checked command, so undo records from before Clear All cannot resurrect data.
  public func restore(_ annotation: TextAnnotation, expectedEpoch: UInt64) throws {
    try validate(documentID: annotation.documentID, expectedEpoch: expectedEpoch)
    guard !state.annotations.contains(where: { $0.id == annotation.id }) else { return }
    var next = state
    next.annotations.append(annotation)
    try commit(next)
    publish(annotation.documentID)
  }

  @discardableResult
  public func clearAll() throws -> UInt64 {
    // Clear is also the explicit destructive recovery action after the UI confirms it.
    var next = state
    guard next.epoch < UInt64.max else { throw AnnotationError.corruptStorage }
    next.epoch += 1
    next.annotations = []
    try commit(next)
    recovery = nil
    publish(nil)
    for entry in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    {
      let name = entry.lastPathComponent
      if (name.hasPrefix("recovery-") || name.hasPrefix(".pending-")) && name.hasSuffix(".json") {
        try FileManager.default.removeItem(at: entry)
      }
    }
    return state.epoch
  }

  public var count: Int { state.annotations.count }

  public func storageBytes() throws -> Int64 {
    try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.fileSizeKey]
    )
    .reduce(0) { total, url in
      total + Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
  }

  public func changes() -> AsyncStream<AnnotationChange> {
    let id = UUID()
    let pair = AsyncStream<AnnotationChange>.makeStream(bufferingPolicy: .bufferingNewest(1))
    observers[id] = pair.continuation
    pair.continuation.onTermination = { [weak self] _ in
      Task { await self?.removeObserver(id) }
    }
    return pair.stream
  }

  private func removeObserver(_ id: UUID) { observers[id] = nil }

  private func ensureWritable() throws {
    if recovery != nil { throw AnnotationError.recoveryRequired }
  }

  private func validate(documentID: UUID, expectedEpoch: UInt64) throws {
    try ensureWritable()
    guard state.epoch == expectedEpoch else { throw AnnotationError.staleEpoch }
    guard state.documents.contains(where: { $0.id == documentID }) else {
      throw AnnotationError.unknownDocument
    }
  }

  private func commit(_ next: Envelope) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(next)
    let temporary = directory.appendingPathComponent(".pending-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try data.write(to: temporary, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    guard Darwin.rename(temporary.path, storageURL.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    // Rename is the commit point; no throwing operations follow before publication.
    state = next
  }

  private func publish(_ documentID: UUID?) {
    // Coalescing a per-document event could hide an earlier changed document; every event
    // therefore invalidates all windows. Annotation mutations are infrequent and bounded.
    for observer in observers.values {
      observer.yield(AnnotationChange(epoch: state.epoch, documentID: nil))
    }
  }
}
