import AppKit
import MarkUpCore
import SwiftUI

@MainActor @Observable final class AppSettings {
  static let shared = AppSettings()
  var value: ReaderPreferences {
    didSet {
      if let data = try? JSONEncoder().encode(value.validated()) {
        UserDefaults.standard.set(data, forKey: "readerPreferences")
        UserDefaults.standard.set([value.language.rawValue], forKey: "AppleLanguages")
      }
    }
  }
  var storageCount = 0
  var storageBytes: Int64 = 0
  var message: String?
  private init() {
    value =
      UserDefaults.standard.data(forKey: "readerPreferences")
      .flatMap { try? ReaderPreferences.decode($0) } ?? ReaderPreferences()
  }
  var colorScheme: ColorScheme? {
    switch value.appearance {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

@MainActor func localized(_ key: String) -> String {
  let language = AppSettings.shared.value.language.rawValue
  guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
    let bundle = Bundle(path: path)
  else { return key }
  return bundle.localizedString(forKey: key, value: key, table: nil)
}

@MainActor func localizedCount(_ key: String, _ count: Int) -> String {
  String.localizedStringWithFormat(localized(key), CInt(clamping: count))
}

@MainActor struct SettingsView: View {
  @Environment(\.colorScheme) private var colorScheme
  @State private var settings = AppSettings.shared
  @State private var confirmingClear = false
  @State private var fonts = NSFontManager.shared.availableFontFamilies.sorted()

  var body: some View {
    TabView {
      Form {
        Picker(localized("Language"), selection: $settings.value.language) {
          Text("English").tag(AppLanguage.en)
          Text("Türkçe").tag(AppLanguage.tr)
        }
        Text(
          localized(
            "App controls change immediately. Restart to update system-owned menus and dialogs.")
        )
        .font(.caption).foregroundStyle(.secondary)
        Picker(localized("Appearance"), selection: $settings.value.appearance) {
          Text(localized("System")).tag(AppAppearance.system)
          Text(localized("Light")).tag(AppAppearance.light)
          Text(localized("Dark")).tag(AppAppearance.dark)
        }
        Toggle(localized("Show minimap"), isOn: $settings.value.showMinimap)
        Toggle(localized("Show outline"), isOn: $settings.value.showOutline)
        Toggle(localized("Allow remote images by default"), isOn: $settings.value.allowRemoteImages)
        Text(
          localized(
            "Remote images can disclose your IP address to their host. Local documents are never uploaded."
          )
        )
        .font(.caption).foregroundStyle(.secondary)
        Button(localized("Choose External Editor…")) { chooseEditor() }
        Toggle(
          localized("Automatically check for updates"),
          isOn: Binding(
            get: { UpdateService.shared.automaticChecks },
            set: { UpdateService.shared.setAutomaticChecks($0) })
        )
        .disabled(!UpdateService.shared.isConfigured)
        Button(localized("Check for Updates…")) { UpdateService.shared.check() }
      }.tabItem { Label(localized("General"), systemImage: "gearshape") }
      ScrollView {
        Form {
          fontPicker("Body Font", selection: $settings.value.bodyFont)
          weightPicker(
            "Body Weight",
            selection: Binding(
              get: { settings.value.bodyWeight ?? .regular },
              set: { settings.value.bodyWeight = $0 }))
          sizeSlider("Body Size", value: $settings.value.bodySize, range: 8...48)
          fontPicker("Heading Font", selection: $settings.value.headingFont)
          weightPicker(
            "Heading Weight",
            selection: Binding(
              get: { settings.value.headingWeight ?? .bold },
              set: { settings.value.headingWeight = $0 }))
          ForEach(0..<6, id: \.self) { index in
            sizeSlider("H\(index + 1)", value: $settings.value.headingSizes[index], range: 8...72)
          }
          fontPicker("Code Font", selection: $settings.value.codeFont)
          sizeSlider("Code Size", value: $settings.value.codeSize, range: 8...48)
          sizeSlider("Line Spacing", value: $settings.value.lineSpacing, range: 0...30)
          sizeSlider("Paragraph Spacing", value: $settings.value.paragraphSpacing, range: 0...60)
          sizeSlider("Reading Width", value: $settings.value.contentWidth, range: 320...1400)
          Text(localized("A calm place to read. Türkçe: İı Şş Ğğ — 123"))
            .font(
              settings.value.bodyFont == "System"
                ? .system(size: settings.value.bodySize)
                : .custom(settings.value.bodyFont, size: settings.value.bodySize)
            )
            .fontWeight(swiftUIWeight(settings.value.bodyWeight ?? .regular))
          Text(localized("Heading preview"))
            .font(
              settings.value.headingFont == "System"
                ? .system(size: settings.value.headingSizes[1])
                : .custom(settings.value.headingFont, size: settings.value.headingSizes[1])
            )
            .fontWeight(swiftUIWeight(settings.value.headingWeight ?? .bold))
          Button(localized("Reset Typography")) {
            let defaults = ReaderPreferences()
            settings.value.bodyFont = defaults.bodyFont
            settings.value.headingFont = defaults.headingFont
            settings.value.codeFont = defaults.codeFont
            settings.value.bodyWeight = defaults.bodyWeight
            settings.value.headingWeight = defaults.headingWeight
            settings.value.bodySize = defaults.bodySize
            settings.value.headingSizes = defaults.headingSizes
            settings.value.codeSize = defaults.codeSize
            settings.value.lineSpacing = defaults.lineSpacing
            settings.value.paragraphSpacing = defaults.paragraphSpacing
            settings.value.contentWidth = defaults.contentWidth
          }
        }
      }.tabItem { Label(localized("Typography"), systemImage: "textformat") }
      Form {
        Picker(localized("Code Theme"), selection: $settings.value.codeThemeID) {
          ForEach(CodeTheme.all) { theme in Text(theme.name).tag(theme.id) }
        }
        Toggle(
          localized("Automatically pair light and dark themes"),
          isOn: $settings.value.automaticTheme)
        Toggle(localized("Wrap code"), isOn: $settings.value.wrapCode)
        Toggle(
          localized("Show long code blocks in short view"),
          isOn: Binding(
            get: { settings.value.limitCodeHeight ?? true },
            set: { settings.value.limitCodeHeight = $0 }))
        Toggle(localized("Show line numbers"), isOn: $settings.value.lineNumbers)
        ThemePreview(
          theme: previewTheme, fontName: settings.value.codeFont, fontSize: settings.value.codeSize)
        Button(localized("Reset Code Settings")) {
          let defaults = ReaderPreferences()
          settings.value.codeThemeID = defaults.codeThemeID
          settings.value.automaticTheme = defaults.automaticTheme
          settings.value.wrapCode = defaults.wrapCode
          settings.value.limitCodeHeight = defaults.limitCodeHeight
          settings.value.lineNumbers = defaults.lineNumbers
        }
      }.tabItem { Label(localized("Code"), systemImage: "curlybraces") }
      Form {
        Text(localizedCount("annotation_count", settings.storageCount))
        Text(
          "\(localized("Storage")): \(ByteCountFormatter.string(fromByteCount: settings.storageBytes, countStyle: .file))"
        )
        Button(localized("Clear All Annotations…"), role: .destructive) { confirmingClear = true }
        Button(localized("Clear Rendering Cache")) {
          NotificationCenter.default.post(name: .clearRenderingCache, object: nil)
          settings.message = localized("Rendering cache cleared.")
        }
        Divider()
        Button(localized("Export Preferences…")) { exportPreferences() }
        Button(localized("Import Preferences…")) { importPreferences() }
        if let message = settings.message { Text(message).foregroundStyle(.secondary) }
      }.tabItem { Label(localized("Data"), systemImage: "externaldrive") }
    }
    .formStyle(.grouped)
    .padding(16)
    .frame(width: 620, height: 570)
    .preferredColorScheme(settings.colorScheme)
    .confirmationDialog(
      localized("Clear all annotations in every document?"), isPresented: $confirmingClear
    ) {
      Button(localized("Clear All Annotations"), role: .destructive) {
        Task {
          do {
            let store = try await Services.shared.annotationStore()
            _ = try await store.clearAll()
            await refreshStorage()
          } catch {
            settings.message = localized(
              "Annotation storage could not be updated. Your documents were not changed.")
          }
        }
      }
    } message: {
      Text(
        localized(
          "This permanently removes highlights and underlines, including recovery copies. Documents and preferences are kept."
        ))
    }
    .task { await refreshStorage() }
  }

  private func fontPicker(_ title: String, selection: Binding<String>) -> some View {
    Picker(localized(title), selection: selection) {
      Text(localized("System")).tag("System")
      ForEach(fonts, id: \.self) { Text($0).tag($0) }
    }
  }
  private var previewTheme: CodeTheme {
    let selected = CodeTheme.theme(id: settings.value.codeThemeID)
    let dark =
      switch settings.value.appearance {
      case .light: false
      case .dark: true
      case .system: colorScheme == .dark
      }
    return settings.value.automaticTheme ? selected.matchingAppearance(dark: dark) : selected
  }
  private func weightPicker(_ title: String, selection: Binding<TextWeight>) -> some View {
    Picker(localized(title), selection: selection) {
      ForEach(TextWeight.allCases, id: \.self) { weight in
        Text(localized(weight.rawValue.capitalized)).tag(weight)
      }
    }
  }
  private func swiftUIWeight(_ weight: TextWeight) -> Font.Weight {
    switch weight {
    case .regular: .regular
    case .medium: .medium
    case .semibold: .semibold
    case .bold: .bold
    }
  }
  private func sizeSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>)
    -> some View
  {
    HStack {
      Text(localized(title)).frame(width: 130, alignment: .leading)
      Slider(value: value, in: range, step: 1)
        .accessibilityLabel(localized(title))
      Text("\(Int(value.wrappedValue))").monospacedDigit().frame(width: 42)
    }
  }
  private func refreshStorage() async {
    guard let store = try? await Services.shared.annotationStore() else { return }
    settings.storageCount = await store.count
    settings.storageBytes = (try? await store.storageBytes()) ?? 0
  }
  private func chooseEditor() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    settings.value.externalEditorBookmark = try? url.bookmarkData(
      options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
  }
  private func exportPreferences() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "MarkUp-preferences.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try settings.value.exported().write(to: url, options: .atomic) } catch {
      settings.message = localized("Preferences could not be exported.")
    }
  }
  private func importPreferences() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      let bounded = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
      var imported = try ReaderPreferences.decode(bounded)
      guard CodeTheme.all.contains(where: { $0.id == imported.codeThemeID }) else {
        throw PreferenceError.invalidValues
      }
      imported.externalEditorBookmark = settings.value.externalEditorBookmark
      settings.value = imported
    } catch {
      settings.message = localized(
        "This preference file is invalid or uses an unsupported version.")
    }
  }
}

private struct ThemePreview: View {
  let theme: CodeTheme
  let fontName: String
  let fontSize: Double
  @State private var tokens: [SyntaxToken] = []
  private let sample = "@Observable\nfinal class Reader {\n    let title = \"MarkUp\"\n}"
  private var preview: AttributedString {
    let font =
      NSFont(name: fontName, size: fontSize)
      ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    let text = NSMutableAttributedString(
      string: sample, attributes: [.font: font, .foregroundColor: NSColor(hex: theme.foreground)])
    for token in tokens
    where token.range.location >= 0 && token.range.length <= text.length - token.range.location {
      text.addAttribute(
        .foregroundColor, value: NSColor(hex: theme.color(for: token.kind)), range: token.range)
    }
    return AttributedString(text)
  }
  var body: some View {
    Text(preview)
      .padding().frame(maxWidth: .infinity, alignment: .leading)
      .background(
        Color(nsColor: NSColor(hex: theme.background)), in: RoundedRectangle(cornerRadius: 10)
      )
      .task { tokens = (try? await SyntaxHighlighter().highlight(sample, language: "swift")) ?? [] }
  }
}

extension Notification.Name {
  static let clearRenderingCache = Notification.Name("MarkUp.clearRenderingCache")
}

actor Services {
  static let shared = Services()
  private var annotations: AnnotationStore?
  func annotationStore() throws -> AnnotationStore {
    if let annotations { return annotations }
    let store = try AnnotationStore()
    annotations = store
    return store
  }
}
