#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="${1:-$TASK_ROOT/verification/local/ui-performance}"
TASK_APP="${2:-$TASK_ROOT/dist/LingoPlayer.app}"
TASK_FIXTURES="$TASK_ROOT/verification/local/ui-performance-fixtures"
mkdir -p "$TASK_OUTPUT" "$TASK_FIXTURES"
TASK_VIDEO="${3:-$TASK_FIXTURES/Interaction.mp4}"
if [ $# -lt 3 ] && [ ! -f "$TASK_VIDEO" ]; then
  "$TASK_ROOT/.runtime/aligner/bin/ffmpeg" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=30" -t 60 -c:v mpeg4 -q:v 7 "$TASK_VIDEO"
  cat > "$TASK_FIXTURES/Interaction.en.srt" <<'EOF'
1
00:00:00,100 --> 00:00:59,900
We can listen again and learn something new together.
EOF
  cat > "$TASK_FIXTURES/Interaction.zh.srt" <<'EOF'
1
00:00:00,100 --> 00:00:59,900
我们可以再听一遍，一起学习新的内容。
EOF
fi
test -f "$TASK_VIDEO"
export LINGOPLAYER_DATA_DIR="$TASK_OUTPUT/state-$(uuidgen)" LINGOPLAYER_RUNTIME="$TASK_ROOT/.runtime"
"$TASK_APP/Contents/MacOS/LingoPlayer" --ui-performance-test "$TASK_VIDEO" "$TASK_OUTPUT"
python3 - "$TASK_OUTPUT/ui-performance.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
for name,passed in r['checks'].items(): print('PASS' if passed else 'FAIL',name)
for scenario in r['scenarios']: print(scenario)
assert r['passed'], r['checks']
PY
