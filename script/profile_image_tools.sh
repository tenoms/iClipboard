#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ROOT="${1:-$ROOT_DIR}"
if [[ ! -f "$SOURCE_ROOT/iClipboard/ImageTools/Models/ToolImage.swift" ]]; then
  printf 'usage: %s [source-snapshot-root]\n' "$0" >&2
  exit 2
fi
OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iclipboard-image-profile.XXXXXX")"
printf 'Profile artifacts: %s\n' "$OUTPUT_DIR"
FLAGS=(-D CURRENT_CAPTURE)
if ! /usr/bin/grep -q 'static func capturedImage' "$SOURCE_ROOT/iClipboard/Store/Models/CapturedPayload.swift"; then
  FLAGS=(-D LEGACY_CAPTURE)
fi
xcrun swiftc -O -parse-as-library "${FLAGS[@]}" \
  "$ROOT_DIR/script/image_tools_performance.swift" \
  "$SOURCE_ROOT/iClipboard/ImageTools/Models/ToolImage.swift" \
  "$SOURCE_ROOT/iClipboard/ImageTools/Editing/ImageDocument.swift" \
  "$SOURCE_ROOT/iClipboard/Store/Models/CapturedPayload.swift" \
  "$SOURCE_ROOT/iClipboard/Store/Models/ClipboardContentKind.swift" \
  "$SOURCE_ROOT/iClipboard/Store/Utilities/ImagePreviewLoader.swift" \
  "$SOURCE_ROOT/iClipboard/Store/Utilities/Extensions.swift" \
  -o "$OUTPUT_DIR/probe"
"$OUTPUT_DIR/probe" fixture "$OUTPUT_DIR/fixture.jpg"
"$OUTPUT_DIR/probe" mosaic-digest "$OUTPUT_DIR/fixture.jpg"
for run in 1 2 3; do
  printf 'Run %s\n' "$run"
  for scenario in capture mosaic empty; do
    "$OUTPUT_DIR/probe" "$scenario" "$OUTPUT_DIR/fixture.jpg"
  done
done
