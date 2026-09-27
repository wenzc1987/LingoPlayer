#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="${1:-$TASK_ROOT/verification/local/keyboard}"
TASK_APP="${2:-$TASK_ROOT/dist/LingoPlayer.app}"
TASK_STATE="$TASK_OUTPUT/state-$(uuidgen)"
mkdir -p "$TASK_STATE" "$TASK_OUTPUT/fixtures"
export LINGOPLAYER_DATA_DIR="$TASK_STATE" LINGOPLAYER_RUNTIME="$TASK_ROOT/.runtime"
TASK_VIDEO="$TASK_OUTPUT/fixtures/Keyboard.mp4"
"$TASK_ROOT/.runtime/aligner/bin/ffmpeg" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=44100" -t 30 -c:v mpeg4 -q:v 5 -c:a aac "$TASK_VIDEO"
cat > "$TASK_OUTPUT/fixtures/Keyboard.en.srt" <<'EOF'
1
00:00:00,200 --> 00:00:06,000
First keyboard test sentence.

2
00:00:08,000 --> 00:00:13,000
Second keyboard test sentence.
EOF
"$TASK_APP/Contents/MacOS/LingoPlayer" --keyboard-test "$TASK_VIDEO" "$TASK_OUTPUT"
python3 - "$TASK_OUTPUT/keyboard.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
for check in result['checks']:
    print(('PASS' if check['passed'] else 'FAIL'),check['name'],check['detail'])
sys.exit(0 if result['passed'] else 1)
PY
