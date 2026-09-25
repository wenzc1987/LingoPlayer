#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="${1:-$TASK_ROOT/verification/local/v02}"
TASK_FIXTURES="$TASK_OUTPUT/fixtures"
TASK_STATE="$TASK_OUTPUT/state-$(uuidgen)"
mkdir -p "$TASK_FIXTURES" "$TASK_STATE"
export LINGOPLAYER_DATA_DIR="$TASK_STATE"
export LINGOPLAYER_RUNTIME="$TASK_ROOT/.runtime"
TASK_FFMPEG="$TASK_ROOT/.runtime/aligner/bin/ffmpeg"
for TASK_EPISODE in 1 2 10; do
  "$TASK_FFMPEG" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=44100" -t 4 -c:v mpeg4 -q:v 5 -c:a aac "$TASK_FIXTURES/Episode$TASK_EPISODE.mp4"
done
python3 - "$TASK_FIXTURES" <<'PY'
import sys
from pathlib import Path
folder=Path(sys.argv[1])
for number,text in [(1,'First episode.'),(2,'Second episode.'),(10,'Last episode.')]:
    (folder/f'Episode{number}.en.srt').write_text(f'1\n00:00:00,200 --> 00:00:01,000\n{text}\n\n2\n00:00:02,000 --> 00:00:03,800\nAnother sentence.\n')
(folder/'Episode3.mp4').write_text('Intentional invalid media for error recovery test.')
PY
"$TASK_ROOT/dist/LingoPlayer.app/Contents/MacOS/LingoPlayer" --interaction-test "$TASK_FIXTURES" "$TASK_OUTPUT"
"$TASK_ROOT/dist/LingoPlayer.app/Contents/MacOS/LingoPlayer" --interaction-restore "$TASK_FIXTURES" "$TASK_OUTPUT"
python3 - "$TASK_OUTPUT" <<'PY'
import json,sys
from pathlib import Path
results=[json.loads((Path(sys.argv[1])/name).read_text()) for name in ['interaction.json','restore.json']]
print(json.dumps(results,ensure_ascii=False,indent=2))
sys.exit(0 if all(r['passed'] for r in results) else 1)
PY
