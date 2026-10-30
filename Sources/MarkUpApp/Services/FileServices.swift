import AppKit
import ImageIO
import MarkUpCore
import UniformTypeIdentifiers

struct LoadedDocument: Sendable {
  let source: String
  let identity: AnnotationDocumentIdentity?
}

actor DocumentLoader {
  func read(_ url: URL) throws -> LoadedDocument {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var before = stat()
    guard fstat(handle.fileDescriptor, &before) == 0 else { throw CocoaError(.fileReadUnknown) }
    let data = try handle.read(upToCount: DocumentInput.maximumBytes + 1) ?? Data()
    var after = stat()
    guard fstat(handle.fileDescriptor, &after) == 0,
      before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
    else { throw CocoaError(.fileReadUnknown) }
    try Task.checkCancellation()
    let identity =
      "\(before.st_dev):\(before.st_ino):\(before.st_birthtimespec.tv_sec):\(before.st_birthtimespec.tv_nsec)"
    return LoadedDocument(
      source: try DocumentInput.decode(data),
      identity: AnnotationDocumentIdentity(resourceIdentifier: identity, canonicalURL: url))
  }
}

/// Sources, descriptor metadata and callbacks are main-queue owned.
@MainActor final class FileWatcher {
  private var sources: [DispatchSourceFileSystemObject] = []
  private var debounce: Task<Void, Never>?
  private var callback: (() -> Void)?
  private var revision = 0
  private var sawRename = false
  private var sawDelete = false
  private var sawRevoke = false
  private var renamedURL: URL?
  private(set) var currentURL: URL?
  private(set) var observedReplacement = false

  func watch(_ url: URL, changed: @escaping () -> Void) {
    close()
    currentURL = url
    callback = changed
    arm(url, isDocument: true)
    // A parent descriptor requires its own user grant. No polling silently broadens access.
    arm(url.deletingLastPathComponent(), isDocument: false)
  }

  private func arm(_ url: URL, isDocument: Bool) {
    let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return }
    let watchedRevision = revision
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .delete, .rename, .attrib, .extend, .revoke], queue: .main)
    source.setEventHandler { [weak self, weak source] in
      let event = source?.data ?? []
      Task { @MainActor [weak self] in
        guard let self, watchedRevision == self.revision else { return }
        if isDocument {
          self.sawRename = self.sawRename || event.contains(.rename)
          self.sawDelete = self.sawDelete || event.contains(.delete)
          self.sawRevoke = self.sawRevoke || event.contains(.revoke)
          if event.contains(.rename) {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if fcntl(descriptor, F_GETPATH, &buffer) == 0 {
              let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
              self.renamedURL = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
            }
          }
        }
        self.schedule()
      }
    }
    source.setCancelHandler { Darwin.close(descriptor) }
    sources.append(source)
    source.resume()
  }

  private func schedule() {
    debounce?.cancel()
    let expected = revision
    debounce = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
      guard let self, expected == revision, let original = currentURL, let callback else { return }
      let originalExists = FileManager.default.fileExists(atPath: original.path)
      // Atomic writes can emit delete rather than rename for the old inode. Preserve the
      // active logical document only when the replacement already exists in this coalesced
      // event. Once absence has been observed, later recreation is a new identity.
      observedReplacement = (sawRename || sawDelete) && !sawRevoke && originalExists
      if !originalExists, sawRename, !sawDelete, let renamedURL,
        FileManager.default.fileExists(atPath: renamedURL.path)
      {
        currentURL = renamedURL
      }
      revision += 1
      for source in sources { source.cancel() }
      sources.removeAll()
      sawRename = false
      sawDelete = false
      sawRevoke = false
      renamedURL = nil
      if let currentURL {
        arm(currentURL, isDocument: true)
        arm(currentURL.deletingLastPathComponent(), isDocument: false)
      }
      callback()
    }
  }

  func close() {
    revision += 1
    debounce?.cancel()
    debounce = nil
    for source in sources { source.cancel() }
    sources.removeAll()
    callback = nil
    currentURL = nil
    sawRename = false
    sawDelete = false
    sawRevoke = false
    renamedURL = nil
    observedReplacement = false
  }
}

enum ImageFailure: Error { case denied, unsupported, tooLarge, failed }

enum ImageRequestPolicy {
  static func allows(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
      let rawHost = url.host?.lowercased(), !rawHost.isEmpty
    else { return false }
    let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    guard host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local") else {
      return false
    }
    // Literal IPv6 addresses must be global unicast (2000::/3); mapped/local ranges are denied.
    if host.contains(":"), !host.hasPrefix("2"), !host.hasPrefix("3") { return false }
    let octets = host.split(separator: ".").compactMap { UInt8($0) }
    if octets.count == 4 {
      if [0, 10, 127].contains(octets[0]) || octets[0] >= 224 { return false }
      if octets[0] == 169 && octets[1] == 254 { return false }
      if octets[0] == 172 && (16...31).contains(octets[1]) { return false }
      if octets[0] == 192 && octets[1] == 168 { return false }
    }
    return true
  }
}

private actor ImageRedirectBudget {
  private var counts: [Int: Int] = [:]
  func allow(_ taskID: Int) -> Bool {
    let count = (counts[taskID] ?? 0) + 1
    counts[taskID] = count
    return count <= 5
  }
  func remove(_ taskID: Int) { counts[taskID] = nil }
}

/// Immutable delegate; redirect counters are isolated in their own actor.
private final class ImageRequestDelegate: NSObject, URLSessionTaskDelegate {
  private let redirects = ImageRedirectBudget()

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    guard let url = request.url, ImageRequestPolicy.allows(url),
      await redirects.allow(task.taskIdentifier)
    else { return nil }
    var clean = request
    clean.setValue(nil, forHTTPHeaderField: "Authorization")
    clean.setValue(nil, forHTTPHeaderField: "Cookie")
    clean.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
    return clean
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    Task { await redirects.remove(task.taskIdentifier) }
  }

  func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
    -> (URLSession.AuthChallengeDisposition, URLCredential?)
  {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      return (.performDefaultHandling, nil)
    }
    return (.cancelAuthenticationChallenge, nil)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
  ) async
    -> (URLSession.AuthChallengeDisposition, URLCredential?)
  {
    await urlSession(session, didReceive: challenge)
  }
}

actor ImageLoader {
  private var cache: [URL: Data] = [:]
  private var cacheBytes = 0
  private let maximumBytes = 8 * 1024 * 1024
  private var session: URLSession?

  private func remoteSession() -> URLSession {
    if let session { return session }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 30
    configuration.httpMaximumConnectionsPerHost = 2
    let created = URLSession(
      configuration: configuration, delegate: ImageRequestDelegate(), delegateQueue: nil)
    session = created
    return created
  }

  func load(_ raw: String, document: URL, roots: [URL], remoteAllowed: Bool) async throws -> Data {
    let url: URL
    if let external = ResourcePolicy.externalURL(raw) {
      guard remoteAllowed, ImageRequestPolicy.allows(external) else { throw ImageFailure.denied }
      url = external
    } else {
      guard let local = ResourcePolicy.localURL(raw, relativeTo: document, grantedRoots: roots)
      else {
        throw ImageFailure.denied
      }
      url = local
    }
    if let cached = cache[url] { return cached }
    let data: Data
    if url.isFileURL {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    } else {
      var request = URLRequest(url: url)
      request.timeoutInterval = 15
      let (bytes, response) = try await remoteSession().bytes(for: request)
      guard let response = response as? HTTPURLResponse, response.statusCode == 200,
        response.url.map(ImageRequestPolicy.allows) == true,
        response.expectedContentLength <= maximumBytes
      else { throw ImageFailure.failed }
      var result = Data()
      for try await byte in bytes {
        guard result.count < maximumBytes else { throw ImageFailure.tooLarge }
        result.append(byte)
        if result.count % 8192 == 0 { try Task.checkCancellation() }
      }
      data = result
    }
    guard data.count <= maximumBytes else { throw ImageFailure.tooLarge }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 16000, height <= 16000, width * height <= 40_000_000
    else { throw ImageFailure.unsupported }
    try Task.checkCancellation()
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 2048,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    else { throw ImageFailure.unsupported }
    let result = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        result, UTType.png.identifier as CFString, 1, nil)
    else {
      throw ImageFailure.failed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ImageFailure.failed }
    let output = result as Data
    if cacheBytes + output.count > 24 * 1024 * 1024 {
      cache.removeAll()
      cacheBytes = 0
    }
    cache[url] = output
    cacheBytes += output.count
    return output
  }

  func clear() {
    cache.removeAll()
    cacheBytes = 0
  }
  func close() {
    session?.invalidateAndCancel()
    session = nil
    clear()
  }
}

@MainActor final class AccessGrants {
  private(set) var roots: [URL] = []
  private var scoped: [URL] = []
  private(set) var restorationFailures = 0

  func grantFolder() -> Bool {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = localized("Grant Access")
    panel.message = localized(
      "Choose a folder to allow local images, linked documents, and reliable replacement-save monitoring."
    )
    guard panel.runModal() == .OK, let url = panel.url else { return false }
    guard add(url) else { return false }
    if let bookmark = try? url.bookmarkData(
      options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    {
      var saved = UserDefaults.standard.array(forKey: "folderBookmarks") as? [Data] ?? []
      if !saved.contains(bookmark) { saved.append(bookmark) }
      UserDefaults.standard.set(saved, forKey: "folderBookmarks")
    }
    return true
  }

  func restore() {
    restorationFailures = 0
    var updated: [Data] = []
    for data in UserDefaults.standard.array(forKey: "folderBookmarks") as? [Data] ?? [] {
      do {
        var stale = false
        let url = try URL(
          resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard add(url) else { throw ImageFailure.denied }
        if stale {
          updated.append(
            try url.bookmarkData(
              options: .withSecurityScope,
              includingResourceValuesForKeys: nil, relativeTo: nil))
        } else {
          updated.append(data)
        }
      } catch {
        // Preserve the original grant for explicit user recovery; never broaden it.
        updated.append(data)
        restorationFailures += 1
      }
    }
    UserDefaults.standard.set(updated, forKey: "folderBookmarks")
  }

  @discardableResult
  private func add(_ url: URL) -> Bool {
    guard !roots.contains(url) else { return true }
    let accessed = url.startAccessingSecurityScopedResource()
    guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
      FileManager.default.isReadableFile(atPath: url.path)
    else {
      if accessed { url.stopAccessingSecurityScopedResource() }
      return false
    }
    if accessed { scoped.append(url) }
    roots.append(url)
    return true
  }

  func close() {
    for url in scoped { url.stopAccessingSecurityScopedResource() }
    scoped.removeAll()
    roots.removeAll()
  }
}
