#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="${1:-$TASK_ROOT/verification/local/window-geometry}"
mkdir -p "$TASK_OUTPUT/fixtures"
TASK_FIXTURES="$(cd "$TASK_OUTPUT/fixtures" && pwd)"
export LINGOPLAYER_DATA_DIR="$TASK_FIXTURES/state-$(uuidgen)" LINGOPLAYER_RUNTIME="$TASK_ROOT/.runtime"
TASK_FFMPEG="$TASK_ROOT/.runtime/aligner/bin/ffmpeg"
"$TASK_FFMPEG" -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=960x540:rate=30' -t 30 -c:v mpeg4 -q:v 7 "$TASK_FIXTURES/Wide.mp4"
"$TASK_FFMPEG" -hide_banner -loglevel error -y -display_rotation 90 -i "$TASK_FIXTURES/Wide.mp4" -c copy "$TASK_FIXTURES/Portrait.mp4"
"$TASK_FFMPEG" -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=640x360:rate=30' -vf setsar=2/1 -t 30 -c:v mpeg4 -q:v 7 "$TASK_FIXTURES/Anamorphic.mp4"
for TASK_MODE in --window-geometry-test --window-geometry-restore; do
    "$TASK_ROOT/dist/LingoPlayer.app/Contents/MacOS/LingoPlayer" "$TASK_MODE" "$TASK_FIXTURES" "$TASK_OUTPUT"
done
python3 - "$TASK_OUTPUT" <<'PY'
import json,sys,pathlib
rows=[json.loads((pathlib.Path(sys.argv[1])/n).read_text()) for n in ['window.json','window-restore.json']]
for r in rows:
    for c in r['checks']: print('PASS' if c['passed'] else 'FAIL',c['name'],c['detail'])
assert all(r['passed'] for r in rows)
PY
