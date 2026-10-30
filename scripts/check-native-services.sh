#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/markup-native-services.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
# Compile the actual platform service code without importing the package module; its two
# Foundation-only input policies are compiled from their owning source below. Localization
# is intentionally an identity stub because this harness tests file/network boundaries.
sed '/^import MarkUpCore$/d' Sources/MarkUpApp/Services/FileServices.swift > "$work_dir/FileServices.swift"
printf '%s\n' 'func localized(_ text: String) -> String { text }' > "$work_dir/Localization.swift"
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$PWD/.build/native-services-module-cache" \
    Sources/MarkUpCore/DocumentInput.swift Sources/MarkUpCore/Annotations.swift "$work_dir/FileServices.swift" \
    "$work_dir/Localization.swift" Tests/NativeServices/FileServicesChecks.swift \
    -o "$work_dir/checks"
"$work_dir/checks"
