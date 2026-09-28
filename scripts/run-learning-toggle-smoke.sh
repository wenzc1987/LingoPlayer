#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="${1:-$TASK_ROOT/verification/local/learning-toggle-$(uuidgen)}"
if [ -e "$TASK_OUTPUT/learning-toggle.json" ]; then echo 'Choose a fresh output directory' >&2; exit 1; fi
mkdir -p "$TASK_OUTPUT/fixtures"
TASK_OUTPUT="$(cd "$TASK_OUTPUT" && pwd)"
export LINGOPLAYER_DATA_DIR="$TASK_OUTPUT/state" LINGOPLAYER_RUNTIME="$TASK_ROOT/.runtime"
"$TASK_ROOT/.runtime/aligner/bin/ffmpeg" -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=960x540:rate=24' -t 30 -c:v mpeg4 -q:v 5 "$TASK_OUTPUT/fixtures/Movie.mp4"
python3 - "$TASK_OUTPUT/fixtures" <<'PY'
import pathlib,shutil,sys
p=pathlib.Path(sys.argv[1])
shutil.copyfile(p/'Movie.mp4',p/'A Very Long Movie Title About Learning English While Exploring The World With Friends And Finding New Stories Every Day.mp4')
texts={'English':'I thought you were going to tell me what happened yesterday. We should talk about it before we leave the house.',
       'Japanese':'昨日何が起こったのか教えてくれると思っていました。家を出る前に話しましょう。'}
for name,text in texts.items(): (p/(name+'.srt')).write_text('1\n00:00:01,000 --> 00:00:29,000\n'+text+'\n')
PY
"$TASK_ROOT/dist/LingoPlayer.app/Contents/MacOS/LingoPlayer" --learning-toggle-test "$TASK_OUTPUT/fixtures" "$TASK_OUTPUT"
python3 - "$TASK_OUTPUT/learning-toggle.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
for c in r['checks']: print('PASS' if c['passed'] else 'FAIL',c['name'],c['detail'])
assert r['passed']
PY
