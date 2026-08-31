#!/usr/bin/env python3
"""Fail-closed privacy preflight for the signed iOS app and its Widget.

This intentionally checks only evidence supplied by the built app.  It does
not add speculative usage descriptions.  On macOS, an optional bundle scan
uses otool to identify linked sensitive frameworks; unknown symbols are only
reported, never treated as proof of a permission requirement.
"""
from __future__ import annotations

import argparse
import plistlib
import shutil
import subprocess
from pathlib import Path

REQUIRED = {
    "NSMicrophoneUsageDescription",
    "NSSpeechRecognitionUsageDescription",
    "NSUserTrackingUsageDescription",
    "NSLocationWhenInUseUsageDescription",
}
WIDGET_FORBIDDEN = REQUIRED
FRAMEWORK_KEYS = {
    "AVFoundation": "NSMicrophoneUsageDescription",
    "Speech": "NSSpeechRecognitionUsageDescription",
    "AppTrackingTransparency": "NSUserTrackingUsageDescription",
    "AdSupport": "NSUserTrackingUsageDescription",
    "CoreLocation": "NSLocationWhenInUseUsageDescription",
}


def read_plist(path: Path) -> dict:
    try:
        with path.open("rb") as stream:
            value = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException, ValueError) as exc:
        raise SystemExit(f"BLOCKED_PRIVACY_PLIST: unable to read {path}: {exc}")
    if not isinstance(value, dict):
        raise SystemExit(f"BLOCKED_PRIVACY_PLIST: {path} is not a dictionary")
    return value


def _binary_candidates(bundle: Path) -> list[Path]:
    executable_name = str(read_plist(bundle / "Info.plist").get("CFBundleExecutable", ""))
    candidates: list[Path] = []
    if executable_name:
        candidates.append(bundle / executable_name)
    for framework in bundle.rglob("*.framework"):
        if framework.is_dir():
            candidates.append(framework / framework.stem)
    candidates.extend(path for path in bundle.rglob("*.dylib") if path.is_file())
    for appex in bundle.rglob("*.appex"):
        if appex.is_dir() and (appex / "Info.plist").exists():
            executable = str(read_plist(appex / "Info.plist").get("CFBundleExecutable", ""))
            if executable:
                candidates.append(appex / executable)
    return list(dict.fromkeys(candidates))


def scan_frameworks(bundle: Path, require: bool) -> set[str]:
    otool = shutil.which("otool")
    if not bundle.is_dir():
        if require:
            raise SystemExit(f"BLOCKED_PRIVACY_BINARY_SCAN: bundle not found: {bundle}")
        return set()
    if not otool:
        if require:
            raise SystemExit("BLOCKED_PRIVACY_BINARY_SCAN: otool is unavailable")
        return set()
    candidates = _binary_candidates(bundle)
    if require and not candidates:
        raise SystemExit("BLOCKED_PRIVACY_BINARY_SCAN: no executable or embedded binaries found")
    found: set[str] = set()
    scanned = 0
    for binary in candidates:
        if not binary.is_file():
            if require:
                raise SystemExit(f"BLOCKED_PRIVACY_BINARY_SCAN: binary not found: {binary}")
            continue
        try:
            otool_result = subprocess.run(
                [otool, "-L", str(binary)], capture_output=True, text=True, check=False
            )
        except OSError:
            if require:
                raise SystemExit(f"BLOCKED_PRIVACY_BINARY_SCAN: otool failed for {binary}")
            continue
        if otool_result.returncode != 0:
            if require:
                raise SystemExit(f"BLOCKED_PRIVACY_BINARY_SCAN: otool failed for {binary}")
            continue
        scanned += 1
        output = otool_result.stdout + otool_result.stderr
        for framework in FRAMEWORK_KEYS:
            if f"{framework}.framework" in output:
                found.add(framework)
        try:
            nm_result = subprocess.run(["nm", "-u", str(binary)], capture_output=True, text=True, check=False)
            strings_result = subprocess.run(["strings", str(binary)], capture_output=True, text=True, check=False)
        except OSError:
            if require:
                raise SystemExit(f"BLOCKED_PRIVACY_BINARY_SCAN: nm/strings failed for {binary}")
            continue
        if require and (nm_result.returncode != 0 or strings_result.returncode != 0):
            raise SystemExit(f"BLOCKED_PRIVACY_BINARY_SCAN: nm/strings failed for {binary}")
        symbol_text = nm_result.stdout + strings_result.stdout
        for framework in FRAMEWORK_KEYS:
            if framework in symbol_text:
                found.add(framework)
    if require and scanned == 0:
        raise SystemExit("BLOCKED_PRIVACY_BINARY_SCAN: no binaries were successfully scanned")
    return found


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner-plist", required=True, type=Path)
    parser.add_argument("--widget-plist", required=True, type=Path)
    parser.add_argument("--runner-bundle", type=Path)
    parser.add_argument("--require-binary-scan", action="store_true")
    args = parser.parse_args()
    runner = read_plist(args.runner_plist)
    widget = read_plist(args.widget_plist)
    missing = sorted(key for key in REQUIRED if not str(runner.get(key, "")).strip())
    if missing:
        raise SystemExit(
            "BLOCKED_RUNNER_PRIVACY: missing required usage descriptions: "
            + ", ".join(missing)
        )
    forbidden = sorted(key for key in WIDGET_FORBIDDEN if key in widget)
    if forbidden:
        raise SystemExit(
            "BLOCKED_WIDGET_PRIVACY: Widget contains Runner-only usage descriptions: "
            + ", ".join(forbidden)
        )
    print("IOS_PRIVACY_PLIST_GATE: PASS")
    if args.runner_bundle:
        frameworks = scan_frameworks(args.runner_bundle, args.require_binary_scan)
        for framework in sorted(frameworks):
            print(f"IOS_PRIVACY_LINKED_FRAMEWORK: {framework} -> {FRAMEWORK_KEYS[framework]}")
        print("IOS_PRIVACY_BINARY_SCAN: " + ("PASS" if frameworks else "PASS_NO_MAPPED_FRAMEWORKS"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
