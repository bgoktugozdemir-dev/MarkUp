# Architecture and critical contracts

Status: implementation contract; verification status belongs in `TASKS.md`. A described feature is not evidence that its acceptance check passed.

## Platform and dependency direction

MarkUp is a native, read-only macOS 14+ application. Release artifacts contain arm64 and x86_64 slices. Swift 6 language mode uses explicit actor isolation rather than assuming that `async` means background work. SwiftUI owns windows, navigation, settings and commands; AppKit owns text selection, native text layout, printing and PDF page layout. No document-provided code is executed.

`App → Reader / Services / Updates → Core`. Core contains immutable, `Sendable` document values, parser adaptation, tokenization, anchor resolution and validated preferences. Core must not depend on SwiftUI/AppKit or Sparkle. Platform services may use Foundation and operating-system APIs. Updates is the sole importer of Sparkle. This is a small set of responsibility boundaries, not a plugin system.

The parser is the maintained [Swift Markdown](https://github.com/swiftlang/swift-markdown) package, backed by cmark-gfm. The integrator pins an actually resolved revision and commits `Package.resolved`. Our intermediate representation, rather than third-party AST or attributed strings, crosses task boundaries. Package licensing and transitive notices must ship with the application. A safe HTML adapter may recognize explicitly allowed tags; unsupported content remains readable source.

## Native rendering contract

The initial vertical slice must establish one continuous, selectable native document: prose, nested lists/quotes, tables, syntax-highlighted code, selection/copy and selectable PDF text. Prefer a shared `NSTextStorage` and `NSLayoutManager` with `NSTextTable` paragraphs. Reader-owned controls are overlays, never characters in the canonical document string. Text selection and copied content must not contain language labels, line-number decorations or toolbar text.

Every rendered block records a stable semantic key, canonical UTF-16 range, kind and current layout rectangle. The canonical display string is the annotation/search/navigation coordinate space. Source locations are a separate coordinate space; never use source byte offsets as `NSRange` values. Code-block models retain the original code verbatim for their Copy action. Parser extensions operate on semantic AST nodes, not global text replacements.

Independent horizontal overflow uses the same text storage and layout manager. `CodeTextContainer` supplies wide code fragments and offsets their native glyph coordinates; `CodeLayoutManager` clips glyphs and selection backgrounds to that block's viewport. Native hit-testing therefore sees the same coordinates as drawing. Code headers, original-source Copy, wrapping, line numbers and horizontal scrollers are reader-owned overlays. Code tabs use a repeating four-space interval; scrollbar extents use native used-line rectangles, excluding the full-width selection region of a terminating newline.

Wide tables use screen-owned `NSTextTable` and cell copies with absolute widths; `ReaderOverflowTable` expands the proposed table bounds while preserving each cell's column geometry. Each table has its own horizontal offset/scroller, still inside the single selectable document. PDF's separate ordinary tables are never mutated by screen scrolling. Export uses its own width-constrained layout and handles header repetition/tall rows explicitly. Native overflow and cross-block copy have regression tests; visual, keyboard and VoiceOver acceptance still require actual UI verification.

AppKit objects, attributed strings containing fonts/colors/attachments, text storage, layout managers and views remain `@MainActor`. Legacy nonisolated TextKit callbacks assert the main thread before reading their weak UI-owner links; background text layout is disabled. Parsing/tokenization and Foundation-only transforms run in cancellable worker tasks. Each load produces a monotonically increasing generation; publication requires the current document, generation and styling revision. Cancellation is cooperative and stale output must also be rejected. Theme-only changes reuse tokens. A closed document invalidates publication, cancels work, closes watchers and balances every successful security-scope access.

The minimap draws miniature glyphs, syntax colors, table decorations and loaded images from the reader's existing native layout. It does not parse or lay out a second document. Uniform scaling preserves the content's proportions; when the miniature is taller than its viewport, its virtual window follows document progress instead of squeezing every line into a fixed height. Clicks and viewport dragging use this same coordinate mapping.

Only visible/nearby raster tiles are produced, with a bounded cache rather than a full-document bitmap. Ordinary scrolling reuses tiles and updates their placement plus the viewport marker. Content, typography, appearance, images, annotations and code layout changes invalidate the visual generation. Disabling the minimap or closing the reader cancels pending work and releases cached images; delayed work must revalidate its generation and weak reader ownership before publishing.

## File and resource trust boundary

Documents are immutable inputs. Opening, reload, annotation and export never modify source bytes. Decode UTF-8 with optional BOM and BOM-marked UTF-16; reject invalid encodings, binary control content and size/nesting limits with localized errors. Keep the last successfully rendered content on a recoverable reload failure.

Represent a file grant separately from a URL. A successful security-scoped access is reference-counted and balanced on close. Bookmarks are resolved with security scope and refreshed when stale. A selected file does not automatically grant sibling-folder access. Relative links/images resolve against the document URL and require access; offer a narrowly described Open panel when access is missing. Resolve symlinks before containment checks. Reject path escapes from a folder grant; ordinary OS access failure remains authoritative. Never infer authorization from a path prefix string or file existence alone.

Watch both the file and its parent directory with event-driven facilities to survive atomic replacement, delete/recreate and rename; debounce approximately 200 ms and reopen file descriptors after replacement. In-place data and replacement generations are serially observed. No idle polling is required. External editor launch passes a file URL to `NSWorkspace`, never to a shell.

Allowed activated external schemes are HTTP and HTTPS. Local Markdown targets open inside MarkUp after permission checks. Other schemes require a deliberate documented policy, not automatic `NSWorkspace.open`. Remote images are off by default and require per-document consent or an explicit saved preference. Bound download bytes, redirects, dimensions, decoded pixels and aggregate retained image memory. Restrict decoding to reviewed formats; SVG/HTML must never become active document content.

## Annotation identity, transaction and recovery contract

Persistent annotations live under `FileManager`'s Application Support directory in an app-owned subtree, with private directory/file permissions. Caches and export intermediates are separate. Store a versioned JSON envelope atomically through one actor. Corrupt or unknown-version storage is preserved for recovery and never silently overwritten. Backups belong exclusively inside the annotation subtree.

Document identity is a generated UUID. Resource identity and security-scoped bookmark resolution can associate the same file after rename. During an already-open, observed atomic replacement, retain the document UUID if the file path relationship is known. Persist updated resource identity. After an unobserved replacement while closed, a path/content coincidence alone is insufficient: preserve old marks as recoverable and require explicit reassociation. Never discover identity by searching for similar text across unrelated files.

An anchor stores exact selected canonical text, bounded prefix/suffix context, original UTF-16 position and a document content digest. On unchanged content, validate the original range. On changed content, match exact text and both available context sides; require a single trustworthy candidate and at least 12 alphanumeric context scalars. This conservative evidence threshold deliberately leaves short/weak matches recoverable. Position may break no ambiguity by itself. Missing or ambiguous anchors remain listed with a recovery status and are never painted at guessed locations. Unicode ranges must be validated against composed-character boundaries.

The annotation store owns an epoch. Every window reads a snapshot with the epoch; add/remove/undo commands supply their expected epoch. Clear All atomically persists an empty store with an incremented epoch, removes annotation backups/journals/recovery copies, and broadcasts the empty snapshot to all windows. Old queued commands and undo records fail with a stale-epoch result. Reload/restart cannot resurrect cleared marks. Cache cleaning is a separate operation and cannot touch annotation state, preferences, bookmarks or sources.

Every undo/redo closure must capture its original command epoch; reading the current epoch when an old undo executes defeats the store's protection. Nil removal results must not register a restore action. The store writes a private pending file, sets its permissions, then atomically renames it; no fallible operation occurs between that commit point and in-memory state publication.

The current event watcher treats an old-inode rename/delete event with a replacement already present at the 220 ms debounce boundary as continuity of the active logical document. Native testing confirms Foundation atomic writes emit delete on this host. An absence observed at the debounce boundary followed by later recreation is a new identity; parent-directory-only events cannot authorize rebinding. A delete/recreate completed entirely inside the coalescing interval is indistinguishable from atomic replacement at this OS event layer. Closed/unobserved replacements remain new identities. Matching text alone never creates cross-document identity.

## PDF and printing

A shared export layout consumes the same IR, tokens and optional resolved annotations but builds separate text storage and page containers. A4/Letter, orientation, margins and appearance are validated inputs. Light output and annotation exclusion are the defaults. Native glyph drawing generates selectable PDF text. Page boundaries must be checked against actual laid-out glyph ranges; the end marker from long fixtures must appear in extracted text. Text should never be rasterized as a window screenshot.

Wrap long code and fit/wrap tables at the page content width; split tall blocks without losing characters. Keep headings with their following paragraph where possible. Repeat table headers when a table spans pages. Add links/bookmarks when available. Print uses the same page-layout result. Export writes a temporary staging file and replaces the selected destination only after successful completion; cancellation/failure must leave no plausible partial final file.

## Updates and distribution

[Sparkle 2 sandbox integration](https://sparkle-project.org/documentation/sandboxing/) requires `SUEnableInstallerLauncherService = YES` and Mach lookup exceptions for `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `$(PRODUCT_BUNDLE_IDENTIFIER)-spki`. The app already needs outbound networking for explicitly enabled remote images, so it uses `com.apple.security.network.client`; do not enable Sparkle's separate Downloader service. The user-selected read-write entitlement is required for PDF/preferences Save Panel output; source documents remain read-only in code. Security-scoped bookmarks cover explicitly selected resource folders. No broad filesystem entitlement is used.

The update wrapper validates configured HTTPS feed and public key before starting Sparkle. Development placeholders disable network checking with an actionable localized message. Automatic checking/install are explicit user preferences. Never contact another product's feed. A future App Store build removes this wrapper UI, dependency, Installer XPC integration and updater-only Mach exceptions; document storage and sandbox behavior remain unchanged.

Use Xcode Archive and Export for Developer ID distribution; Sparkle documents that this signs nested services correctly while Code Sign on Copy alone does not. Do not use `codesign --deep` to sign. Notarize, inspect the result/log, staple the app, recreate the final archive, then calculate checksums and Sparkle signatures from those final bytes. GitHub Actions use verified immutable action revisions and least privilege; fork PR validation receives no signing secrets. Controlled N→N+1 installation and invalid-signature rejection remain release gates until actually executed.

## Accessibility, localization and availability

English is explicitly persisted as the first-launch language even on Turkish systems. All app-owned strings—including error descriptions and accessibility text—use the same English/Turkish localization mechanism. Document text is never localized. System-owned dialogs may follow OS language and this boundary is documented.

Use standard native controls/materials and gate custom macOS 26 glass APIs with `#available(macOS 26, *)`. macOS 14/15 retain a finished native material fallback. Respect Reduce Transparency, Reduce Motion and Increase Contrast. Meaningful alerts use a label/icon as well as color. Annotations distinguish underline/highlight; unresolved marks have explicit text. Heading, table, keyboard and VoiceOver behavior require UI verification, not only source review.

## Primary references checked

- [Swift Markdown source and parser description](https://github.com/swiftlang/swift-markdown) — maintained cmark-gfm adaptation and immutable markup tree.
- [Apple NSTextTable](https://developer.apple.com/documentation/appkit/nstexttable) — native text-table API; layout/selection behavior must be demonstrated locally.
- [Sparkle sandboxing](https://sparkle-project.org/documentation/sandboxing/) — Installer XPC, entitlements, network-client decision and Archive/Export signing requirements.

Dependency versions, SDK-specific API availability and release procedures are verified against their owning sources during implementation. This document does not substitute for runtime tests.

## Native annotation undo boundary

Each reader session owns its annotation UndoManager independently of view mounting and NSDocument. The text view exposes that same manager to the responder chain; programmatic rendering and layout do not register content edits. Durable annotation history retains accepted saves until drained, while session callbacks are weak. This avoids source-document dirty state and keeps Cmd+Z attached to annotation actions.

Native printing explicitly uses the narrow `com.apple.security.print` entitlement in both configurations, as required by [Apple’s sandbox printing entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.print). CI checks the source entitlements and the release verifier checks the exported app.

PDF save-panel authorization is limited to the chosen file. Export stages in `FileManager`’s same-volume item replacement directory, then coordinates replacement or creation through Foundation. It never assumes parent-folder access. Precommit cancellation cleans staging; if Foundation reports a failed replacement that may retain original recovery data, that private directory is preserved. Native recent-document observation starts after application launch, after SwiftUI installs its document controller.

## Native window lifetime

SwiftUI and NSDocument can retain a closed window, so view disappearance alone is not a resource boundary. The native coordinator observes its owning window's close notification, persists the cached semantic reading location, and closes the session idempotently. Closing clears snapshots and callbacks, removes the native first responder, and detaches the heavy text-storage/layout graph. A retained scroll view can install a fresh graph on restart. Coordinator identity checks prevent a late callback from an obsolete view from resizing or closing a replacement view. Actor cache teardown completes before a restarted load uses those actors.

Reading locations store the semantic block identifier and a bounded intra-block character offset. Scroll events update an in-memory snapshot; durable preferences are written at close. Restoration waits for mounted, usable native geometry and is deferred beyond the current native mounting stack. The cancellable task revalidates view ownership and generation before applying the saved position; it also moves the empty caret so later focus cannot reveal a stale start-of-document selection. The native lifecycle tests deliberately retain closed windows and exercise actual window close/reopen rather than calling session cleanup directly.

Font descriptor lookup is cached only within each native rendering pass, keyed by the complete font request. The cache is cleared before the next render, so typography changes cannot reuse an earlier font choice. Empty annotation results and unchanged image state do not republish identical native content.

The SwiftUI `FileDocument` boundary validates input but does not retain decoded source. File-backed sessions already load from the user-selected URL through `DocumentLoader`; keeping another source string in a document box lets SwiftUI's retained closed windows accumulate full document copies. Missing document URLs produce the existing localized empty state. The actual parser/session remains the owner of loaded source and releases it on close.
