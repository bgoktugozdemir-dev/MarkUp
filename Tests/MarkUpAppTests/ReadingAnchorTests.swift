import Foundation
import MarkUpCore
import Testing

@testable import MarkUp

@MainActor
struct ReadingAnchorTests {
  @Test func postorderContainersDoNotReplaceNearestStableTextAnchor() {
    let blocks = [
      RenderedBlock(id: "first", range: NSRange(location: 0, length: 20), kind: .paragraph),
      RenderedBlock(id: "code", range: NSRange(location: 20, length: 40), kind: .code),
      RenderedBlock(id: "item", range: NSRange(location: 0, length: 60), kind: .listItem),
      RenderedBlock(id: "list", range: NSRange(location: 0, length: 60), kind: .list),
      RenderedBlock(id: "quote", range: NSRange(location: 0, length: 60), kind: .quote),
    ]
    #expect(blocks.semanticReadingBlock(at: 35)?.id == "code")
    #expect(blocks.semanticReadingBlock(at: 5)?.id == "first")
    #expect(blocks.semanticReadingBlock(at: 80)?.id == "code")
  }
}
