#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_FIXTURES="${1:?Provide practice fixture directory}"
TASK_OUTPUT="${2:?Provide output directory}"
TASK_STATE="$TASK_OUTPUT/state-$(uuidgen)"
mkdir -p "$TASK_STATE/MFA"
ln -s "$HOME/Library/Application Support/LingoPlayer/MFA/pretrained_models" "$TASK_STATE/MFA/pretrained_models"
export LINGOPLAYER_DATA_DIR="$TASK_STATE" LINGOPLAYER_RUNTIME="$TASK_ROOT/.runtime"
"$TASK_ROOT/dist/LingoPlayer.app/Contents/MacOS/LingoPlayer" --display-test "$TASK_FIXTURES" "$TASK_OUTPUT"
"$TASK_ROOT/dist/LingoPlayer.app/Contents/MacOS/LingoPlayer" --display-restore "$TASK_FIXTURES" "$TASK_OUTPUT"
python3 - "$TASK_OUTPUT" <<'PY'
import json,sys
from pathlib import Path
results=[json.loads((Path(sys.argv[1])/name).read_text()) for name in ['display.json','display-restore.json']]
print(json.dumps(results,ensure_ascii=False,indent=2))
sys.exit(0 if all(r['passed'] for r in results) else 1)
PY
