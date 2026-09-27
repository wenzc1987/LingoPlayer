#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="${1:-$TASK_ROOT/verification/local/viewing}"
TASK_STATE="$TASK_OUTPUT/state-$(uuidgen)"
mkdir -p "$TASK_STATE" "$TASK_OUTPUT/fixtures"
export LINGOPLAYER_DATA_DIR="$TASK_STATE" LINGOPLAYER_RUNTIME="$TASK_ROOT/.runtime"
TASK_VIDEO="$TASK_OUTPUT/fixtures/Viewing.mp4"
"$TASK_ROOT/.runtime/aligner/bin/ffmpeg" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=960x540:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=44100" -t 15 -c:v mpeg4 -q:v 5 -c:a aac "$TASK_VIDEO"
cat > "$TASK_OUTPUT/fixtures/Viewing.en.srt" <<'EOF'
1
00:00:00,100 --> 00:00:14,000
Why don't we have a seat and talk it over.
EOF
cat > "$TASK_OUTPUT/fixtures/Viewing.zh.srt" <<'EOF'
1
00:00:00,100 --> 00:00:14,000
咱们坐下谈吧。
EOF
"$TASK_ROOT/dist/LingoPlayer.app/Contents/MacOS/LingoPlayer" --viewing-test "$TASK_VIDEO" "$TASK_OUTPUT"
"$TASK_ROOT/dist/LingoPlayer.app/Contents/MacOS/LingoPlayer" --viewing-restore "$TASK_VIDEO" "$TASK_OUTPUT"
python3 - "$TASK_OUTPUT" <<'PY'
import json,sys
from pathlib import Path
results=[json.loads((Path(sys.argv[1])/name).read_text()) for name in ['viewing.json','viewing-restore.json']]
for result in results:
    for check in result['checks']:
        print(('PASS' if check['passed'] else 'FAIL'),check['name'],check['detail'])
sys.exit(0 if all(r['passed'] for r in results) else 1)
PY
