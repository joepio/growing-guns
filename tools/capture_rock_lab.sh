#!/usr/bin/env bash
# Capture rock_lab to artifacts/ (requires GPU — do not pass --headless).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-artifacts/rock_lab.png}"
mkdir -p "$ROOT/artifacts"
/Applications/Godot.app/Contents/MacOS/Godot \
	--path "$ROOT" \
	--resolution 1280x720 \
	--quit-after 8 \
	res://scenes/rock_lab.tscn \
	-- --capture "$OUT"
