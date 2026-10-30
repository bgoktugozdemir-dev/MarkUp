import Foundation

public enum DocumentInputError: Error, Sendable { case tooLarge, invalidEncoding, binaryInput }

public enum DocumentInput {
  public static let maximumBytes = 16 * 1024 * 1024

  public static func decode(_ data: Data) throws -> String {
    guard data.count <= maximumBytes else { throw DocumentInputError.tooLarge }
    let bytes = [UInt8](data.prefix(3))
    let text: String?
    if bytes.starts(with: [0xFF, 0xFE]) {
      guard data.count.isMultiple(of: 2) else { throw DocumentInputError.invalidEncoding }
      text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
    } else if bytes.starts(with: [0xFE, 0xFF]) {
      guard data.count.isMultiple(of: 2) else { throw DocumentInputError.invalidEncoding }
      text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
    } else {
      text = String(
        data: bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data, encoding: .utf8)
    }
    guard let text else { throw DocumentInputError.invalidEncoding }
    guard
      !text.unicodeScalars.contains(where: {
        $0.value == 0 || ($0.value < 32 && ![9, 10, 13].contains($0.value))
      })
    else {
      throw DocumentInputError.binaryInput
    }
    return text
  }
}

public enum ResourcePolicy {
  public static func externalURL(_ raw: String) -> URL? {
    guard let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
      url.host != nil, url.user == nil, url.password == nil
    else { return nil }
    return url
  }

  /// A parent directory is not a grant. Callers must supply explicit user-selected roots.
  public static func localURL(_ raw: String, relativeTo document: URL, grantedRoots: [URL]) -> URL?
  {
    guard let candidate = URL(string: raw, relativeTo: document)?.absoluteURL,
      candidate.isFileURL
    else { return nil }
    let path = candidate.standardizedFileURL.resolvingSymlinksInPath().path
    let allowed = grantedRoots.contains { root in
      let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
      return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
    return allowed ? candidate : nil
  }
}
