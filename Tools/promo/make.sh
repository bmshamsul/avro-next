#!/bin/zsh
# Builds the Avro Next promo film:  Tools/promo/make.sh [--bn] [--stills]
#   1. voice + timing           (build_voice.py: macOS `say`, or edge-tts for --bn)
#   2. picture                  (promo_video.swift, real riti engine)
#   3. sound: voice + key clicks, loudness-normalised, muxed into the MP4 (mix.py)
# Output: media/promo/avro-next-promo.mp4 and .srt (English)
#         media/promo-bn/avro-next-promo.mp4 and .srt (Bangla, --bn)
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="$HOME/.cargo/bin:$PATH"
SCRIPT=Tools/promo/script.json OUT=media/promo WANT_STILLS=0
for a in "$@"; do
  case $a in
    --bn) SCRIPT=Tools/promo/script.bn.json OUT=media/promo-bn ;;
    --stills) WANT_STILLS=1 ;;
    *) echo "unknown option $a"; exit 2 ;;
  esac
done
mkdir -p "$OUT" build/promo

# Bangla narration uses Microsoft's neural bn-BD voices through edge-tts (needs internet;
# the narration text is sent to Microsoft). Installed into a local venv, not system Python.
EDGE=build/promo/venv/bin/edge-tts
if [[ $SCRIPT == *.bn.json && ! -x $EDGE ]]; then
  python3 -m venv build/promo/venv && build/promo/venv/bin/pip install -q edge-tts
fi

[[ -f riti/target/release/libriti.a ]] || (cd riti && cargo build --release 2>&1 | tail -1)

echo "==> Voice"
python3 Tools/promo/build_voice.py "$SCRIPT" "$OUT" --edge-tts "$EDGE"

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
if (( WANT_STILLS )); then rm -rf "$OUT/stills"; mkdir -p "$OUT/stills"; STILLS=(--stills "$OUT/stills"); fi
build/promo/promo_video riti/data "$SCRIPT" "$OUT" "${STILLS[@]}"

echo "==> Sound and mux"
python3 Tools/promo/mix.py "$SCRIPT" "$OUT"
ls -lh "$OUT/avro-next-promo.mp4"
