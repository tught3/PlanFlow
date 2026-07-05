#!/usr/bin/env python3
"""임시 검증 스크립트: flutter test + analyze 실행 후 결과 출력."""
import os
import subprocess
import sys

os.environ["PATH"] = r"C:\src\flutter\bin;" + os.environ.get("PATH", "")
os.chdir(r"E:\FluxStudio\planflow")

results = []

def run(cmd, label, timeout=240):
    print(f"\n{'='*60}")
    print(f"RUN: {label}")
    print(f"CMD: {cmd}")
    print(f"{'='*60}")
    try:
        r = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            shell=True,
        )
        out = (r.stdout or "").strip()
        err = (r.stderr or "").strip()
        # 결과를 파일로 저장 (콘솔 인코딩 문제 방지)
        safe_label = label.replace(" ", "_").replace("/", "_")
        with open(f"scripts/_verify_{safe_label}.log", "w", encoding="utf-8") as f:
            f.write(f"CMD: {cmd}\nEXIT: {r.returncode}\n\n--- STDOUT ---\n{out}\n\n--- STDERR ---\n{err}\n")
        results.append((label, r.returncode, out[-2000:]))
        # ASCII-safe print
        try:
            print(f"EXIT: {r.returncode}")
            # Print only last 1500 chars, replace non-ascii for console
            tail = out[-1500:]
            print(tail.encode("ascii", "replace").decode("ascii"))
        except Exception:
            pass
        return r.returncode
    except subprocess.TimeoutExpired:
        print(f"TIMEOUT after {timeout}s")
        results.append((label, -1, "TIMEOUT"))
        return -1
    except Exception as e:
        print(f"ERROR: {e}")
        results.append((label, -2, str(e)))
        return -2

# 1. api_usage_guard_test
run("flutter test test/services/api_usage_guard_test.dart --no-pub -r compact",
    "api_usage_guard_test", timeout=180)

# 2. analyze changed files
run("flutter analyze lib/services/api_usage_guard.dart lib/services/location_lookup_service.dart lib/screens/home/home_screen.dart test/services/api_usage_guard_test.dart --no-pub",
    "analyze_changed", timeout=180)

print(f"\n{'='*60}")
print("SUMMARY:")
for label, code, tail in results:
    status = "PASS" if code == 0 else f"FAIL({code})"
    print(f"  {label}: {status}")
