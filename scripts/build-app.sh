#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
TASK_CONFIGURATION="${1:-release}"
swift build -c "$TASK_CONFIGURATION"
TASK_BIN="$(swift build -c "$TASK_CONFIGURATION" --show-bin-path)"
TASK_APP="$TASK_ROOT/dist/LingoPlayer.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources" "$TASK_APP/Contents/Frameworks"
cp "$TASK_BIN/LingoPlayer" "$TASK_APP/Contents/MacOS/LingoPlayer.next"
mv -f "$TASK_APP/Contents/MacOS/LingoPlayer.next" "$TASK_APP/Contents/MacOS/LingoPlayer"
if [ -d "$TASK_BIN/LingoPlayer_LingoPlayer.bundle" ]; then
  ditto "$TASK_BIN/LingoPlayer_LingoPlayer.bundle" "$TASK_APP/Contents/Resources/LingoPlayer_LingoPlayer.bundle"
fi
if [ -d "$TASK_ROOT/.runtime/lib" ]; then
  for TASK_LIB in "$TASK_ROOT/.runtime/lib/"*.dylib; do
    [ -e "$TASK_LIB" ] || continue
    TASK_DEST="$TASK_APP/Contents/Frameworks/$(basename "$TASK_LIB")"
    if ! cmp -s "$TASK_LIB" "$TASK_DEST"; then
      cp "$TASK_LIB" "$TASK_DEST.next"
      mv -f "$TASK_DEST.next" "$TASK_DEST"
    fi
  done
fi
cp "$TASK_ROOT/Sources/LingoPlayer/Resources/Icon/AppIcon.icns" "$TASK_APP/Contents/Resources/AppIcon.icns"
python3 "$TASK_ROOT/scripts/write-app-info.py" "$TASK_APP" "$TASK_ROOT/.runtime"
codesign --force --deep --sign - "$TASK_APP"
echo "Built $TASK_APP"
