#!/bin/bash
# Render every design board (plus setting/hover variants) to PNGs.
# Usage: docs/design/tools/render-all.sh <path to dc-runtime.js> [out dir]
# dc-runtime.js comes from the canvas artifact: Artifact read, url = canvas, path = artifact-type/dc-runtime.js
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
RUNTIME=${1:?path to dc-runtime.js}
OUT=${2:-$HERE/../screenshots}
WORK=$(mktemp -d)
cp "$HERE"/../canvas/*.dc.html "$WORK"/
cp "$RUNTIME" "$WORK"/support.js
mk() { sed -e "s|<dc-import name=\"Main\" probes=\"8\" hint-size=\"100%,900px\">|<dc-import $2 hint-size=\"1440px,900px\">|" "$WORK"/Main8.dc.html > "$WORK"/$1.dc.html; }
mk Main1At 'name="Main" probes="1" time-format="Ready at"'
mk Kitchen1At 'name="Kitchen" probes="1" time-format="Ready at"'
mk SettingsAlerts 'name="Settings" section="Alerts and sounds"'
mk SettingsDevices 'name="Settings" section="Devices"'
mkdir -p "$OUT"; rm -f -- "$OUT"/*.png
node "$HERE"/shoot.mjs "$WORK" "$OUT" Main1:1440:900 Main1:1440:900:hover Main1At:1440:900 Main:1440:900 MainAlert:1440:900 Main8:1440:900 Kitchen1:1440:900 Kitchen1At:1440:900 Kitchen:1440:900 KitchenAlert:1440:900 LiveActivity:1440:1000 WindowsSurfaces:1440:1000 Sheets:1440:1140 Tokens:1440:1000 Onboarding:1440:1000 History:1440:900 History:1440:900:hover Settings:1440:900 SettingsAlerts:1440:900 SettingsDevices:1440:900 InstantRead:1440:900 KitchenInstant:1440:900 States:1440:1400
rm -rf -- "$WORK"
