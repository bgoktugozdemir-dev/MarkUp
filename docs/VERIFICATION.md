# Verification ledger

Executed on 2026-10-30/31 (Europe/Istanbul). This ledger distinguishes source review, compilation, runtime evidence and external release gates. It does not claim a signed public release.

## Observed environment and routing

Apple M3 (Mac15,3), 8 logical CPUs, 16 GiB RAM; macOS 27.2 build 26B123, arm64. Xcode 27.1 build 27A9275, Swift 6.4, macOS SDK 27.0. App/core use Swift 6 with complete concurrency checking and macOS 14 deployment. Universal slices are cross-built; only arm64 was executed. Rosetta execution was attempted and returned `Bad CPU type in executable`; no translator was installed.

The root model identity is not exposed and cannot be switched by a prompt. Runtime accepted explicit worker selectors: `gpt-6-astra` / high for architecture, security/persistence/native-text invariants and final critical review; `gpt-6.1-sol` / high for substantive implementation and independent reviews; `gpt-6.1-terra` / medium only for two established plural catalog entries. Sol reviewed Terra output. Astra-authored annotation and PDF fixes received independent Sol review. No model dependency ships in the app.

## Automated and native gates

| Gate | Result and local evidence |
| --- | --- |
| Core regression suite | 33 executed tests passed; one opt-in performance test skipped in the ordinary run. Swift Testing reports 34 total. `build-core-final.log` |
| Full app-hosted suite | **49 tests / 12 suites passed**, 10.411 seconds test execution; the new native-test wrapper exited 0 and Xcode reported `TEST SUCCEEDED`. `build-app-payload-final49.log` and `build/Tests/Logs/Test/` |
| Source formatting | `xcrun swift-format lint --strict --recursive Sources Tests` passed; warnings were corrected rather than suppressed |
| Dependency/action/localization checks | `scripts/release-check.py` passed: 2 verified full-SHA Actions, 22 pinned grammar assets, 167 EN/TR strings plus plural catalogs |
| Native watcher/resource harness | Actual atomic replacement, rename, delete/recreate and close callbacks passed; HTTPS literal-address/credential/scheme policy passed. `build-services-final2.log` |
| Update signature primitive | Valid, tampered and wrong-key Ed25519 checks passed. `build-update-selftest.log`; this is not a Sparkle installation test |
| Owner configuration preflight | Correctly refuses missing configuration before importing credentials; `build-preflight.log` |
| PDF | Actual native multi-page text extraction, exact CJK/Turkish text/end markers, orphan-heading prevention, tall-row continuation labels, image pixels/aspect, safe links/bookmarks and annotation opt-in passed |
| PDF cancellation | Cancellation at pagination, drawing and writing boundaries preserves the existing destination and cleans staging; failed commit and successful replacement also covered |
| Native text | Continuous cross-block copy, code/table horizontal hit testing, tab-heavy code, compact controls, geometry cache reuse, full-document scroll height, AX control exposure and selection restoration passed |
| Search focus | Real NSHostingView/window/field-editor tests cover Cmd+F-equivalent mount, typing, repeated focus and dismissal without late focus theft |
| Annotation history | Real UndoManager/store tests cover inverse registration, serial persistence, rollback, close retention, clear epochs and stale snapshots |

The opt-in core Release benchmark ran separately: three samples each for 2,500, 10,000 and 50,000 lines. Parse+tokenization totals were 135.62/90.49/88.86 ms, 124.77/123.77/124.11 ms and 663.91/637.62/630.22 ms respectively. Cumulative test-process peak RSS reached approximately 144 MiB. These are **not** app startup or app memory figures. Raw original-fixture results: `artifacts/core-performance.json`.

## Important corrections found during real integration

Actual app UI caught a text-view maximum-height clamp that prevented scrolling, invisible accessibility children for code controls, a horizontal-origin compensation error and premature search focus. Native scroll-view/AX/focus regressions now cover them. PDF app-hosted tests exposed SF's Turkish localized `i` glyph with an empty ToUnicode map (`i` extracted as `!`); export-owned private-SF runs use undetermined shaping language while preserving the original characters, chosen fonts and UI language. EN/TR mixed-letter, source-immutability and existing PDF assertions all passed. Legacy manual PDF tags were removed to avoid mixing them with AppKit's newer tagging.

The actual sandboxed app exposed two additional integration boundaries: native printing needed its explicit `com.apple.security.print` entitlement, and a save-panel file grant did not permit a custom temporary sibling. The print panel now opens and cancels correctly. The PDF writer uses an OS-managed same-volume replacement directory with coordinated commit; the final sandboxed Release app successfully created and then replaced `artifacts/review.pdf` through the real NSSavePanel without a parent-folder grant. The UI reported “PDF exported.” both times. Native command routing also explicitly restores annotation Undo/Redo, Close and Open Recent after replacing source-editing commands.

Coverage collection is disabled because this Xcode/cmark combination failed to link `_llvm_profile_runtime` with coverage enabled. Test execution is retained. The upstream cmark umbrella-header warning and host linkd service diagnostics are not suppressed; they did not prevent successful builds/tests.

## Actual UI observations

The optimized sandboxed review build was inspected through native UI/accessibility tools using original public fixtures. English and Turkish settings/menus, light/dark content, automatic code-theme pairing, readable Turkish code labels, a full-document minimap, scrolling into later sections, loaded local images after explicit folder access, and double-click image enlargement were observed. System-owned menus switched after restart as documented. The document content itself remained unchanged. Final Release UI additionally verified actual Cmd+Z / Shift+Cmd+Z add-remove-restore behavior, cleanup of the test mark, and Cmd+W closing the document. The final exported public sample is a valid one-page PDF.

Actual repeated close/reopen testing exposed retained native text graphs and premature position restoration during window mounting. The native close boundary now releases the graph even when SwiftUI retains the window. Restoration runs after the mounting stack and revalidates ownership; old callbacks cannot affect a replacement view. The final suite retains closed windows and verifies three paragraph and three long-code reopen cycles, end-of-document visibility, intra-block offsets, weak graph release and retained-view restart. Earlier failed runs remain in ignored local logs; they are not counted as passes.

Heap inspection then found a second retained source copy in closed SwiftUI document boxes. The validation-only `MarkdownFile` fix preserves all input checks and uses the existing scoped loader. Five final Release reopen cycles retained the end position; the closed heap has one native text view, no large per-document source-copy bucket, and approximately 1.0 MB Swift.StringStorage versus 19.7 MB before the fix. Post-close footprints recovered to 154.47 / 155.89 MiB in the final two cycles. Timing and settling caveats are preserved in the performance report.

Final Release measurements and final smoke observations are recorded in [PERFORMANCE.md](PERFORMANCE.md). A concurrent-build idle sample was discarded and is explicitly marked invalid in `artifacts/idle-overlapped-discarded.json`.

## External and unexecuted release gates

No Git remote, Team ID, Developer ID export, notarization credentials, production update key/feed or authorized release environment is configured. No remote push or public release occurred. Owner setup must precede Developer ID signing/notarization, Gatekeeper acceptance, protected GitHub CI execution, controlled N→N+1 Sparkle download/install/relaunch and invalid-signature installation rejection. See [English release guide](RELEASING.md) and [Turkish owner walkthrough](OWNER_SETUP_TR.md).

macOS 14/15 fallback runtime, macOS 26 runtime and physical Intel execution require other systems. This host verifies macOS 27 native materials; no unguarded custom macOS-26 glass API is used. Actual VoiceOver speech/rotor behavior and the complete system Reduce Transparency/Motion/Increase Contrast matrix remain manual checks; native AX names/actions, layout and keyboard focus were checked. Printer output to physical hardware is not claimed.

Mermaid rendering, final logo/icon and App Store publication are deliberate later scope. The development icon is original and temporary.

## Local handoff artifacts and readiness

- `build/Review/MarkUp.app`: optimized Universal local review app, ad-hoc signed with development entitlements; App Sandbox remains enabled. The archive strips framework headers, so its local Sparkle framework seal is refreshed before signing the review app. This is not a Developer ID distribution.
- `build/MarkUp-unsigned.xcarchive`: final unsigned Release archive, built from the payload-fixed source.
- `artifacts/MarkUp-0.1.0-local-review-universal.zip` and `artifacts/SHA256SUMS`: local review package/checksum; not public release assets.
- `artifacts/review.pdf`: original public fixture exported and replaced through the real sandboxed Save panel.
- `artifacts/`: numeric measurements and local diagnostic evidence; ignored by Git.

| Readiness item | Status |
| --- | --- |
| Implemented V1 features, reviewed critical contracts, arm64 native tests | Completed locally |
| Universal archive, dependency locks, localization and source checks | Completed locally |
| Event-driven reload, annotation/PDF failure paths, actual close/reopen cleanup | Completed locally |
| Warm-open/reload 500-ms targets; every cold/idle sample within target | Not fully met; actual misses and profiles documented |
| Signing/notarization/Gatekeeper, hosted CI, real Sparkle install/relaunch/rejection | External setup required; unverified |
| Other supported macOS versions, physical Intel, full VoiceOver/system-a11y matrix | Additional hardware/manual validation required |
| Final icon, Mermaid rendering, App Store publication | Explicit later scope |

No remote push, release publication or App Store submission was performed.
