#!/bin/bash
# Copy the plugin into ~/.config/omarchy/plugins/govee and put it on the bar.
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)"
dest="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/govee"
omarchy plugin validate "$src"
mkdir -p "$dest/i18n"
install -m 644 "$src/manifest.json" "$src/Panel.qml" "$src/Model.js" "$dest/"
install -m 755 "$src/govee.py" "$dest/"
install -m 644 "$src/i18n/"*.json "$dest/i18n/"
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do omarchy plugin list | grep -q "govee" && break; read -rt 1 <> <(:) || true; done
omarchy plugin list --json | jq -e '.[] | select(.id == "govee" and .enabled == true)' >/dev/null 2>&1 \
  || omarchy plugin enable govee --section right
echo "Installed Govee plugin to $dest"
