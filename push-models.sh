#!/usr/bin/env bash
# Install ASR models onto a phone over USB. This is the zero-network path: the phone never
# opens a socket, we only need the PC to have the files.
set -euo pipefail
ADB="${ADB:-/d/android-sdk/platform-tools/adb.exe}"
SRC="${1:-/d/dayly/models/asr-zipformer-bilingual-int8}"
PKG="com.qoder.si"
DEST="/storage/emulated/0/Android/data/$PKG/files/models/asr-zipformer-bilingual-int8"

command -v "$ADB" >/dev/null || { echo "adb not found at $ADB"; exit 1; }
"$ADB" wait-for-device
# the app-private dir on external storage may not exist until first launch
"$ADB" shell mkdir -p "$DEST" || true

for f in encoder.onnx decoder.onnx joiner.onnx tokens.txt; do
  [ -f "$SRC/$f" ] || { echo "missing $SRC/$f"; exit 1; }
  echo "pushing $f ..."
  "$ADB" push "$SRC/$f" "$DEST/$f"
done

# trigger a media rescan so the file is immediately visible to the app
"$ADB" shell "cmd mount remount" 2>/dev/null || true
"$ADB" shell "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_DIR -d file:///storage/emulated/0/Android/data/$PKG/files" 2>/dev/null || true
echo
echo "done. 在 App 里点「推完后重新扫描」"
