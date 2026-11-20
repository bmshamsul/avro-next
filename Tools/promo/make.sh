#!/bin/zsh
# Builds the Avro Next promo film:  Tools/promo/make.sh [--stills]
#   1. scratch voice + timing   (build_voice.py, macOS `say`)
#   2. picture                  (promo_video.swift, real riti engine)
#   3. sound: voice + key clicks, loudness-normalised, muxed into the MP4 (mix.py)
# Output: media/promo/avro-next-promo.mp4 and .srt
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="$HOME/.cargo/bin:$PATH"
OUT=media/promo
mkdir -p "$OUT" build/promo

[[ -f riti/target/release/libriti.a ]] || (cd riti && cargo build --release 2>&1 | tail -1)

echo "==> Voice"
python3 Tools/promo/build_voice.py Tools/promo/script.json "$OUT"

echo "==> Compiling the renderer"
cp Tools/promo/promo_video.swift build/promo/main.swift
# Its own Info.plist: the app's version (shown in the Settings shots) and a
# separate bundle id, so rendering never touches the real Avro Next preferences.
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
cat > build/promo/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.avronext.promo-render</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
</dict></plist>
P
swiftc -O -import-objc-header Sources/Bridging-Header.h -Xcc -Iriti/include \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker build/promo/Info.plist \
  Sources/Engine.swift Sources/Settings.swift Sources/KeyMap.swift Sources/CandidateState.swift \
  Sources/SettingsWindow.swift Sources/UpdateCore.swift Sources/UpdateManager.swift \
  build/promo/main.swift riti/target/release/libriti.a \
  -framework Cocoa -framework AVFoundation -framework UserNotifications -o build/promo/promo_video

echo "==> Picture"
STILLS=()
if [[ ${1:-} == --stills ]]; then rm -rf "$OUT/stills"; mkdir -p "$OUT/stills"; STILLS=(--stills "$OUT/stills"); fi
build/promo/promo_video riti/data Tools/promo/script.json "$OUT" "${STILLS[@]}"

echo "==> Sound and mux"
python3 Tools/promo/mix.py Tools/promo/script.json "$OUT"
ls -lh "$OUT/avro-next-promo.mp4"
