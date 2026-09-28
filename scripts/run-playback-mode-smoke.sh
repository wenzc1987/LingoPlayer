#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="${1:-$TASK_ROOT/verification/local/playback-mode-$(uuidgen)}"
if [ -e "$TASK_OUTPUT/playback-mode.json" ]; then echo 'Choose a fresh output directory' >&2; exit 1; fi
mkdir -p "$TASK_OUTPUT/fixtures"
TASK_OUTPUT="$(cd "$TASK_OUTPUT" && pwd)"
export LINGOPLAYER_DATA_DIR="$TASK_OUTPUT/state" LINGOPLAYER_RUNTIME="$TASK_ROOT/.runtime"
TASK_FFMPEG="$TASK_ROOT/.runtime/aligner/bin/ffmpeg"
"$TASK_FFMPEG" -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=960x540:rate=24' -f lavfi -i 'sine=frequency=440:sample_rate=48000' -f lavfi -i 'sine=frequency=660:sample_rate=48000' -map 0:v -map 1:a -map 2:a -t 30 -c:v mpeg4 -q:v 5 -c:a aac -metadata:s:a:0 language=eng -metadata:s:a:1 language=zho -disposition:a:0 0 -disposition:a:1 default "$TASK_OUTPUT/fixtures/Movie.mp4"
"$TASK_FFMPEG" -hide_banner -loglevel error -y -display_rotation 90 -i "$TASK_OUTPUT/fixtures/Movie.mp4" -map 0 -c copy "$TASK_OUTPUT/fixtures/Portrait.mp4"
python3 - "$TASK_OUTPUT/fixtures" <<'PY'
import sys,pathlib
p=pathlib.Path(sys.argv[1])
texts={
'English': 'I thought you were going to tell me what happened yesterday. We should talk about it before we leave the house.',
'French': "Je pensais que tu allais me raconter ce qui s'est passé hier. Nous devrions en parler avant de quitter la maison.",
'Spanish': 'Pensé que me ibas a contar lo que pasó ayer. Deberíamos hablar de ello antes de salir de casa.',
'Japanese': '昨日何が起こったのか教えてくれると思っていました。家を出る前に話しましょう。',
'Chinese': '我以为你会告诉我昨天发生了什么，我们离开房子之前应该谈一谈。',
'Short':'Hello, world!',
'Effects':'[The door slams loudly and footsteps echo down the empty hallway]'}
texts['Bilingual'] = texts['English'] + '\n双语文件默认译文。'
for name,text in texts.items(): (p/(name+'.srt')).write_text('1\n00:00:01,000 --> 00:00:29,000\n'+text+'\n')
(p/'Outside.srt').write_text('1\n10:00:01,000 --> 10:00:29,000\n'+texts['English']+'\n')
(p/'slow-ffmpeg').write_text('#!/usr/bin/python3\nimport time\ntime.sleep(10)\n')
(p/'serial-ffmpeg').write_text('#!/usr/bin/python3\nimport signal,time,pathlib,sys\np=pathlib.Path(__file__).with_name("serial.log")\ndef log(s):\n with p.open("a") as f: f.write(s+"\\n")\ndef stop(*args):\n time.sleep(.12)\n log("end")\n sys.exit(0)\nsignal.signal(signal.SIGTERM,stop)\nlog("start")\ntime.sleep(.4)\nlog("end")\n')
for name in ['slow-ffmpeg','serial-ffmpeg']: (p/name).chmod(0o755)
PY
for TASK_MODE in --playback-mode-test --playback-mode-restore; do
    "${LINGOPLAYER_TEST_BINARY:-$TASK_ROOT/dist/LingoPlayer.app/Contents/MacOS/LingoPlayer}" "$TASK_MODE" "$TASK_OUTPUT/fixtures" "$TASK_OUTPUT"
done
python3 - "$TASK_OUTPUT" <<'PY'
import json,sys,pathlib
rows=[json.loads((pathlib.Path(sys.argv[1])/n).read_text()) for n in ['playback-mode.json','restore.json']]
for r in rows:
 for c in r['checks']: print('PASS' if c['passed'] else 'FAIL',c['name'],c['detail'])
assert all(r['passed'] for r in rows)
PY
