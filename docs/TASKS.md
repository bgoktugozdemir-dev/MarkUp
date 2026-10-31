# Execution board and acceptance evidence

This board records ownership and evidence. `Pending` means not established. Do not interpret planned behavior as shipped or tested behavior.

## Runtime and ownership

The root model identity is not exposed and cannot be switched by a prompt. Explicit worker selectors were accepted: `gpt-6-astra` / high for architecture, annotation identity/security, native text invariants and critical review; `gpt-6.1-sol` / high for parser/rendering/PDF, grammar/themes, undo integration and release preparation; `gpt-6.1-terra` / medium for two established EN/TR plural entries only. Sol reviewed Terra output. No model service or orchestration framework ships in the app.

| Work | Ownership | Evidence / remaining boundary |
| --- | --- | --- |
| Architecture and dependency contracts | Astra + coordinator | `ARCHITECTURE.md`; actual modules reviewed |
| Parser, native rendering and PDF | Sol + coordinator; Astra review | Core and app-hosted regression suites; cooperative PDF cancellation and atomic-write harness |
| Native selection/code/table controls | Astra; independent Sol review | Cross-block copy, hit testing, tabs, local scrolling, compact controls, selection restoration and scroll geometry tests |
| Durable annotation identity/recovery | Astra; independent Sol review | Nine store tests; eight native undo/history tests, epoch and stale-revision protection |
| File/resource boundaries | Astra + coordinator | Actual watcher replacement/rename/delete/recreate/close harness; sandbox app and safe URL/resource tests |
| Preferences/localization/navigation | Sol + coordinator; limited Terra plurals | Validated versioned preferences; 167 bilingual strings plus plural catalogs; native visual/keyboard evidence in ledger |
| Update/release trust | Sol + coordinator; Astra review | Real Sparkle boundary, pinned Actions, fail-closed owner preflight, signature self-test; signing/install gates external |
| Universal artifacts/performance | Coordinator | Release archive, numeric-only instrumentation and original generated fixtures; measured results in ledger |
| Final integrated acceptance | Astra + coordinator | Source review and failure-path evidence; `VERIFICATION.md` is the authoritative executed/unverified matrix |

During review we fixed conservative anchoring, undo retention/epoch reuse, stale reload/image publication, image attachment glyphs, PDF header/long-row layout, cancellation/atomic output, AppKit automatic unsafe PDF links, tab overflow, narrow code controls, per-scroll geometry remeasurement, and the native scroll-view height clamp found by actual UI inspection. Tests were retained or strengthened; failed runs remain local logs. The final ledger distinguishes rerun results from earlier failures. The final native wrapper executed 49 tests in 12 suites successfully (10.411 seconds): `build-app-payload-final49.log`. The last lifecycle correction releases the native text graph at actual window close and defers saved-position restoration beyond initial mounting. Six retained-window close/reopen cycles, intra-code offsets, view restart and stale-owner isolation are covered.

## External release gates

Developer ID identity/private key, Team ID, notarization credentials, actual repository/feed ownership and Sparkle private signing key require owner-operated setup. They must never be pasted into chat or committed. Their absence does not block implementation, unsigned development builds, local tests or complete workflow preparation. Public release publication and App Store submission remain unauthorized unless separately requested.

## Annotation module evidence

Executed on the supplied macOS arm64 host using Xcode 27.1 / Swift 6.4:

```sh
env CLANG_MODULE_CACHE_PATH="$PWD/.build-architecture-clang" \
    SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build-architecture-swift" \
    swift test --disable-sandbox --filter AnnotationTests
```

Result: 9 tests passed. The test process reports `arm64e-apple-macos14.0`; this is target metadata, not evidence of execution on macOS 14. Default user-level compiler caches were sandbox-denied; project-local caches avoid that restriction. A `/tmp` versus `/private/tmp` cache-alias collision caused a Swift frontend failure before using project-local caches. One initial Unicode test used canonical NSString matching and selected the wrong equivalent character; explicit `.literal` lookup corrected the fixture, after which decomposed-character boundary rejection passed.

The store is one shared actor per app process. Actual multiwindow update behavior and native accessibility remain integrated UI checks. Native undo history received an independent review: original-epoch commands register inverse actions synchronously and persist through a serial queue; accepted operations retain their owner until drained; failure recovery rejects stale snapshots.

## Native code and table overflow evidence

`CodeBlockControlsTests.swift` exercises the actual app text container/layout manager and renderer: continuous prose/code/prose native copy, horizontal native hit-testing, wrap and line-number changes without text/selection mutation, tab-heavy unwrapped lines, final content visible at maximum scroll, independent six-column table scroll, screen/export table separation, and plain copying of image alt text without its object marker. `ReadingAnchorTests.swift` checks nearest semantic leaf selection despite postorder list/quote containers. The coordinator's final test ledger records integrated pass/fail totals.

A standalone native AppKit harness confirmed 100 tabs plus `END` at an 8-point code font remain on one baseline. Clearing prose tab stops and setting a repeating four-space interval corrected AppKit's default twelve-stop wrapping behavior. Native used-line geometry reports approximately 1941 points of content, rather than the conservative 6784-point layout proposal, so the scrollbar does not expose a large empty tail. Separate harness checks confirmed final table-cell visibility after local scrolling and unchanged canonical text. An offscreen capture was blank and is explicitly not visual acceptance evidence; the real app must be inspected.

## Native file/resource service evidence

`scripts/check-native-services.sh` compiles the actual `FileServices.swift` and `DocumentInput.swift` sources with Swift 6 and macOS 14 deployment, substituting only an identity localization function and removing the package import for this standalone harness. The host-run checks passed: Foundation atomic write observed as replacement; descriptor-based rename follows the new path; observed deletion then recreation does not transfer identity; closing prevents later callbacks; HTTPS policy rejects HTTP, credentials and literal local/private addresses.

The loader uses an ephemeral URLSession with no cookie/credential storage or cache. Redirect destinations are checked before following, have a five-redirect budget, and lose authorization/cookie headers. Authentication challenges do not request ambient credentials. User-approved DNS names still use system DNS; literal-address filtering is not a DNS-rebinding prevention claim. File bytes, remote bytes, decoded image dimensions and retained compressed-image cache have explicit limits.

The service harness is not a sandbox entitlement test and does not exercise a live TLS redirect chain. Stale bookmark refresh, permission-denied UI, actual app close and native multiwindow interactions remain integrated checks. The standalone command exited 0; this restricted environment also printed two compiler `sandbox-exec: sandbox_apply: Operation not permitted` messages while compilation/check execution still completed.

## Final local acceptance

Astra approved the integrated local handoff after independent Sol reviews of the
critical authored fixes. Final evidence: 49 native tests / 12 suites passed in
10.411 seconds; Universal payload-fixed archive; five actual reopen cycles; closed
heap with one native reader and no retained large source copies. Final performance
exceptions (warm opening, refresh, idle CPU and one slightly slower cold sample)
remain explicit in `PERFORMANCE.md`. All independent local implementation work is
complete. Signing/update installation and additional OS/hardware/accessibility
checks remain owner-operated gates, not claimed passes.

## Code-panel follow-up (2026-10-31)

The owner requested a unified rounded code surface, compact header controls and
a per-block full-height/limited-height toggle, explicitly confirming height rather
than width. Sol (explicit `gpt-6.1-sol`, high) owns CodeBlockControls and its native
tests; root owns localization, integration and actual UI verification; Astra
(explicit `gpt-6-astra`, high) independently reviews native glyph/selection/export
invariants and the Local Network diagnosis. No default collapsing or nested
vertical scroll area is introduced.

The Local Network request is consistent with the earlier native Print-panel test
and system Bonjour printer discovery. The available evidence does not establish
the exact request at the screenshot timestamp. No network permission is granted
and no entitlement is removed to hide the prompt. See SECURITY.md.

Follow-up completion evidence: 52 native tests / 12 suites passed in 10.538 seconds,
wrapper exit 0; formatting and release checks passed (170 localization keys).
Universal archive and local strict signature checks passed. Actual dark/light,
EN/TR, limit/show-all, search-reveal, wrap/numbers and copy-feedback checks passed.
Performance numbers remain attributed to the preceding V1 baseline.
Astra independently verified the final logs and diff and approved integrated
acceptance; no follow-up blocker remained. Existing external release gates are
unchanged.

## Real-content minimap follow-up (2026-10-31)

The owner requested a VS Code-like miniature instead of the current block-kind
bars. Astra (`gpt-6-astra`, high) defines/reviews geometry, cache and lifecycle
invariants. Sol (`gpt-6.1-sol`, high) owns the native minimap, its reader/code-layout
integration and meaningful tests. Root owns build integration, documentation,
actual UI verification and bounded performance checks.

The preview must use actual glyphs, colors, tables and images from the existing
native layout, with uniform scaling and a virtual vertical window for long
documents. Raster tiles are bounded and cached; no second live document renderer
or full-height bitmap. Click, viewport dragging and accessibility navigation
must map to the same layout. Ordinary scrolling must not rescan/re-render the
whole document. Content/appearance/layout changes invalidate tiles; hiding the
minimap or closing the reader cancels work and releases its cache. Private user
documents/screenshots are not test artifacts or repository content.

Implementation and unlocked integration checks are complete. The final full
app-hosted gate passed **60 tests / 13 suites in 11.119 seconds**
(`build-app-minimap-accepted.log`, TEST SUCCEEDED, wrapper exit 0). Focused
minimap and CodeBlockControls runs previously passed 7/7 and 10/10. The final
suite adds strict clipping regression coverage after actual UI revealed painting
outside the native preview bounds. Selection, clipping and focus assertions were
retained.

The final Universal archive succeeded (`build-release-minimap-final.log`); six
Mach-O binaries retain both architectures and local nested signatures verify.
Both `build/Review/MarkUp.app` and `build/MinimapReview/MarkUp.app` are refreshed.
Actual short/long-document navigation, real glyph/syntax/table/image content,
light/dark appearance, zoom, hide/re-enable and final no-bleed drawing were checked.
Preferences are restored to English/System/100%. The current 31.176-second idle
observation measured 1.347% CPU and 103.74 MiB physical footprint; the <1% CPU
target remains an explicit performance exception, not a claimed pass.

Astra independently approved the final integrated handoff, including source,
strict test/log evidence and the explicitly qualified performance observation.
No implementation blocker remains. No remote push or publication occurred.
Existing external release gates remain unchanged.
