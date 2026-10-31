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
| Dependency/action/localization checks | `scripts/release-check.py` passed: 2 verified full-SHA Actions, 22 pinned grammar assets, 170 EN/TR strings plus plural catalogs |
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

## Integrated code-panel follow-up

The 2026-10-31 follow-up uses one rounded theme-colored code surface and compact
localized icon controls. Blocks start fully expanded; each long block can be
limited to 12 visual rows. Native glyph folding preserves canonical UTF-16 ranges,
full copy and separate PDF content. Search/selection reveals hidden code. Short
blocks disable the height action, and narrow headers expose an options menu.

Astra independently reviewed the glyph/layout, annotation, selection and export
boundaries. The first hosted run exposed AppKit changing icon position after
localized title assignment. The implementation now restores icon-only positioning
after refresh and copy-feedback transitions; the strict assertion was retained.
The corrected run passed **52 tests / 12 suites in 10.538 seconds** (local log:
`build-app-codeblocks-final.log`). The suite includes wrapped/unwrapped folding,
following-prose geometry/hit testing, full native copy, selection reveal, refresh
and resize state, annotation paint and export-attribute preservation. Strict
Swift formatting and release checks passed with 170 EN/TR keys. The native-test
wrapper exited 0 and Xcode reported TEST SUCCEEDED.

The refreshed optimized Universal app was inspected through native UI controls:
one rounded shared surface, icon-only header, full/limited toggle, following
prose moving up, disabled short-block control, line-number and wrap states, copy
feedback, and automatic expansion of the hidden `func section8` search result
were observed. Dark and light appearances and both English/Turkish action labels
were checked; the previous English/System preferences were restored. No Print
panel was reopened for this follow-up. The Release archive succeeded
(`build-release-codeblocks.log`); all six Mach-O binaries retain arm64/x86_64
slices, and the local review copy passes strict nested signature verification.
Only arm64 was executed. Performance figures remain the earlier V1 baseline as
explicitly identified in PERFORMANCE.md.

## Real-content minimap follow-up

The replacement minimap uses actual native glyphs, syntax colors, table decoration
and loaded images. It keeps uniform scale and follows a virtual vertical window
for long documents. It uses the existing text layout with bounded raster tiles,
not a second live renderer or a full-height bitmap.

The focused offscreen suite passed **7 tests / 1 suite in 1.085 seconds**, Xcode
TEST SUCCEEDED and runner exit 0 (`build-minimap-offscreen3.log`). Checks cover
real colored glyph/image pixels and offscreen code panels; panel-only padding;
identical selected/unselected raster pixels with unchanged single/multiple native
selections; click/drag continuity and accessibility actions; bounded Retina cache
allocation/reuse; fold, horizontal offset and line-number invalidation; and
cancellation/release with a retained minimap. Cache accounting, including two
working bitmap buffers, stayed within its 8 MiB ceiling in the native test.
This is an allocation-accounting assertion, not an app RSS measurement.
The existing CodeBlockControls suite also passed **10 tests / 1 suite in 0.217
seconds**, TEST SUCCEEDED and runner exit 0 (`build-minimap-code-regression.log`).
These two targeted runs do not replace the full app-hosted suite.

Earlier failed runs exposed a selection overlay in the miniature and a strong
reference retained by the test fixture. The preview now exposes an empty
selection only during synchronous native drawing, without setting/changing the
real selection. The release test drops its own strong fixture before asserting
weak graph release. Exact pixel and weak-release assertions were retained.
Swift 6 callback isolation was fixed through the existing main-actor controller
bridge; no new unsafe or unchecked annotation was added.

The final Universal Release archived successfully (`build-release-minimap-final.log`).
All six native binaries include arm64/x86_64 slices; the ad-hoc review app
passes strict nested signature verification. Both `build/Review/MarkUp.app` and
`build/MinimapReview/MarkUp.app` contain this final build. Their local review ZIPs
and checksums are refreshed together. Only arm64 was executed. These local
review copies are not Developer ID signed or notarized.

After unlocking, the full app-hosted gate passed **60 tests / 13 suites in
11.119 seconds**, Xcode TEST SUCCEEDED and wrapper exit 0
(`build-app-minimap-accepted.log`). Actual UI inspection caught negative tile
positions painting beyond the native view into the titlebar/footer. The view now
clips all drawing to its bounds; a translated bitmap regression requires real
inside content and exactly zero modified outside pixels. The final run includes
that test. An earlier run lost application activation during annotation command
routing; the same focus assertions passed on the final run without alteration.

Actual short/long-document UI inspection confirmed recognizable headings, prose,
syntax-colored code, tables and loaded images. Clicking the short preview reached
its end; dragging the long preview reached top/middle/end, with matching native
scrollbar values. Light/dark, 90%/100% zoom and hide/re-enable refreshed the map.
The original System appearance, English language and 100% zoom were restored.
The final rebuilt app was checked again at the long document’s end: miniature
painting stays inside the content area, with no titlebar/footer bleed. Current
CPU/memory observations are recorded in [PERFORMANCE.md](PERFORMANCE.md). No
private document was used as a fixture or published. Astra independently
approved the integrated handoff with the documented idle CPU exception.

## Minimap opacity and inline-code styling (2026-10-31)

At the owner's explicit request, Terra (`gpt-6.1-terra`, medium) implemented
70% compositing for minimap content while retaining the viewport marker. Inline
backtick code now uses appearance-aware red text and a subtle neutral background;
the native reader rounds its background without changing text or selection ranges.
The separate PDF layout retains the new colors with rectangular backgrounds.
Fenced-code themes are unchanged.

The Universal Release archive succeeded (`build-release-visual-polish.log`), all
six Mach-O binaries verify as Universal, and strict nested local signatures pass.
Formatting, release checks and diff checks passed. Actual local Release UI was
checked with an original generated fixture in light and dark appearances; the
System preference was restored. Both local Review app paths are refreshed.

Two full native attempts completed 59 of 60 tests successfully; the unchanged
`ReaderAnnotationUndoTests.focusedReaderRoutesUndoToDurableAnnotationsAfterRenderingUpdates`
failed its `NSApp.isActive`/activation wait in both runs. This is not a passing
full-suite gate. All 12 other suites, including eight minimap tests, code controls,
rendering/PDF and native layout, passed. Latest log:
`build-app-visual-polish-final.log`. No assertion was removed or weakened. No new
performance measurement is claimed for this visual-only follow-up.

## Owner artwork and first Developer ID package (2026-10-31)

The owner supplied `Branding/MarkUp.png`; all ten standard macOS icon slots now
contain resized copies preserving transparency. The development icon generator
writes to an ignored build folder by default. Version 0.1.0, build 2 was archived
and exported with the owner's Developer ID Application identity, team
`78N26NU5P4`. Local logs: `build-release-developerid.log` and
`build-export-developerid.log`. No private key or credential was exported or
committed; notarization used the owner's existing `MarkUp-notary` Keychain profile.

Apple accepted submission `829d7028-1ba2-48b8-8295-211b09ea7e63` with no issues.
The ticket was stapled to the app and validated. Post-staple verification checks
all six Universal Mach-O binaries and nested Developer ID signatures, timestamps,
hardened runtime and sandbox entitlements. Gatekeeper reports **accepted**, with
source **Notarized Developer ID**. The ZIP was recreated after stapling and its
integrity/checksum verified. Evidence is in `artifacts/developer-id/`.

The signed app opened the original visual fixture on this arm64 host. Its About
panel displays the supplied icon and Version 0.1.0 (2). On first launch macOS
requested access to the preceding development build's application data because
the signing identity changed. The owner explicitly clicked Open Anyway; no
container data was deleted and no system protection was disabled.

The signed app is `build/DeveloperID/MarkUp.app`; the final package is
`artifacts/developer-id/MarkUp-0.1.0-build2-universal.zip`. Automatic updates remain
disabled because the production feed/public key are blank. No GitHub release or
App Store submission occurred. This artwork/signing change did not rerun native
behavior tests or performance measurements; the preceding 59/60 focus-test
qualification and historical performance exceptions remain applicable.

## External and unexecuted release gates

Local Developer ID export, notarization and Gatekeeper acceptance are now verified as recorded above. No Git remote, production update key/feed or protected GitHub release environment is configured. No remote push or public release occurred. Owner setup is still required for protected GitHub CI execution, controlled N→N+1 Sparkle download/install/relaunch and invalid-signature installation rejection. See [English release guide](RELEASING.md) and [Turkish owner walkthrough](OWNER_SETUP_TR.md).

macOS 14/15 fallback runtime, macOS 26 runtime and physical Intel execution require other systems. This host verifies macOS 27 native materials; no unguarded custom macOS-26 glass API is used. Actual VoiceOver speech/rotor behavior and the complete system Reduce Transparency/Motion/Increase Contrast matrix remain manual checks; native AX names/actions, layout and keyboard focus were checked. Printer output to physical hardware is not claimed.

Mermaid rendering and App Store publication remain deliberate later scope. The owner-supplied product icon is integrated.

## Local handoff artifacts and readiness

- `build/Review/MarkUp.app`: optimized Universal local review app, ad-hoc signed with development entitlements; App Sandbox remains enabled. The archive strips framework headers, so its local Sparkle framework seal is refreshed before signing the review app. This is not a Developer ID distribution.
- `build/MarkUp-unsigned.xcarchive`: current unsigned Release archive, including the code-panel and real-content minimap follow-ups.
- `artifacts/MarkUp-0.1.0-local-review-universal.zip` and `artifacts/SHA256SUMS`: local review package/checksum; not public release assets.
- `artifacts/review.pdf`: original public fixture exported and replaced through the real sandboxed Save panel.
- `artifacts/`: numeric measurements and local diagnostic evidence; ignored by Git.

| Readiness item | Status |
| --- | --- |
| Implemented V1 features, reviewed critical contracts, arm64 native tests | Completed locally |
| Universal archive, dependency locks, localization and source checks | Completed locally |
| Event-driven reload, annotation/PDF failure paths, actual close/reopen cleanup | Completed locally |
| Warm-open/reload 500-ms targets; every cold/idle sample within target | Not fully met; actual misses and profiles documented |
| Local Developer ID signing, notarization and Gatekeeper | Verified for 0.1.0 (2) |
| Hosted CI, real Sparkle install/relaunch/rejection | External setup required; unverified |
| Other supported macOS versions, physical Intel, full VoiceOver/system-a11y matrix | Additional hardware/manual validation required |
| Owner-supplied final icon | Integrated and observed in signed app |
| Mermaid rendering, App Store publication | Explicit later scope |

No remote push, release publication or App Store submission was performed.
