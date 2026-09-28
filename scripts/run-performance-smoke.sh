#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="${1:-$TASK_ROOT/verification/local/performance}"
TASK_APP="${3:-$TASK_ROOT/dist/LingoPlayer.app}"
mkdir -p "$TASK_OUTPUT"
TASK_VIDEO="${2:-$TASK_OUTPUT/layout.mp4}"
if [ $# -lt 2 ]; then
  "$TASK_ROOT/.runtime/aligner/bin/ffmpeg" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=960x540:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=44100" -t 30 -c:v mpeg4 -q:v 5 -c:a aac "$TASK_VIDEO"
fi
export LINGOPLAYER_DATA_DIR="$TASK_OUTPUT/state-$(uuidgen)" LINGOPLAYER_RUNTIME="$TASK_ROOT/.runtime"
"${LINGOPLAYER_TEST_BINARY:-$TASK_APP/Contents/MacOS/LingoPlayer}" --performance-test "$TASK_VIDEO" "$TASK_OUTPUT/performance.json"
python3 - "$TASK_OUTPUT/performance.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert [s['name'] for s in r['scenarios']]==['immersive','controls','learning','transcript']
for s in r['scenarios']:
    print(s['name'],round(s['cpu_percent_one_core'],1),'% of one CPU core',s['counts'])
    assert s['rendered_frames']>100, s
    assert not s['paused'] and s['controls_visible']==(s['name']!='immersive'),s
    assert s['highlighted_words']>20 and s['english_count']==5000 and s['word_timing_count']==180,s
    if s['name']=='immersive': assert s['counts'].get('controls_body',0)==0,s
    if s['name']!='transcript': assert s['counts'].get('transcript_native_updates',0)==0,s
PY
