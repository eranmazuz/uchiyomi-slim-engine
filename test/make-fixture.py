#!/usr/bin/env python3
"""Generate test/fixtures/local-library/Test Manga/Chapter 1.cbz -- the hermetic fixture.

The CI smoke test serves pages out of this CBZ through Suwayomi's built-in Local source, so the page
path (chapter -> page URLs -> page bytes) is exercised with no external site, no extension and no
network in the path. Reproducible: run this to regenerate the committed fixture.

    python3 test/make-fixture.py
"""
import os
import shutil
import struct
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "fixtures", "local-library", "Test Manga", "Chapter 1.cbz")
PAGES = 5


def png(path, w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def main():
    tmp = os.path.join(HERE, ".fixture-tmp")
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    for i in range(1, PAGES + 1):
        png(os.path.join(tmp, f"{i:03d}.png"), 300, 400, (30 * i % 255, 90, 200 - 20 * i))
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        for i in range(1, PAGES + 1):
            z.write(os.path.join(tmp, f"{i:03d}.png"), f"{i:03d}.png")
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"wrote {OUT} ({os.path.getsize(OUT)} bytes, {PAGES} pages)")


if __name__ == "__main__":
    main()
