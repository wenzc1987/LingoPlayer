#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="${1:-$TASK_ROOT/verification/local/v03-practice}"
TASK_FIXTURES="$TASK_OUTPUT/fixtures"
TASK_STATE="$TASK_OUTPUT/state-$(uuidgen)"
mkdir -p "$TASK_FIXTURES" "$TASK_STATE"
export LINGOPLAYER_DATA_DIR="$TASK_STATE"
export LINGOPLAYER_RUNTIME="$TASK_ROOT/.runtime"
TASK_FFMPEG="$TASK_ROOT/.runtime/aligner/bin/ffmpeg"
"$TASK_FFMPEG" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=44100" -t 8 -c:v mpeg4 -q:v 5 -c:a aac "$TASK_FIXTURES/Practice1.mp4"
cp "$TASK_FIXTURES/Practice1.mp4" "$TASK_FIXTURES/Practice2.mp4"
python3 - "$TASK_FIXTURES" "$TASK_STATE" <<'PY'
import json,sys
from pathlib import Path
folder,state=map(Path,sys.argv[1:])
folder.joinpath('Practice1.en.srt').write_text('1\n00:00:00,200 --> 00:00:01,000\nFirst [sentence].\n\n2\n00:00:02,000 --> 00:00:03,000\nAnother sentence.\n\n3\n00:00:07,600 --> 00:00:09,000\nFinal word.\n')
folder.joinpath('Practice1.zh.srt').write_text('1\n00:00:00,300 --> 00:00:02,500\n跨两句的中文。\n\n2\n00:00:04,000 --> 00:00:05,000\n独立中文。\n\n3\n00:00:07,700 --> 00:00:09,000\n最后一句。\n')
folder.joinpath('Practice2.en.srt').write_text('1\n00:00:00,200 --> 00:00:02,000\nDifferent movie.\n')
folder.joinpath('replacement.srt').write_text('1\n00:00:00,500 --> 00:00:01,500\nReplacement text.\n替换字幕。\n')
# An actual v0.2 file: old custom actions occupy both new defaults.
state.joinpath('interaction.json').write_text(json.dumps({'autoplay':True,'bindings':{'playPause':{'keyCode':15,'key':'r','modifiers':9},'forward':{'keyCode':11,'key':'b','modifiers':1}},'disabled':[]}))
PY
"$TASK_ROOT/dist/LingoPlayer.app/Contents/MacOS/LingoPlayer" --practice-test "$TASK_FIXTURES" "$TASK_OUTPUT"
"$TASK_ROOT/dist/LingoPlayer.app/Contents/MacOS/LingoPlayer" --practice-restore "$TASK_FIXTURES" "$TASK_OUTPUT"
python3 - "$TASK_OUTPUT" <<'PY'
import json,sys
from pathlib import Path
results=[json.loads((Path(sys.argv[1])/name).read_text()) for name in ['practice.json','practice-restore.json']]
print(json.dumps(results,ensure_ascii=False,indent=2))
sys.exit(0 if all(r['passed'] for r in results) else 1)
PY
