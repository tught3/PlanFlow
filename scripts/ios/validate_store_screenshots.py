#!/usr/bin/env python3
"""Fail-closed validation for local iOS Store screenshot artifacts."""
from __future__ import annotations

import hashlib
import json
import re
import struct
import sys
import zlib
from pathlib import Path


PII_PATTERNS = (
    re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"),
    re.compile(r"(?:eyJ|sb_publishable_|sk_live_|pk_live_|ca-app-pub-)[A-Za-z0-9_-]+"),
)


def _paeth(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    left_distance = abs(estimate - left)
    above_distance = abs(estimate - above)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    if above_distance <= upper_left_distance:
        return above
    return upper_left


def png_info(path: Path) -> tuple[int, int, bool]:
    """Parse, integrity-check, decompress, and decode every PNG scanline."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"not a PNG: {path.name}")
    offset = 8
    chunks: list[tuple[bytes, bytes]] = []
    saw_iend = False
    while offset < len(data):
        if len(data) - offset < 12:
            raise ValueError(f"truncated PNG chunk header: {path.name}")
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        chunk_type = data[offset + 4:offset + 8]
        chunk_end = offset + 12 + length
        if chunk_end > len(data):
            raise ValueError(f"truncated PNG chunk payload: {path.name}")
        payload = data[offset + 8:offset + 8 + length]
        expected_crc = struct.unpack(">I", data[offset + 8 + length:chunk_end])[0]
        actual_crc = zlib.crc32(chunk_type)
        actual_crc = zlib.crc32(payload, actual_crc) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            raise ValueError(f"PNG CRC mismatch in {chunk_type!r}: {path.name}")
        chunks.append((chunk_type, payload))
        offset = chunk_end
        if chunk_type == b"IEND":
            saw_iend = True
            break
    if not saw_iend or offset != len(data):
        raise ValueError(f"missing IEND or trailing PNG data: {path.name}")
    if not chunks or chunks[0][0] != b"IHDR" or len(chunks[0][1]) != 13:
        raise ValueError(f"missing IHDR: {path.name}")

    width, height, depth, color_type, compression, filter_method, interlace = (
        struct.unpack(">IIBBBBB", chunks[0][1])
    )
    if width <= 0 or height <= 0:
        raise ValueError(f"invalid PNG dimensions: {path.name}")
    if depth != 8 or color_type not in (2, 6):
        raise ValueError(
            f"unsupported screenshot PNG depth/type {depth}/{color_type}: {path.name}"
        )
    if compression != 0 or filter_method != 0 or interlace != 0:
        raise ValueError(f"unsupported PNG encoding: {path.name}")
    compressed = b"".join(payload for kind, payload in chunks if kind == b"IDAT")
    if not compressed:
        raise ValueError(f"missing IDAT: {path.name}")
    try:
        decoded = zlib.decompress(compressed)
    except zlib.error as error:
        raise ValueError(f"invalid IDAT stream: {path.name}: {error}") from error

    bytes_per_pixel = 3 if color_type == 2 else 4
    row_bytes = width * bytes_per_pixel
    expected_length = height * (row_bytes + 1)
    if len(decoded) != expected_length:
        raise ValueError(
            f"decoded pixel length mismatch {len(decoded)} != {expected_length}: {path.name}"
        )
    prior = bytearray(row_bytes)
    opaque = True
    cursor = 0
    for _ in range(height):
        filter_type = decoded[cursor]
        cursor += 1
        if filter_type > 4:
            raise ValueError(f"invalid PNG filter {filter_type}: {path.name}")
        source = decoded[cursor:cursor + row_bytes]
        cursor += row_bytes
        row = bytearray(row_bytes)
        for index, value in enumerate(source):
            left = row[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            above = prior[index]
            upper_left = prior[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            if filter_type == 0:
                reconstructed = value
            elif filter_type == 1:
                reconstructed = value + left
            elif filter_type == 2:
                reconstructed = value + above
            elif filter_type == 3:
                reconstructed = value + ((left + above) // 2)
            else:
                reconstructed = value + _paeth(left, above, upper_left)
            row[index] = reconstructed & 0xFF
        if color_type == 6 and any(row[index] != 255 for index in range(3, row_bytes, 4)):
            opaque = False
        prior = row
    return width, height, opaque


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: validate_store_screenshots.py PLAN OUTPUT_DIR", file=sys.stderr)
        return 2
    plan = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    output = Path(sys.argv[2])
    devices = {d["slot"]: (d["width"], d["height"]) for d in plan["devices"]}
    shots = {s["screenshotId"]: s for s in plan["shots"]}
    files = sorted(output.glob("*.png"))
    expected = {
        f'{shot_id}-{slot}.png'
        for shot_id, shot in shots.items()
        for slot in shot["deviceSlots"]
    }
    actual = {p.name for p in files}
    if actual != expected:
        raise ValueError(f"artifact set mismatch: missing={sorted(expected-actual)} extra={sorted(actual-expected)}")
    hashes: dict[str, str] = {}
    for path in files:
        shot_id, slot, suffix = path.stem.rpartition("-")
        if suffix not in devices or shot_id not in shots:
            raise ValueError(f"unexpected screenshot filename: {path.name}")
        width, height, opaque = png_info(path)
        if suffix not in shots[shot_id]["deviceSlots"]:
            raise ValueError(f"shot/device mapping mismatch: {path.name}")
        expected_size = devices[suffix]
        if (width, height) != expected_size:
            raise ValueError(f"dimension mismatch {path.name}: got {width}x{height}, expected {expected_size[0]}x{expected_size[1]}")
        if not opaque:
            raise ValueError(f"alpha channel is not allowed: {path.name}")
        raw = path.read_bytes()
        text = raw.decode("latin1", errors="ignore")
        for pattern in PII_PATTERNS:
            if pattern.search(text):
                raise ValueError(f"possible PII/credential token in PNG metadata: {path.name}")
        digest = hashlib.sha256(raw).hexdigest()
        if digest in hashes.values():
            duplicate = next(name for name, value in hashes.items() if value == digest)
            raise ValueError(f"duplicate screenshot content: {path.name} and {duplicate}")
        hashes[path.name] = digest
    print(f"SCREENSHOT_VALIDATION_PASS count={len(files)}")
    for name in sorted(hashes):
        print(f"{name} sha256={hashes[name]}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"SCREENSHOT_VALIDATION_FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
