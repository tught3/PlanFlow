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
    creationflags = 0
    if os.name == "nt":
        creationflags = subprocess.CREATE_NEW_PROCESS_GROUP
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            shell=True,
            creationflags=creationflags,
        )
        out, err = proc.communicate(timeout=timeout)
        out = (out or "").strip()
        err = (err or "").strip()
        # 결과를 파일로 저장 (콘솔 인코딩 문제 방지)
        safe_label = label.replace(" ", "_").replace("/", "_")
        with open(f"scripts/_verify_{safe_label}.log", "w", encoding="utf-8") as f:
            f.write(f"CMD: {cmd}\nEXIT: {proc.returncode}\n\n--- STDOUT ---\n{out}\n\n--- STDERR ---\n{err}\n")
        results.append((label, proc.returncode, out[-2000:]))
        # ASCII-safe print
        try:
            print(f"EXIT: {proc.returncode}")
            # Print only last 1500 chars, replace non-ascii for console
            tail = out[-1500:]
            print(tail.encode("ascii", "replace").decode("ascii"))
        except Exception:
            pass
        return proc.returncode
    except subprocess.TimeoutExpired as e:
        print(f"TIMEOUT after {timeout}s")
        timed_out_out = (e.stdout or "").strip()
        timed_out_err = (e.stderr or "").strip()
        if 'proc' in locals() and proc.poll() is None:
            if os.name == "nt":
                subprocess.run(
                    ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                )
            else:
                proc.kill()
        try:
            out, err = proc.communicate(timeout=10)
            timed_out_out = (out or timed_out_out or "").strip()
            timed_out_err = (err or timed_out_err or "").strip()
        except Exception:
            pass
        safe_label = label.replace(" ", "_").replace("/", "_")
        with open(f"scripts/_verify_{safe_label}.log", "w", encoding="utf-8") as f:
            f.write(
                f"CMD: {cmd}\nEXIT: TIMEOUT after {timeout}s\n\n--- STDOUT ---\n{timed_out_out}\n\n--- STDERR ---\n{timed_out_err}\n"
            )
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
