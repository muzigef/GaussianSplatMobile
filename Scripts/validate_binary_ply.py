#!/usr/bin/env python3
"""Validate a complete binary Graphdeco SH3 PLY and write its manifest."""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path


TYPE_WIDTHS = {
    "char": 1,
    "int8": 1,
    "uchar": 1,
    "uint8": 1,
    "short": 2,
    "int16": 2,
    "ushort": 2,
    "uint16": 2,
    "int": 4,
    "int32": 4,
    "uint": 4,
    "uint32": 4,
    "float": 4,
    "float32": 4,
    "double": 8,
    "float64": 8,
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit(
            "usage: validate_binary_ply.py INPUT MANIFEST_JSON "
            "EXPECTED_VERTEX_COUNT EXPECTED_SHA256"
        )

    source_path = Path(sys.argv[1])
    manifest_path = Path(sys.argv[2])
    expected_vertex_count = int(sys.argv[3])
    expected_sha256 = sys.argv[4].lower()

    with source_path.open("rb") as source:
        header = bytearray()
        while not header.endswith(b"end_header\n"):
            byte = source.read(1)
            if not byte or len(header) >= 256 * 1024:
                raise SystemExit("invalid or oversized PLY header")
            header.extend(byte)

    header_text = header.decode("ascii")
    if "format binary_little_endian 1.0" not in header_text:
        raise SystemExit("only binary_little_endian PLY 1.0 is supported")

    vertex_match = re.search(r"(?m)^element vertex (\d+)$", header_text)
    if not vertex_match:
        raise SystemExit("PLY has no vertex element")
    vertex_count = int(vertex_match.group(1))
    if vertex_count != expected_vertex_count:
        raise SystemExit(
            f"unexpected vertex count {vertex_count}; expected complete source count "
            f"{expected_vertex_count}"
        )

    in_vertex = False
    property_names: list[str] = []
    vertex_stride = 0
    element_names: list[str] = []
    for line in header_text.splitlines():
        if line.startswith("element "):
            parts = line.split()
            element_names.append(parts[1])
            in_vertex = parts[1] == "vertex"
        elif in_vertex and line.startswith("property "):
            parts = line.split()
            if len(parts) != 3 or parts[1] == "list":
                raise SystemExit("vertex list properties are unsupported")
            try:
                vertex_stride += TYPE_WIDTHS[parts[1]]
            except KeyError as error:
                raise SystemExit(f"unsupported PLY type: {parts[1]}") from error
            property_names.append(parts[2])

    if element_names != ["vertex"]:
        raise SystemExit(f"expected only a vertex element, found {element_names}")
    rest_names = sorted(
        (name for name in property_names if name.startswith("f_rest_")),
        key=lambda name: int(name.removeprefix("f_rest_")),
    )
    if rest_names != [f"f_rest_{index}" for index in range(45)]:
        raise SystemExit("validation source is not a contiguous SH3 Graphdeco PLY")

    expected_size = len(header) + vertex_count * vertex_stride
    actual_size = source_path.stat().st_size
    if actual_size != expected_size:
        raise SystemExit(
            f"unexpected file size {actual_size}; expected {expected_size} for all vertices"
        )

    actual_sha256 = sha256(source_path)
    if actual_sha256 != expected_sha256:
        raise SystemExit(
            f"unexpected SHA-256 {actual_sha256}; expected {expected_sha256}"
        )

    manifest = {
        "source": "pjramg/gaussian_splatting / Dr Johnson / iteration 30000 (trained with the official Graphdeco implementation)",
        "source_url": "https://huggingface.co/datasets/pjramg/gaussian_splatting/blob/main/FO_dataset/drjohnson/point_cloud/iteration_30000/point_cloud.ply",
        "vertex_count": vertex_count,
        "sh_degree": 3,
        "f_rest_property_count": len(rest_names),
        "vertex_stride_bytes": vertex_stride,
        "file_size_bytes": actual_size,
        "sha256": actual_sha256,
        "selection": "complete source PLY (no vertex cropping)",
    }
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
