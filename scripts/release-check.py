#!/usr/bin/env python3
"""Secret-free CI gates: immutable actions, pinned assets, source hygiene, EN/TR coverage."""
from pathlib import Path
import hashlib
import json
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def strings(path):
    result = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)], check=True, capture_output=True)
    return json.loads(result.stdout)


def main():
    for name in ("MarkUp.entitlements", "MarkUp-Debug.entitlements"):
        entitlements = plistlib.loads((ROOT / "Config" / name).read_bytes())
        require(entitlements.get("com.apple.security.app-sandbox") is True, "App Sandbox must remain enabled")
        require(entitlements.get("com.apple.security.print") is True, "Native printing requires its sandbox entitlement")
    lock = json.loads((ROOT / ".github/actions-lock.json").read_text())["actions"]
    used = set()
    for workflow in (ROOT / ".github/workflows").glob("*.yml"):
        content = workflow.read_text()
        require("pull_request_target" not in content, "PR target execution must never expose release credentials")
        for action, revision in re.findall(r"uses:\s*([\w./-]+)@([^\s#]+)", content):
            require(action in lock and re.fullmatch(r"[a-f0-9]{40}", revision), f"Unpinned/unreviewed action: {action}")
            require(lock[action]["commit"] == revision, f"Action lock mismatch: {action}")
            used.add(action)
    require(used == set(lock), "Action manifest has unused or missing dependencies")
    root_lock = json.loads((ROOT / "Package.resolved").read_text())
    xcode_lock = json.loads((ROOT / "MarkUp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())
    for resolved in (root_lock, xcode_lock):
        require(all(re.fullmatch(r"[a-f0-9]{40}", pin["state"].get("revision", "")) and pin["state"].get("version")
                    for pin in resolved["pins"]), "Every Swift dependency needs a real version and immutable revision")
    asset_manifest = json.loads((ROOT / "licenses/highlight.js-manifest.json").read_text())
    for name, digest in asset_manifest["files"].items():
        asset = ROOT / "Sources/MarkUpCore/Highlighting/Resources" / name
        require(hashlib.sha256(asset.read_bytes()).hexdigest() == digest, f"Vendored grammar changed: {name}")
    english = strings(ROOT / "Sources/MarkUpApp/Resources/en.lproj/Localizable.strings")
    turkish = strings(ROOT / "Sources/MarkUpApp/Resources/tr.lproj/Localizable.strings")
    require(set(english) == set(turkish), "English and Turkish localization keys differ")
    require(all(isinstance(v, str) and v for v in turkish.values()), "Empty Turkish translation")
    required_keys = set()
    for source in (ROOT / "Sources/MarkUpApp").rglob("*.swift"):
        content = source.read_text()
        require(not any(line.rstrip() != line for line in content.splitlines()), f"Trailing whitespace: {source.name}")
        for quoted in re.findall(r'(?:\blocalized|\bfontPicker|\bsizeSlider)\(\s*("(?:[^"\\]|\\.)*")', content):
            if r"\(" not in quoted:
                required_keys.add(json.loads(quoted))
    require(required_keys <= set(english), "Missing localization keys: " + repr(sorted(required_keys - set(english))))
    format_pattern = re.compile(r"%(?:\d+\$)?[@difus]")
    for key in english:
        require(sorted(format_pattern.findall(english[key])) == sorted(format_pattern.findall(turkish[key])),
                "Localized format placeholders differ: " + key)
    tracked = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True).stdout.decode().split("\0")
    require(not any(p.startswith("private-fixtures/") or p.endswith((".p12", ".p8", ".key")) for p in tracked if p),
            "Private examples or signing material must not be tracked")
    print(f"Checks passed: {len(used)} pinned actions, {len(asset_manifest['files'])} grammar assets, {len(english)} EN/TR keys.")


if __name__ == "__main__":
    main()
