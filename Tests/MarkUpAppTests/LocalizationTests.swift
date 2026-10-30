import Foundation
import MarkUpCore
import Testing

@testable import MarkUp

struct LocalizationTests {
  @Test func explicitLanguageCatalogsUseCorrectPlurals() throws {
    for (language, singular, plural) in [
      ("en", "1 annotation", "2 annotations"), ("tr", "1 işaret", "2 işaret"),
    ] {
      let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
      let bundle = try #require(Bundle(path: path))
      let format = bundle.localizedString(forKey: "annotation_count", value: nil, table: nil)
      #expect(String.localizedStringWithFormat(format, 1) == singular)
      #expect(String.localizedStringWithFormat(format, 2) == plural)
    }
    #expect(ReaderPreferences().language == .en)
  }
}
