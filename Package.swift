// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MarkUp",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MarkUpCore", targets: ["MarkUpCore"])],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
        .package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.9.0")
    ],
    targets: [
        .target(name: "MarkUpCore", dependencies: [.product(name: "Markdown", package: "swift-markdown"),
                                                   .product(name: "cmark-gfm", package: "swift-cmark")],
                resources: [.process("Highlighting/Resources")]),
        .testTarget(name: "MarkUpCoreTests", dependencies: ["MarkUpCore"])
    ],
    swiftLanguageModes: [.v6]
)
