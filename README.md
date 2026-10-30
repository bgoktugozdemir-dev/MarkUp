# MarkUp

A native, typography-led Markdown reader for macOS 14 and later. Built with SwiftUI, AppKit, Swift Markdown, and the native text system. Source files are read-only; editing belongs in your chosen external editor.

**Development status:** V1 is implemented and available for local review, with measured warm-open, reload and idle-CPU performance exceptions. This repository is not yet a signed, notarized public release. See [verification](docs/VERIFICATION.md) for executed checks and remaining gates. The development icon is temporary.

## Build and run

Requirements: Xcode 26 or later with Swift 6.2 or later (Swift Markdown 0.9.0 requires Swift tools 6.2), macOS 14+, and XcodeGen 2.46.0. The implementation was first built using Xcode 27.1 / Swift 6.4. Both Apple Silicon and Intel slices are required.

```sh
git clone <your MarkUp repository URL>
cd MarkUp
xcodegen generate
open MarkUp.xcodeproj
```

Choose the **MarkUp** scheme. For a credential-free local run, select **Sign to Run Locally** for Debug, or use the command below with `CODE_SIGN_IDENTITY=-`. A Developer ID certificate is not needed for this ad-hoc Debug build. Debug alone permits library loading for Sparkle's pre-signed framework; Release retains Hardened Runtime library validation.

```sh
swift test
python3 scripts/localize.py
bash scripts/check-native-services.sh
xcodebuild -project MarkUp.xcodeproj -scheme MarkUp \
  -destination 'generic/platform=macOS' -configuration Debug \
  -derivedDataPath build/DerivedData ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build
```

`ONLY_ACTIVE_ARCH=NO` is supplied on the command line so Swift Package dependencies also build both architectures. See [setup](docs/SETUP.md) for tests and artifacts.

## Reading

- Open `.md` and `.markdown` files from Finder, the Open command, or drag-and-drop. Each document has its own window; macOS can merge windows into tabs.
- Read CommonMark/GFM prose, headings, nested lists, tables, tasks, footnotes, and all five GitHub alerts.
- Select native text across the document. Search, heading outline, semantic reading positions, and a left minimap support navigation.
- Choose body, heading, and code fonts; adjust size, spacing, width, and zoom. Choose six independent code-theme families with nine palettes.
- Highlight or underline text without changing source bytes. Durable annotations are stored in Application Support; ambiguous marks remain available for recovery.
- Double-click a loaded image to inspect it in a resizable native preview.
- Export selectable multi-page PDF or print. Personal annotations are excluded by default.
- Read in English by default or explicitly choose Turkish in Settings. System-owned dialogs may require restarting to change language.

Remote images are blocked by default. Use **Reading → Load Remote Images** for the current document, or explicitly enable them in Settings. Relative local resources and linked documents require user-selected folder access; MarkUp does not infer permission from a Markdown path.

Mermaid is intentionally readable, copyable source in V1. Math and MDX are not executed. Unsupported HTML stays visible; scripts, event handlers, styles, and embedded applications never execute. Details/summary content is expanded for reading.

## Project guide

- [Architecture and safety invariants](docs/ARCHITECTURE.md)
- [Content compatibility](docs/COMPATIBILITY.md), [executed verification](docs/VERIFICATION.md), and [Release measurements](docs/PERFORMANCE.md)
- [Keyboard shortcuts](docs/SHORTCUTS.md)
- [Signing and releases](docs/RELEASING.md), [Türkçe kurulum](docs/OWNER_SETUP_TR.md)
- [Privacy and security](SECURITY.md)
- [Contributing](CONTRIBUTING.md), [third-party notices](THIRD_PARTY_NOTICES.md)

No analytics, accounts, cloud synchronization, or document uploads. MIT licensed. Theme names describe inspiration and do not imply affiliation with their original products.
