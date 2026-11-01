#!/usr/bin/env python3
"""Run hosted native tests with explicit, verified test-host activation on macOS.

Usage: python3 scripts/run-native-tests.py [--derived-data build/Tests]
Close other local MarkUp copies and keep UI automation idle during this gate.
Xcode output is inherited; redirect it normally to retain a local log.
"""
import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class Process:
    pid: int
    started: str
    executable: str


def parse_processes(output):
    processes = []
    for line in output.splitlines():
        fields = line.split(None, 6)
        if len(fields) == 7 and fields[0].isdigit():
            processes.append(Process(int(fields[0]), " ".join(fields[1:6]), fields[6]))
    return processes


def processes():
    result = subprocess.run(
        ["/bin/ps", "-axo", "pid=,lstart=,comm="], check=True, capture_output=True, text=True,
        timeout=5)
    return parse_processes(result.stdout)


def activate(host):
    current = set(processes())
    if host not in current:
        raise RuntimeError("Test host exited or changed before activation")
    if any(item != host and item.executable.endswith("/Contents/MacOS/MarkUp") for item in current):
        raise RuntimeError("Another MarkUp copy appeared; refusing ambiguous activation")
    # If the verified PID exits in the remaining race, open can start only this derived-data
    # test app. Final cleanup also discovers new exact-path processes. Other copies fail preflight.
    app = str(Path(host.executable).parents[2])
    subprocess.run(
        ["/usr/bin/open", "-a", app], check=True, timeout=10)
    print(f"Requested native test-host activation (PID {host.pid}).", flush=True)


def cleanup(build, hosts, executable=None, initial=frozenset()):
    if build is not None:
        def group_exists():
            try:
                os.killpg(build.pid, 0)
                return True
            except ProcessLookupError:
                return False

        try:
            os.killpg(build.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 5
        while group_exists() and time.monotonic() < deadline:
            build.poll()
            time.sleep(0.1)
        if group_exists():
            try:
                os.killpg(build.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        build.wait(timeout=5)
    # Xcode may launch the GUI host outside its process group. Never signal a preexisting
    # process or a recycled PID: the complete captured identity must still match.
    if hosts or executable:
        current = set(processes())
        if executable:
            hosts = hosts | {
                item for item in current if item.executable == executable and item not in initial
            }
        for host in hosts & current:
            try:
                os.kill(host.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 3
        remaining = hosts & current
        while remaining and time.monotonic() < deadline:
            remaining &= set(processes())
            if remaining:
                time.sleep(0.1)
        for host in remaining & set(processes()):
            try:
                os.kill(host.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def run(args):
    derived = (ROOT / args.derived_data).resolve()
    executable = str(derived / "Build/Products/Debug/MarkUp Dev.app/Contents/MacOS/MarkUp Dev")
    existing = processes()
    if any(item.executable.endswith("/Contents/MacOS/MarkUp Dev") for item in existing):
        raise RuntimeError("Close other MarkUp Dev app/test copies before running native focus tests.")
    initial = set(existing)
    command = [
        "xcodebuild", "-project", "MarkUp.xcodeproj", "-scheme", "MarkUp",
        "-configuration", "Debug", "-destination", f"platform=macOS,arch={platform.machine()}",
        "-derivedDataPath", str(derived), "-clonedSourcePackagesDirPath", args.package_cache,
        "-onlyUsePackageVersionsFromResolvedFile", "-enableCodeCoverage", "NO",
        "ONLY_ACTIVE_ARCH=YES", "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "test",
    ]
    build = None
    hosts = set()
    activated = False
    deadline = time.monotonic() + args.timeout
    try:
        build = subprocess.Popen(command, cwd=ROOT, start_new_session=True)
        while build.poll() is None:
            if time.monotonic() >= deadline:
                raise TimeoutError(f"Native test gate exceeded {args.timeout:g} seconds")
            candidates = {
                item for item in processes()
                if item.executable == executable and item not in initial
            }
            hosts.update(candidates)
            if not activated and candidates:
                if len(candidates) != 1:
                    raise RuntimeError("Multiple exact test hosts appeared; refusing ambiguous activation")
                activate(next(iter(candidates)))
                activated = True
            time.sleep(0.25)
        status = build.returncode
        if status == 0 and not activated:
            raise RuntimeError("Xcode reported success without a detected, activated native test host")
        return status if status >= 0 else 128 - status
    finally:
        try:
            cleanup(build, hosts, executable, initial)
        except (OSError, subprocess.SubprocessError) as error:
            print(f"Native test cleanup failed: {error}", file=sys.stderr)
            # Keep Xcode's original failure status; a successful build with failed cleanup
            # must still fail this gate rather than silently leave its test host running.
            if build is not None and build.returncode == 0:
                raise


def self_test():
    from unittest.mock import patch
    parsed = parse_processes(
        " 42 Fri Oct 30 22:00:00 2026 /tmp/Derived Data/MarkUp.app/Contents/MacOS/MarkUp\n"
        " 43 Fri Oct 30 22:00:01 2026 /Applications/MarkUp.app/Contents/MacOS/MarkUp\n")
    assert parsed[0].executable == "/tmp/Derived Data/MarkUp.app/Contents/MacOS/MarkUp"
    with patch(__name__ + ".processes", return_value=parsed[:1]), patch("subprocess.run") as call:
        activate(parsed[0])
        assert call.call_args.args[0] == ["/usr/bin/open", "-a", "/tmp/Derived Data/MarkUp.app"]
        assert call.call_args.kwargs["timeout"] == 10
    with patch(__name__ + ".processes", return_value=parsed), patch("subprocess.run") as call:
        try:
            activate(parsed[0])
            raise AssertionError("A concurrently opened production copy must block activation")
        except RuntimeError:
            pass
        call.assert_not_called()
    recycled = Process(parsed[0].pid, "Sat Oct 31 00:00:00 2026", parsed[0].executable)
    with patch(__name__ + ".processes", return_value=[recycled, parsed[1]]), patch("os.kill") as kill:
        cleanup(None, {parsed[0]})
        kill.assert_not_called()
    with patch(__name__ + ".processes", side_effect=[parsed, [], []]), patch("os.kill") as kill:
        cleanup(None, {parsed[0]})
        kill.assert_called_once_with(42, signal.SIGTERM)
    from unittest.mock import Mock
    exited_leader = Mock(pid=123)
    exited_leader.poll.return_value = 65
    with patch("os.killpg") as kill_group, patch("time.monotonic", side_effect=[0, 6]):
        cleanup(exited_leader, set())
        assert (123, signal.SIGTERM) in [call.args for call in kill_group.call_args_list]
        assert (123, signal.SIGKILL) in [call.args for call in kill_group.call_args_list]
    print("Native test wrapper identity/activation/cleanup checks passed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", default=".build/ci-tests")
    parser.add_argument("--package-cache", default=".build/xcode-packages")
    parser.add_argument("--timeout", type=float, default=1800)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not 0 < args.timeout <= 3600:
        parser.error("--timeout must be greater than zero and at most 3600 seconds")
    if sys.platform != "darwin":
        parser.error("Native AppKit tests require a logged-in macOS GUI session")

    def interrupted(number, _frame):
        raise KeyboardInterrupt(number)

    for number in (signal.SIGINT, signal.SIGTERM):
        signal.signal(number, interrupted)
    try:
        return run(args)
    except KeyboardInterrupt as error:
        return 128 + (error.args[0] if error.args else signal.SIGINT)
    except (OSError, RuntimeError, TimeoutError, subprocess.SubprocessError) as error:
        print(f"Native test gate failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
