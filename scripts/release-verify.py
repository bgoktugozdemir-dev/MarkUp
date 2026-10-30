#!/usr/bin/env python3
"""Inspect an app's actual Mach-O slices and exported distribution signatures."""
from pathlib import Path
import argparse
import os
import plistlib
import subprocess


def run(*args):
    return subprocess.run(args, check=True, capture_output=True).stdout


def require(value, message):
    if not value:
        raise SystemExit(message)


def require_universal(path):
    architectures = set(run("lipo", "-archs", str(path)).decode().split())
    require({"arm64", "x86_64"} <= architectures, "Missing Universal architecture slice: " + path.name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--unsigned", action="store_true", help="Development inspection; never a distribution-readiness claim")
    parser.add_argument("--team")
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info["CFBundleIdentifier"] == "com.bgoktugozdemir.MarkUp", "Unexpected application bundle identifier")
    require(info["LSMinimumSystemVersion"].split(".")[:2] == ["14", "0"], "Deployment target must remain macOS 14.0")
    main_binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    require_universal(main_binary)
    binaries = []
    for path in app.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        # Mach-O magic values, including universal/fat headers. Avoid running file(1) on every resource.
        with path.open("rb") as stream:
            magic = stream.read(4)
        if magic in [bytes.fromhex(h) for h in ("cffaedfe", "feedfacf", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")]:
            require_universal(path)
            binaries.append(path)
    require(binaries, "No actual native binaries inspected")
    require(any(p.name == "Installer" for p in binaries), "Required Sparkle sandbox installer service is missing")
    require(info.get("SUEnableInstallerLauncherService") is True, "Sandbox updater installer must be enabled")
    if not args.unsigned:
        require(args.team, "--team is required for distribution verification")
        require(info.get("SUPublicEDKey") == os.environ.get("MARKUP_UPDATE_PUBLIC_KEY"), "Embedded updater public key differs from approved release configuration")
        require(info.get("SUFeedURL") == os.environ.get("MARKUP_UPDATE_FEED"), "Embedded update feed differs from approved release configuration")
        run("codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app))
        bundles = [app] + [p for p in app.rglob("*") if p.is_dir() and not p.is_symlink() and p.suffix in (".app", ".xpc", ".framework")]
        for path in bundles + binaries:
            result = subprocess.run(["codesign", "-d", "--verbose=4", str(path)], check=True, capture_output=True)
            details = (result.stdout + result.stderr).decode()
            require("TeamIdentifier=" + args.team in details, "Nested code has the wrong team: " + path.name)
            require("runtime" in details and "Timestamp=" in details, "Missing hardened runtime or secure timestamp: " + path.name)
        result = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)], check=True, capture_output=True)
        entitlements = plistlib.loads(result.stdout)
        require(entitlements.get("com.apple.security.app-sandbox") is True, "Release app must be sandboxed")
        require(entitlements.get("com.apple.security.print") is True, "Release app must support sandboxed printing")
        require(not entitlements.get("com.apple.security.get-task-allow", False), "Release must not allow debugging")
    print(f"Inspected {len(binaries)} Universal Mach-O binaries; " + ("unsigned development build." if args.unsigned else "distribution code signatures verified."))


if __name__ == "__main__":
    main()
