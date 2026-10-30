import Foundation

@main struct SecurityHarness {
  @MainActor static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "markup-watcher-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("document.md")
    try Data("initial".utf8).write(to: file)
    let watcher = FileWatcher()
    var events = 0
    watcher.watch(file) {
      events += 1
      FileHandle.standardError.write(
        Data(
          "event=\(events) replacement=\(watcher.observedReplacement) renamed=\(watcher.currentURL?.lastPathComponent == "renamed.md")\n"
            .utf8))
    }
    try await Task.sleep(for: .milliseconds(100))
    try Data("atomic".utf8).write(to: file, options: .atomic)
    try await Task.sleep(for: .milliseconds(700))
    precondition(watcher.observedReplacement)
    let renamed = root.appendingPathComponent("renamed.md")
    try FileManager.default.moveItem(at: file, to: renamed)
    try await Task.sleep(for: .milliseconds(700))
    precondition(watcher.currentURL?.resolvingSymlinksInPath() == renamed.resolvingSymlinksInPath())
    try FileManager.default.removeItem(at: renamed)
    try await Task.sleep(for: .milliseconds(700))
    try Data("recreated".utf8).write(to: renamed)
    try await Task.sleep(for: .milliseconds(700))
    precondition(!watcher.observedReplacement)
    watcher.close()
    let countAfterClose = events
    try Data("closed".utf8).write(to: renamed)
    try await Task.sleep(for: .milliseconds(700))
    precondition(events == countAfterClose)
    precondition(ImageRequestPolicy.allows(URL(string: "https://example.com/a.png")!))
    for raw in [
      "http://example.com/a.png", "https://localhost/a.png", "https://127.0.0.1/a.png",
      "https://10.0.0.1/a.png", "https://[::1]/a.png", "https://user:pass@example.com/a.png",
    ] {
      precondition(!ImageRequestPolicy.allows(URL(string: raw)!))
    }
    print("watcher lifecycle and image URL policy checks passed")
  }
}
