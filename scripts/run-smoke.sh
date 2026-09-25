#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_VIDEO="${1:?Provide an absolute validation video path}"
TASK_OUTPUT="${2:?Provide an absolute output directory}"
TASK_MODELS="${LINGOPLAYER_DATA_DIR:-$HOME/Library/Application Support/LingoPlayer}/MFA/pretrained_models"
TASK_STATE="$TASK_OUTPUT/state-$(uuidgen)"
mkdir -p "$TASK_STATE/MFA"
ln -s "$TASK_MODELS" "$TASK_STATE/MFA/pretrained_models"
export LINGOPLAYER_DATA_DIR="$TASK_STATE"
export LINGOPLAYER_RUNTIME="$TASK_ROOT/.runtime"
"$TASK_ROOT/dist/LingoPlayer.app/Contents/MacOS/LingoPlayer" --self-test "$TASK_VIDEO" "$TASK_OUTPUT"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(json.dumps(r,ensure_ascii=False,indent=2)); sys.exit(0 if r["passed"] else 1)' "$TASK_OUTPUT/smoke.json"
