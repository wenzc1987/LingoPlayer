#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="${1:-$TASK_ROOT/verification/local/learning-card-$(uuidgen)}"
if [ -e "$TASK_OUTPUT/learning-card.json" ]; then echo 'Choose a fresh output directory' >&2; exit 1; fi
mkdir -p "$TASK_OUTPUT/fixtures"
TASK_OUTPUT="$(cd "$TASK_OUTPUT" && pwd)"
export LINGOPLAYER_DATA_DIR="$TASK_OUTPUT/state" LINGOPLAYER_RUNTIME="$TASK_ROOT/.runtime"
TASK_VIDEO="$TASK_OUTPUT/fixtures/LearningCard.mp4"
"$TASK_ROOT/.runtime/aligner/bin/ffmpeg" -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=640x360:rate=24' -t 30 -c:v mpeg4 -q:v 5 "$TASK_VIDEO"
cat > "$TASK_OUTPUT/fixtures/LearningCard.en.srt" <<'EOF'
1
00:00:00,200 --> 00:00:14,000
Help, help! Don't stop now.

2
00:00:16,000 --> 00:00:18,000
We should listen carefully and learn English together.
EOF
"$TASK_ROOT/dist/LingoPlayer.app/Contents/MacOS/LingoPlayer" --learning-card-test "$TASK_VIDEO" "$TASK_OUTPUT"
"$TASK_ROOT/dist/LingoPlayer.app/Contents/MacOS/LingoPlayer" --learning-card-restore "$TASK_VIDEO" "$TASK_OUTPUT"
python3 - "$TASK_OUTPUT" <<'PY'
import json,sys
from pathlib import Path
results=[json.loads((Path(sys.argv[1])/name).read_text()) for name in ['learning-card.json','restore.json']]
for result in results:
    for check in result['checks']: print('PASS' if check['passed'] else 'FAIL', check['name'])
assert all(result['passed'] for result in results)
PY
