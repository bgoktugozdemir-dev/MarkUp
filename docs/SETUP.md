# Development setup

The checked-in `project.yml` owns Xcode configuration; regenerate with XcodeGen 2.46.0 after adding sources or targets. `Package.swift` owns the Foundation/core package. Keep both root and Xcode workspace `Package.resolved` files under version control. Xcode may update the root lock when resolving the local package, so inspect lock diffs before committing.

Minimum application OS is macOS 14. Swift language mode is 6 with complete concurrency checking; default actor isolation remains nonisolated. App/UI types explicitly use MainActor. Swift Markdown 0.9.0 itself uses Swift 5 language mode and Swift tools 6.2; MarkUp converts its tree into immutable Sendable values before crossing actor boundaries.

## Verification commands

```sh
swift test
python3 scripts/localize.py
python3 scripts/generate-fixtures.py
bash scripts/check-native-services.sh
xcodegen generate
python3 scripts/run-native-tests.py --derived-data build/Tests
xcodebuild -project MarkUp.xcodeproj -scheme MarkUp \
  -destination 'generic/platform=macOS' -configuration Release \
  -derivedDataPath build/Release ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
lipo -archs build/Release/Build/Products/Release/MarkUp.app/Contents/MacOS/MarkUp
```

Close other running development copies of MarkUp before app-hosted tests. The wrapper refuses competing copies, runs Xcode tests for the host architecture, and activates only the verified newly launched test-host path. It preserves Xcode failures and cleans up its own process group. CI uses the same wrapper. The native command/focus regression requires the test host to become the active application and acquire a real key window; two running copies with the same bundle identifier can prevent that. Do not interact with other windows during that short test. The test asserts activation/key focus rather than silently skipping routing checks.

Use `arch=x86_64` only on a runner that can execute it. A successful cross-build does not establish native Intel runtime behavior. A sandbox-restricted agent may need permission to access Xcode's caches and package network hosts; do not disable the application's Sandbox to work around the agent's filesystem sandbox.

Core tests use temporary private directories; source fixtures are never modified. Generated stress documents are ignored by Git and reproduced from an original public generator. Development artifacts live under `build/`, which is ignored. Do not copy private test materials into tracked paths or CI uploads.

## Environments

Debug builds are the test environment: **MarkUp Dev** (`MarkUp Dev.app`) with bundle ID `com.bgoktugozdemir.MarkUp.dev`, an orange DEV icon badge and a DEV label in the status bar. Its own sandbox container keeps preferences, annotations and folder grants apart from the installed MarkUp, and its update feed is always empty. Release builds keep the name `MarkUp` and ID `com.bgoktugozdemir.MarkUp`. After changing `AppIcon`, regenerate the badge with `swift scripts/make-dev-app-icon.swift`.

## Temporary icon

`scripts/make-development-icon.swift` produces an original development-only icon. Replace the asset catalog with the later GPT Image design at all required macOS resolutions, inspect light/dark Dock appearances, and rebuild before public branding. Final logo generation is intentionally deferred.
