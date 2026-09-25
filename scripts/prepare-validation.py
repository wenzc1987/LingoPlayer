#!/usr/bin/env python3
"""Make local playback fixtures from a small CC-BY-4.0 LibriSpeech sample.

These are integration fixtures, NOT human-annotated word-boundary ground truth.
Only the beginning of the official streaming archive is downloaded.
"""
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import wave

root = Path(__file__).resolve().parents[1]
out = root / "verification/local"
source_dir = out / "librispeech"
source_dir.mkdir(parents=True, exist_ok=True)
ffmpeg = root / ".runtime/aligner/bin/ffmpeg"
source = "https://www.openslr.org/resources/12/test-clean.tar.gz"
manifest = source_dir / "selected.json"
if manifest.exists():
    selected = json.loads(manifest.read_text())
else:
    audio, transcripts, selected = {}, {}, []
    process = subprocess.Popen(["curl", "-fL", "--silent", "--show-error", "--connect-timeout", "20", "--max-time", "300", source], stdout=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=process.stdout, mode="r|gz") as archive:
            for member in archive:
                if not member.isfile() or member.size > 10_000_000:
                    continue
                name = Path(member.name).name
                if name.endswith(".trans.txt"):
                    for line in archive.extractfile(member).read().decode().splitlines():
                        key, text = line.split(" ", 1)
                        transcripts[key] = text
                elif name.endswith(".flac") and len(audio) < 24:
                    path = source_dir / name
                    path.write_bytes(archive.extractfile(member).read())
                    audio[path.stem] = path.name
                selected = [{"id": key, "file": audio[key], "text": transcripts[key]} for key in sorted(audio) if key in transcripts]
                if sum(len(item["text"].split()) for item in selected) >= 150:
                    break
    finally:
        process.stdout.close()
        if process.poll() is None:
            process.terminate()
        process.wait()
    if not selected:
        raise SystemExit("No matching LibriSpeech samples were retrieved")
    # Bound the fixture to the minimum utterances exceeding 150 reference words.
    total, chosen = 0, []
    for item in selected:
        chosen.append(item); total += len(item["text"].split())
        if total >= 150:
            break
    selected = chosen
    manifest.write_text(json.dumps(selected, indent=2))

def stamp(seconds):
    millis = round(seconds * 1000)
    return "%02d:%02d:%02d,%03d" % (millis // 3600000, millis // 60000 % 60, millis // 1000 % 60, millis % 1000)

position, cues, subtitles = 0.0, [], []
audio_path = out / "clear.wav"
with wave.open(str(audio_path), "wb") as joined:
    joined.setnchannels(1); joined.setsampwidth(2); joined.setframerate(16000)
    for index, item in enumerate(selected):
        wav = source_dir / (item["id"] + ".wav")
        subprocess.run([str(ffmpeg), "-nostdin", "-v", "error", "-y", "-i", str(source_dir / item["file"]), "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(wav)], check=True)
        with wave.open(str(wav), "rb") as recording:
            frames = recording.readframes(recording.getnframes())
            duration = recording.getnframes() / recording.getframerate()
        joined.writeframes(frames)
        text = item["text"].capitalize()
        tokens = []
        for token_index, match in enumerate(re.finditer(r"[A-Za-z]+(?:['’\-][A-Za-z]+)*|[^A-Za-z]+", text)):
            if match.group()[0].isalpha():
                tokens.append({"id": token_index, "text": match.group(), "isWord": True})
        cues.append({"id": "cue-%d-en" % index, "start": position, "end": position + duration, "tokens": tokens})
        subtitles.append("%d\n%s --> %s\n%s\n" % (index + 1, stamp(position), stamp(position + duration), text))
        position += duration
        joined.writeframes(b"\0\0" * 8000)
        position += 0.5
(out / "clear.en.srt").write_text("\n".join(subtitles), encoding="utf-8")
translations = [
    "营帐间又恢复了和睦。",
    "英国人把花篮送给法国人；他们为迎接年轻公主准备了许多鲜花。作为回礼，法国人邀请英国人参加第二天的晚宴。",
    "公主一路所到之处，都收到人们的祝贺。",
    "众人的尊敬让她如同女王，少数人的倾慕更使她如同受人崇拜的对象。王太后热情接待法国人。法国是她的故乡，在英国经历的苦难不足以让她忘记法国。",
    "她以自己对法国的感情，教女儿热爱这个曾热情接待她们、也为她们展开光明前途的国家。",
]
chinese, ass = [], ["[Events]", "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"]
for index, cue in enumerate(cues):
    translation = translations[index]
    # Deliberately offset this independently timed translation to exercise
    # language timelines instead of pairing subtitle rows by their indices.
    start, end = cue["start"] + 0.2, cue["end"] + 0.2
    chinese.append("%d\n%s --> %s\n%s\n" % (index + 1, stamp(start), stamp(end), translation))
    ass_time = lambda value: stamp(value).replace(",", ".")[:-1]
    english_text = " ".join(t["text"] for t in cue["tokens"])
    ass.append("Dialogue: 0,%s,%s,Default,,0,0,0,,%s\\N%s" % (ass_time(cue["start"]), ass_time(cue["end"]), english_text, translation))
(out / "clear.zh.srt").write_text("\n".join(chinese), encoding="utf-8")
(out / "manual-bilingual.ass").write_text("\n".join(ass), encoding="utf-8")
subprocess.run([str(ffmpeg), "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=960x540:rate=24", "-i", str(audio_path), "-c:v", "mpeg4", "-q:v", "8", "-c:a", "aac", "-shortest", str(out / "clear.mp4")], check=True)
subprocess.run([str(ffmpeg), "-nostdin", "-v", "error", "-y", "-i", str(out / "clear.mp4"), "-i", str(out / "clear.en.srt"), "-i", str(out / "clear.zh.srt"), "-map", "0:v", "-map", "0:a", "-map", "0:a", "-map", "1", "-map", "2", "-c", "copy", "-c:s", "srt", "-metadata:s:s:0", "language=eng", "-metadata:s:s:1", "language=zho", "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "title=Second audio validation track", str(out / "embedded.mkv")], check=True)
shutil.copyfile(out / "clear.mp4", out / "no-subtitles.mp4")
model_root = Path.home() / "Library/Application Support/LingoPlayer/MFA"
job = {"video": str(out / "clear.mp4"), "stream": 1, "ffmpeg": str(ffmpeg), "mfa": str(root / ".runtime/aligner/bin/mfa"), "acousticModel": "english_mfa", "pronunciationDictionary": "english_us_mfa", "modelRoot": str(model_root), "cues": cues}
(out / "clear-request.json").write_text(json.dumps(job, indent=2))
(out / "provenance.json").write_text(json.dumps({"source": source, "dataset": "LibriSpeech test-clean / OpenSLR 12", "license": "CC BY 4.0", "authors": "Vassil Panayotov, Guoguo Chen, Daniel Povey, Sanjeev Khudanpur", "selected_utterances": [x["id"] for x in selected], "reference_words": sum(len(x["tokens"]) for x in cues), "duration_seconds": position, "note": "Real audiobook audio and reference transcripts, with synthetic test-pattern video. No human word-level timestamps; this fixture cannot establish the ±200 ms acceptance criterion."}, indent=2))
print(json.dumps({"video": str(out / "clear.mp4"), "duration": position, "words": sum(len(c["tokens"]) for c in cues)}, indent=2))
