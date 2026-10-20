#!/bin/bash
# Promotional screenshots of PureMac with fictional demo data.
#
#   Scripts/Promo/make_screenshots.sh <output-folder> [en de ...]   (default: en)
#
# Builds the Debug app, generates the mock Mac (Scripts/Promo/make_demo.py), opens PureMac in its
# DEBUG-only demo mode once per scene, captures the real window with macOS's `screencapture`
# (needs Screen Recording permission for the terminal), and writes for each scene:
#   <out>/<lang>/window/NN-name.png   the window alone, transparent corners
#   <out>/<lang>/NN-name.png          the window on a branded background (website / store)
# Window size is 1440×900 points: 1440×900 px on a standard display, 2880×1800 px on Retina.
# PureMac windows open in front while this runs (about 15 seconds per scene).
# ONLY=applications limits the run to scenes whose name contains that text.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:?usage: make_screenshots.sh <output-folder> [languages…]}"
shift
if [[ $# -gt 0 ]]; then LANGS=("$@"); else LANGS=(en); fi
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/PureMac-cli"
WORK="$(cd "$(mktemp -d -t puremac-promo)" && pwd -P)"   # real path: /var is a symlink to /private/var
DEMO="$WORK/demo"
APP="$DERIVED/Build/Products/Debug/PureMac.app"

echo "==> Build (Debug)"
xcodebuild -project PureMac.xcodeproj -scheme PureMac -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO build -quiet
swiftc -O Scripts/Promo/capture.swift -o "$WORK/capture" 2>/dev/null
swiftc -O Scripts/Promo/frame.swift -o "$WORK/frame" 2>/dev/null

echo "==> Mock Mac"
python3 Scripts/Promo/make_demo.py --root "$DEMO"

# name | sidebar section | demo scene | appearance | extra arguments
SCENES=(
  "01-overview|overview||dark|"
  "02-scanning|overview|scanning|dark|"
  "03-smart-clean|smartClean||dark|"
  "04-review-before-cleaning|smartClean|review|dark|"
  "05-storage-explorer-treemap|explorer||dark|"
  "06-storage-explorer-sunburst|explorer||dark|-PureMacExplorerMap sunburst"
  "07-applications|applications|apps|dark|"
  "08-orphaned-remnants|orphans|orphans|dark|"
  "09-duplicates|duplicates|duplicates|dark|"
  "10-developer-storage|developer|developer|dark|"
  "11-performance|performance||dark|"
  "12-history|history||dark|"
  "13-overview-light|overview||light|"
  "14-applications-light|applications|apps|light|"
)

locale_for() {
  case "$1" in
    tr) echo tr_TR ;; de) echo de_DE ;; fr) echo fr_FR ;; it) echo it_IT ;; pt-BR) echo pt_BR ;;
    nl) echo nl_NL ;; sv) echo sv_SE ;; nb) echo nb_NO ;; da) echo da_DK ;; fi) echo fi_FI ;;
    ru) echo ru_RU ;; pl) echo pl_PL ;; ja) echo ja_JP ;; ko) echo ko_KR ;; zh-Hans) echo zh_CN ;;
    zh-Hant) echo zh_TW ;; ar) echo ar_SA ;; *) echo en_US ;;
  esac
}

for lang in "${LANGS[@]}"; do
  mkdir -p "$OUT/$lang/window"
  for entry in "${SCENES[@]}"; do
    IFS='|' read -r name section scene appearance extra <<< "$entry"
    [[ -n "${ONLY:-}" && "$name" != *"$ONLY"* ]] && continue
    args=(-PureMacDemo YES -PureMacInitialSection "$section" -PureMacWindowSize 1440x900 -appearance "$appearance" -AppleLanguages "($lang)" -AppleLocale "$(locale_for "$lang")" -ApplePersistenceIgnoreState YES)
    [[ -n "$scene" ]] && args+=(-PureMacDemoScene "$scene")
    # shellcheck disable=SC2206
    [[ -n "$extra" ]] && args+=($extra)
    open -n --env "PUREMAC_DEMO_ROOT=$DEMO" --env "PUREMAC_DEMO_HOME=$DEMO/Users/alex" "$APP" --args "${args[@]}"
    sleep 2
    pid=$(pgrep -n -f "$APP/Contents/MacOS/PureMac")
    open "$APP"   # bring the running instance to the front (active window colors)
    sleep 8
    # A slow launch may not have its window yet: retry for a few seconds.
    for attempt in 1 2 3 4 5; do
      pid=$(pgrep -n -f "$APP/Contents/MacOS/PureMac" || true)
      [[ -n "$pid" ]] && "$WORK/capture" "$pid" "$OUT/$lang/window/$name.png" && break
      [[ $attempt -eq 5 ]] && { echo "error: no window for $name" >&2; exit 1; }
      sleep 3
    done
    "$WORK/frame" "$OUT/$lang/window/$name.png" "$OUT/$lang/$name.png" "$appearance" > /dev/null
    kill "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do sleep 0.3; done
  done
done

defaults delete com.openappbox.PureMac.demo 2>/dev/null || true
rm -rf "$WORK"
echo "==> Screenshots in $OUT"
