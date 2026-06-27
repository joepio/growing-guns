#!/usr/bin/env bash
# Capture start_screen to artifacts/ (requires GPU — do not pass --headless).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-artifacts/menu_cinematic.png}"
mkdir -p "$ROOT/artifacts"
/Applications/Godot.app/Contents/MacOS/Godot \
	--path "$ROOT" \
	--resolution 1280x720 \
	--quit-after 12 \
	res://scenes/start_screen.tscn \
	-- --capture "$OUT"
