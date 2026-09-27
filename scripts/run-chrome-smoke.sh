#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="${1:-$TASK_ROOT/verification/local/chrome}"
TASK_STATE="$TASK_OUTPUT/state-$(uuidgen)"
mkdir -p "$TASK_STATE" "$TASK_OUTPUT/fixtures"
export LINGOPLAYER_DATA_DIR="$TASK_STATE" LINGOPLAYER_RUNTIME="$TASK_ROOT/.runtime"
TASK_VIDEO="${2:-$TASK_OUTPUT/fixtures/Layout.mp4}"
if [ $# -lt 2 ]; then
  "$TASK_ROOT/.runtime/aligner/bin/ffmpeg" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=960x540:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=44100" -t 30 -c:v mpeg4 -q:v 5 -c:a aac "$TASK_VIDEO"
  cat > "$TASK_OUTPUT/fixtures/Layout.en.srt" <<'EOF'
1
00:00:00,500 --> 00:00:28,000
Why don't we have a seat and talk it over.
EOF
  cat > "$TASK_OUTPUT/fixtures/Layout.zh.srt" <<'EOF'
1
00:00:00,500 --> 00:00:28,000
咱们坐下谈吧。
EOF
fi
"$TASK_ROOT/dist/LingoPlayer.app/Contents/MacOS/LingoPlayer" --chrome-test "$TASK_VIDEO" "$TASK_OUTPUT"
python3 - "$TASK_OUTPUT/chrome.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
for check in result['checks']:
    print(('PASS' if check['passed'] else 'FAIL'),check['name'],check['detail'])
sys.exit(0 if result['passed'] else 1)
PY
