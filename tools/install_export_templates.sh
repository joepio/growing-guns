#!/usr/bin/env bash
# Download + extract Godot export templates for the version Godot expects.
# This lets `tools/build_release.sh win` work without opening the Godot editor.
#
# Templates download is ~700 MB (covers all platforms — Linux/Win/Mac/Web).
# Once installed, builds for any of those platforms work via CLI.
#
# Usage: tools/install_export_templates.sh

set -euo pipefail

GODOT_VERSION="4.6.2-stable"
DEST="$HOME/Library/Application Support/Godot/export_templates/4.6.2.stable"
URL="https://github.com/godotengine/godot/releases/download/$GODOT_VERSION/Godot_v${GODOT_VERSION}_export_templates.tpz"

if [[ -f "$DEST/windows_release_x86_64.exe" && -f "$DEST/macos.zip" ]]; then
	echo "Export templates already installed at: $DEST"
	exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $URL"
echo "  (~700 MB — only needed once per Godot version)"
curl -L --fail --progress-bar -o "$TMP/templates.tpz" "$URL"

# .tpz is a regular zip with templates/ at the root.
echo "Extracting to: $DEST"
mkdir -p "$DEST"
unzip -q -o "$TMP/templates.tpz" -d "$TMP"
# The zip extracts into a `templates/` subdir; move its contents up.
cp -R "$TMP/templates/." "$DEST/"

echo "Done. Verify:"
ls "$DEST" | head -10
