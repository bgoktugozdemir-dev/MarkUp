import Darwin
import Foundation
import Testing

@testable import MarkUpCore

/// Opt in with MARKUP_RUN_PERFORMANCE=1 swift test -c release --filter PerformanceTests.
/// These are core pipeline measurements, never app startup, UI latency, idle CPU, or app memory claims.
@Suite(
  .serialized, .enabled(if: ProcessInfo.processInfo.environment["MARKUP_RUN_PERFORMANCE"] == "1"))
struct PerformanceTests {
  @Test func publicFixtureCorePipelineSamples() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let fixtures = ["long-reading.md", "generated/stress-10000.md", "generated/stress-50000.md"]
    let repetitions = 3
    var results: [[String: Any]] = []
    for fixture in fixtures {
      let source = try String(
        contentsOf: root.appendingPathComponent("Fixtures").appendingPathComponent(fixture),
        encoding: .utf8)
      let parser = MarkdownParser()
      let highlighter = SyntaxHighlighter()
      var samples: [[String: Any]] = []
      var headingCount = 0
      var codeCount = 0
      for index in 0..<repetitions {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let document = try await parser.parse(source)
        let parsed = ContinuousClock.now
        let codeBlocks = flattened(document.blocks).filter { $0.kind == .code }
        var spanCount = 0
        var plainFallbackCount = 0
        for block in codeBlocks {
          do {
            spanCount += try await highlighter.highlight(block.code ?? "", language: block.language)
              .count
          } catch SyntaxHighlightingError.resourceLimit {
            plainFallbackCount += 1
          }
        }
        let completed = ContinuousClock.now
        headingCount = document.headings.count
        codeCount = codeBlocks.count
        #expect(document.source == source)
        if fixture.contains("stress-") { #expect(document.plainText.contains("END-OF-STRESS-")) }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        samples.append([
          "sample": index + 1,
          "parseMilliseconds": milliseconds(started.duration(to: parsed)),
          "tokenizeMilliseconds": milliseconds(parsed.duration(to: completed)),
          "coreTotalMilliseconds": milliseconds(started.duration(to: completed)),
          "styledSpans": spanCount,
          "oversizedCodePlainFallbacks": plainFallbackCount,
          "testProcessPeakResidentBytes": usage.ru_maxrss,
        ])
      }
      await highlighter.releaseResources()
      results.append([
        "fixture": fixture, "utf8Bytes": source.utf8.count,
        "lines": source.split(separator: "\n", omittingEmptySubsequences: false).count
          - (source.hasSuffix("\n") ? 1 : 0),
        "headings": headingCount, "codeBlocks": codeCount, "samples": samples,
      ])
    }
    #if arch(arm64)
      let architecture = "arm64"
    #elseif arch(x86_64)
      let architecture = "x86_64"
    #else
      let architecture = "other"
    #endif
    let report: [String: Any] = [
      "metricScope":
        "Core parse plus grammar tokenization; excludes disk read, native rendering, images, minimap, app startup, and display readiness.",
      "method":
        "Three sequential samples per public fixture. Parser and highlighter actors reused within fixture; first sample includes lazy VM/grammar setup; tokens recomputed each pass. No app token cache.",
      "memoryMetric":
        "Darwin getrusage(RUSAGE_SELF).ru_maxrss peak resident bytes for entire test process; cumulative across samples, not app/helper memory.",
      "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
      "hardwareModel": systemString("hw.model"), "cpu": systemString("machdep.cpu.brand_string"),
      "architectureExecuted": architecture, "logicalCPUs": ProcessInfo.processInfo.processorCount,
      "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
      "requiredBuildMode":
        "Run with swift test -c release; command invocation determines optimization.",
      "fixtures": results,
    ]
    let bytes = try JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    if let output = ProcessInfo.processInfo.environment["MARKUP_PERFORMANCE_REPORT"] {
      let url = URL(fileURLWithPath: output)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try bytes.write(to: url, options: .atomic)
    }
    print(String(decoding: bytes, as: UTF8.self))
  }

  private func flattened(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
    blocks.flatMap { [$0] + flattened($0.children) }
  }

  private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
  }

  private func systemString(_ name: String) -> String {
    var length = 0
    guard sysctlbyname(name, nil, &length, nil, 0) == 0, length > 0 else { return "unavailable" }
    var bytes = [CChar](repeating: 0, count: length)
    guard sysctlbyname(name, &bytes, &length, nil, 0) == 0 else { return "unavailable" }
    return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}
