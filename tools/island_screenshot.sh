#!/usr/bin/env bash
# Generate a screenshot of a procedural island for fast LLM-driven iteration.
#
# Usage:
#   tools/island_screenshot.sh                    # random seed, iso cam
#   tools/island_screenshot.sh 42                 # explicit seed
#   tools/island_screenshot.sh 42 top             # seed + camera (iso|top|ground)
#   tools/island_screenshot.sh 42 iso --radius=30 --tiers=5
#
# Output: .tmp/island_<seed>_<cam>.png (project-relative)
# Stdout: prints the absolute path of the saved PNG so callers can pipe it.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"

SEED="${1:-$RANDOM}"
CAM="${2:-iso}"
shift || true
shift || true
EXTRA_ARGS=("$@")

mkdir -p "$ROOT/.tmp"
OUT="$ROOT/.tmp/island_${SEED}_${CAM}.png"
rm -f "$OUT"

# Run Godot with the preview scene. Args after `--` are forwarded to
# OS.get_cmdline_user_args() so the preview script can parse them.
"$GODOT_BIN" --path "$ROOT" \
	res://scenes/island_preview.tscn \
	-- \
	"--seed=$SEED" \
	"--cam=$CAM" \
	"--screenshot=$OUT" \
	"${EXTRA_ARGS[@]}" \
	>/dev/null 2>&1 || true

if [ ! -f "$OUT" ]; then
	echo "ERROR: screenshot was not produced at $OUT" >&2
	exit 1
fi

echo "$OUT"
