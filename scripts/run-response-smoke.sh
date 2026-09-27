#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_REQUEST="${1:?Provide local JSON with video, subtitle, position}"
TASK_OUTPUT="${2:?Provide output directory}"
TASK_APP="${3:-$TASK_ROOT/dist/LingoPlayer.app}"
TASK_STATE="$TASK_OUTPUT/state-$(uuidgen)"
mkdir -p "$TASK_STATE/MFA"
ln -s "$HOME/Library/Application Support/LingoPlayer/MFA/pretrained_models" "$TASK_STATE/MFA/pretrained_models"
export LINGOPLAYER_DATA_DIR="$TASK_STATE" LINGOPLAYER_RUNTIME="$TASK_ROOT/.runtime"
"$TASK_APP/Contents/MacOS/LingoPlayer" --response-test "$TASK_REQUEST" "$TASK_OUTPUT/response.json"
python3 - "$TASK_OUTPUT/response.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
passed=len(r['scenarios'])==6
for s in r['scenarios']:
 f=s['feedback_ms']; p=s['pause_confirmation_ms']
 if r.get('input')=='native-mouse-button':
  pattern=['forward','backward','toggleSidebarVisibility','toggleSidebarVisibility'] if s['state']=='paused' else ['playPause','playPause','forward','backward','toggleSidebarVisibility','toggleSidebarVisibility']
 else:
  pattern=['volumeUp','volumeDown','toggleSidebar','cycleSubtitleDisplay'] if s['state']=='paused' else ['playPause','playPause','toggleSidebar','cycleSubtitleDisplay','forward','backward']
 expected_pause=sum(o['action']=='playPause' for o in s['operations'])
 valid=len(s['operations'])>=50 and f.get('count',0)==len(s['operations']) and all(o['action']==pattern[i%len(pattern)] for i,o in enumerate(s['operations'])) and p.get('count',0)==expected_pause
 meets=valid and f['p95']<=100 and f['max']<=250 and (not p or p['p95']<=250)
 passed &= meets
 print(s['subtitles'],s['state'],'feedback',f,'pause',p,'pass',meets)
sys.exit(0 if passed else 1)
PY
