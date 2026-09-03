#!/bin/bash
set -euo pipefail

source_url="https://huggingface.co/datasets/pjramg/gaussian_splatting/resolve/main/FO_dataset/drjohnson/point_cloud/iteration_30000/point_cloud.ply?download=true"
expected_vertex_count="3177554"
expected_sha256="92f4898839ec4ad7f197cf6c74b89918b35ea712b4e41435593ccb152d22b7f5"

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
output_dir="$project_dir/ValidationAssets"
output_ply="$output_dir/drjohnson_full_sh3.ply"
output_manifest="$output_dir/drjohnson_full_sh3.json"
partial_ply="$output_dir/.drjohnson_full_sh3.ply.partial"

mkdir -p "$output_dir"

if [[ -f "$output_ply" ]]; then
  python3 "$script_dir/validate_binary_ply.py" \
    "$output_ply" "$output_manifest" "$expected_vertex_count" "$expected_sha256"
  echo "Complete validation scene already exists: $output_ply"
  exit 0
fi

curl -fL --retry 10 --retry-all-errors --retry-delay 2 \
  --continue-at - "$source_url" --output "$partial_ply"
python3 "$script_dir/validate_binary_ply.py" \
  "$partial_ply" "$output_manifest" "$expected_vertex_count" "$expected_sha256"
mv "$partial_ply" "$output_ply"

echo "Complete validation scene ready: $output_ply"
echo "Manifest: $output_manifest"
