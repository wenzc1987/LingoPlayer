#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="${1:-$TASK_ROOT/verification/local/toolbar-$(uuidgen)}"
if [ -e "$TASK_OUTPUT/toolbar.json" ] || [ -e "$TASK_OUTPUT/saved" ]; then
    echo "Choose a fresh output directory; prior screenshot test files are preserved." >&2
    exit 1
fi
mkdir -p "$TASK_OUTPUT/fixtures"
TASK_OUTPUT="$(cd "$TASK_OUTPUT" && pwd)"
export LINGOPLAYER_DATA_DIR="$TASK_OUTPUT/state-$(uuidgen)" LINGOPLAYER_RUNTIME="$TASK_ROOT/.runtime"
TASK_VIDEO="$TASK_OUTPUT/fixtures/Toolbar.mp4"
TASK_FFMPEG="$TASK_ROOT/.runtime/aligner/bin/ffmpeg"
"$TASK_FFMPEG" -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=960x540:rate=24' -t 30 -c:v mpeg4 -q:v 5 "$TASK_VIDEO"
"$TASK_FFMPEG" -hide_banner -loglevel error -y -display_rotation 90 -i "$TASK_VIDEO" -c copy "$TASK_OUTPUT/fixtures/Portrait.mp4"
cat > "$TASK_OUTPUT/fixtures/Toolbar.en.srt" <<'EOF'
1
00:00:00,100 --> 00:00:29,000
Why don't we have a seat and talk it over.
EOF
cat > "$TASK_OUTPUT/fixtures/Toolbar.zh.srt" <<'EOF'
1
00:00:00,100 --> 00:00:29,000
咱们坐下谈吧。
EOF
for TASK_MODE in --toolbar-test --toolbar-restore; do
    "$TASK_ROOT/dist/LingoPlayer.app/Contents/MacOS/LingoPlayer" "$TASK_MODE" "$TASK_VIDEO" "$TASK_OUTPUT"
done
python3 - "$TASK_OUTPUT" <<'PY'
import json,sys,pathlib
rows=[json.loads((pathlib.Path(sys.argv[1])/n).read_text()) for n in ['toolbar.json','toolbar-restore.json']]
for r in rows:
    for c in r['checks']: print('PASS' if c['passed'] else 'FAIL',c['name'],c['detail'])
assert all(r['passed'] for r in rows)
PY
