#!/usr/bin/env python3
"""Fail-closed privacy preflight for the signed iOS app and its Widget.

This intentionally checks only evidence supplied by the built app.  It does
not add speculative usage descriptions.  On macOS, an optional bundle scan
uses otool to identify linked sensitive frameworks; unknown symbols are only
reported, never treated as proof of a permission requirement.
"""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
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
SCAN_REPORT: list[dict] = []
EVIDENCE_PATTERN = re.compile(
    r"(?:AVFoundation|Speech|AppTrackingTransparency|AdSupport|CoreLocation|"
    r"NS(?:Microphone|SpeechRecognition|UserTracking|Location).*UsageDescription|"
    r"CNContactStore|EKEventStore|PHPhotoLibrary|AVCaptureDevice|CBCentralManager|"
    r"NWPathMonitor|CMMotionManager|LAContext|MPMediaLibrary)",
    re.IGNORECASE,
)


def _filtered_evidence(output: str) -> list[str]:
    return sorted({line.strip() for line in output.splitlines() if EVIDENCE_PATTERN.search(line)})[:50]


def _write_report(path: Path | None, payload: dict) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _which_tool(name: str, extra_dir: Path | None = None) -> str | None:
    """Resolve native tools, including deterministic .cmd fixtures on Windows."""
    if extra_dir is not None:
        for suffix in ("", ".cmd", ".exe"):
            candidate = extra_dir / f"{name}{suffix}"
            if candidate.is_file():
                return str(candidate)
    resolved = shutil.which(name)
    if resolved:
        return resolved
    if os.name == "nt":
        for directory in os.environ.get("PATH", "").split(os.pathsep):
            candidate = Path(directory) / f"{name}.cmd"
            if candidate.is_file():
                return str(candidate)
    return None


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


def scan_frameworks(bundle: Path, require: bool, tool_dir: Path | None = None) -> set[str]:
    otool = _which_tool("otool", tool_dir)
    binary_report = {"bundle": str(bundle), "otool": otool or "", "binaries": []}
    SCAN_REPORT.append(binary_report)
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
        entry = {"path": str(binary), "commands": {}}
        binary_report["binaries"].append(entry)
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
        entry["commands"]["otool"] = {
            "returncode": otool_result.returncode,
            "filteredEvidence": _filtered_evidence(otool_result.stdout + otool_result.stderr),
        }
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
            nm_tool = _which_tool("nm", tool_dir)
            strings_tool = _which_tool("strings", tool_dir)
            if not nm_tool or not strings_tool:
                raise OSError("nm/strings unavailable")
            nm_result = subprocess.run([nm_tool, "-u", str(binary)], capture_output=True, text=True, check=False)
            strings_result = subprocess.run([strings_tool, str(binary)], capture_output=True, text=True, check=False)
        except OSError:
            if require:
                raise SystemExit(f"BLOCKED_PRIVACY_BINARY_SCAN: nm/strings failed for {binary}")
            continue
        entry["commands"]["nm"] = {
            "returncode": nm_result.returncode,
            "filteredEvidence": _filtered_evidence(nm_result.stdout + nm_result.stderr),
        }
        entry["commands"]["strings"] = {
            "returncode": strings_result.returncode,
            "filteredEvidence": _filtered_evidence(strings_result.stdout + strings_result.stderr),
        }
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
    parser.add_argument("--report-json", type=Path)
    parser.add_argument("--tool-dir", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.require_binary_scan and args.runner_bundle is None:
        raise SystemExit(
            "BLOCKED_PRIVACY_BINARY_SCAN: --runner-bundle is required with --require-binary-scan"
        )
    report = {"runnerPlist": str(args.runner_plist), "widgetPlist": str(args.widget_plist), "status": "FAIL"}
    try:
        runner = read_plist(args.runner_plist)
        widget = read_plist(args.widget_plist)
        report["runnerKeys"] = {key: bool(str(runner.get(key, "")).strip()) for key in sorted(REQUIRED)}
        report["widgetForbiddenKeys"] = sorted(key for key in WIDGET_FORBIDDEN if key in widget)
        missing = sorted(key for key in REQUIRED if not str(runner.get(key, "")).strip())
        if missing:
            raise SystemExit("BLOCKED_RUNNER_PRIVACY: missing required usage descriptions: " + ", ".join(missing))
        if report["widgetForbiddenKeys"]:
            raise SystemExit("BLOCKED_WIDGET_PRIVACY: Widget contains Runner-only usage descriptions: " + ", ".join(report["widgetForbiddenKeys"]))
        print("IOS_PRIVACY_PLIST_GATE: PASS")
        if args.runner_bundle:
            frameworks = scan_frameworks(args.runner_bundle, args.require_binary_scan, args.tool_dir)
            report["linkedFrameworks"] = {framework: FRAMEWORK_KEYS[framework] for framework in sorted(frameworks)}
            print("IOS_PRIVACY_BINARY_SCAN: " + ("PASS" if frameworks else "PASS_NO_MAPPED_FRAMEWORKS"))
        report["status"] = "PASS"
        return 0
    except SystemExit as exc:
        report["error"] = str(exc)
        raise
    finally:
        report["binaryScan"] = SCAN_REPORT
        _write_report(args.report_json, report)


if __name__ == "__main__":
    raise SystemExit(main())
