#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname -- "$SCRIPT_DIR")
DESTINATION="$PROJECT_DIR/GaussianSplatMobile/Resources/sample_scene.ply"
ARCHIVE_URL="https://projects.markkellogg.org/downloads/gaussian_splat_data.zip"
ARCHIVE_RANGE="36769259-40808021"
EXPECTED_KSPLAT_SHA256="161922dd7b5667ad1881ca3105e183d4da3b2f2fc4595c9e129fd772542cae43"
EXPECTED_PLY_SHA256="5108445bc1594d6b6c5cb862b8c5084caf339e742b397f2295230684e576989b"
TEMP_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT INT TERM

echo "Downloading only the Bonsai entry from the public 563 MB archive..."
curl -fL -r "$ARCHIVE_RANGE" "$ARCHIVE_URL" -o "$TEMP_DIR/bonsai.zipentry"
python3 "$SCRIPT_DIR/extract_zip_entry.py" \
    "$TEMP_DIR/bonsai.zipentry" \
    "$TEMP_DIR/bonsai_trimmed.ksplat" \
    4244696

KSPLAT_SHA256=$(shasum -a 256 "$TEMP_DIR/bonsai_trimmed.ksplat" | awk '{print $1}')
if [ "$KSPLAT_SHA256" != "$EXPECTED_KSPLAT_SHA256" ]; then
    echo "Unexpected KSPLAT checksum: $KSPLAT_SHA256" >&2
    exit 1
fi

echo "Converting KSPLAT to standard 3DGS PLY..."
npx --registry=https://registry.npmjs.org -y \
    @playcanvas/splat-transform@3.3.0 \
    -w \
    "$TEMP_DIR/bonsai_trimmed.ksplat" \
    "$DESTINATION"

PLY_SHA256=$(shasum -a 256 "$DESTINATION" | awk '{print $1}')
if [ "$PLY_SHA256" != "$EXPECTED_PLY_SHA256" ]; then
    echo "Unexpected PLY checksum: $PLY_SHA256" >&2
    exit 1
fi

echo "Installed: $DESTINATION"
