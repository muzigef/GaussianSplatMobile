#!/usr/bin/env python3
"""Extract one already range-downloaded, Deflate-compressed ZIP local record."""

from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: extract_zip_entry.py INPUT OUTPUT EXPECTED_SIZE")

    source_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])
    expected_size = int(sys.argv[3])

    with source_path.open("rb") as source:
        local_header = source.read(30)
    if len(local_header) != 30:
        raise SystemExit("input is shorter than a ZIP local file header")
    header = struct.unpack("<4s5H3I2H", local_header)
    if header[0] != b"PK\x03\x04":
        raise SystemExit("input does not begin with a ZIP local file header")
    if header[3] != 8:
        raise SystemExit(f"unsupported ZIP compression method: {header[3]}")

    filename_length = header[9]
    extra_length = header[10]
    payload_offset = 30 + filename_length + extra_length
    decompressor = zlib.decompressobj(-15)
    decoded_size = 0
    with source_path.open("rb") as source, output_path.open("wb") as output:
        source.seek(payload_offset)
        while compressed_chunk := source.read(1024 * 1024):
            decoded_chunk = decompressor.decompress(compressed_chunk)
            output.write(decoded_chunk)
            decoded_size += len(decoded_chunk)
        final_chunk = decompressor.flush()
        output.write(final_chunk)
        decoded_size += len(final_chunk)

    if decoded_size != expected_size:
        raise SystemExit(
            f"unexpected decoded size: {decoded_size} (expected {expected_size})"
        )
    if not decompressor.eof:
        raise SystemExit("compressed ZIP payload ended before the Deflate stream")


if __name__ == "__main__":
    main()
