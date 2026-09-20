#!/usr/bin/env python3
from __future__ import annotations

import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "docs" / "assets"
REQUIRED = ("chat.png", "history.png", "memory.png", "tools.png", "settings.png")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
FORBIDDEN_METADATA_CHUNKS = {b"tEXt", b"zTXt", b"iTXt", b"eXIf"}
EXPECTED_SIZE = (432, 960)


def inspect_png(path: Path) -> None:
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        raise SystemExit(f"Not a PNG: {path.relative_to(ROOT)}")
    if len(data) > 1_000_000:
        raise SystemExit(f"Demo asset unexpectedly large: {path.relative_to(ROOT)}")

    offset = len(PNG_SIGNATURE)
    width = height = None
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        kind = data[offset + 4 : offset + 8]
        payload_start = offset + 8
        payload_end = payload_start + length
        if payload_end + 4 > len(data):
            raise SystemExit(f"Malformed PNG: {path.relative_to(ROOT)}")
        payload = data[payload_start:payload_end]
        if kind in FORBIDDEN_METADATA_CHUNKS:
            raise SystemExit(
                f"Text/EXIF metadata is not allowed in demo asset: {path.relative_to(ROOT)}"
            )
        if kind == b"IHDR":
            width, height = struct.unpack(">II", payload[:8])
        offset = payload_end + 4
        if kind == b"IEND":
            break

    if (width, height) != EXPECTED_SIZE:
        raise SystemExit(
            f"Unexpected demo asset size for {path.relative_to(ROOT)}: "
            f"{width}x{height}; expected {EXPECTED_SIZE[0]}x{EXPECTED_SIZE[1]}"
        )


def main() -> int:
    missing = [name for name in REQUIRED if not (ASSETS / name).is_file()]
    if missing:
        raise SystemExit("Missing demo assets: " + ", ".join(missing))
    for name in REQUIRED:
        inspect_png(ASSETS / name)
    print(f"Demo asset check passed: {len(REQUIRED)} sanitized PNGs.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
