#!/usr/bin/env python3
"""Local-only MFA adapter. No fabricated timestamps and no network transcription.

Input: AlignmentJob JSON. Output: AlignmentResult JSON with absolute media times.
MFA models must be installed beforehand by scripts/setup-runtime.sh.
"""
import argparse
import contextlib
import json
import os
from pathlib import Path
import re
import resource
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import wave

WORKER_VERSION = 2
STAGE = "prepare"


def normalize(word):
    return re.sub(r"[^a-z]", "", word.lower())


def map_words(cue, entries, audio_start):
    """Only merge real aligned spans. Never interpolate or split a model span."""
    entries = [e for e in entries if len(e) >= 3 and str(e[2]).strip() not in ("", "sil", "sp", "<eps>")]
    result, cursor = [], 0
    for token in cue["tokens"]:
        expected = normalize(token["text"])
        if not expected:
            continue
        combined, selected = "", []
        while cursor < len(entries) and len(combined) < len(expected):
            entry = entries[cursor]
            if entry[2] in ("<unk>", "spn", "<oov>"):
                raise ValueError("出现未识别词，保留整句字幕")
            combined += normalize(str(entry[2]))
            selected.append(entry)
            cursor += 1
        if combined != expected or not selected:
            raise ValueError("对齐输出与字幕单词不一致")
        start, end = float(selected[0][0]) + audio_start, float(selected[-1][1]) + audio_start
        if end <= start or start < audio_start - 0.01 or end > cue["end"] + 0.35:
            raise ValueError("单词时间范围无效")
        result.append({"cueID": cue["id"], "tokenIndex": token["id"], "start": max(0.0, start), "end": end})
    if cursor != len(entries):
        raise ValueError("对齐输出包含额外单词")
    return result


def read_entries(path):
    data = json.loads(path.read_text())
    tiers = data.get("tiers", {})
    if isinstance(tiers, dict):
        candidates = [(name, tier) for name, tier in tiers.items() if name.lower().endswith("words")]
        if candidates:
            return candidates[0][1].get("entries", [])
    raise ValueError("MFA 未返回单词时间层")


def prepare_dictionary(job, working):
    source = Path(job["pronunciationDictionary"])
    if not source.is_file():
        source = Path(job["modelRoot"]) / "pretrained_models/dictionary" / (job["pronunciationDictionary"] + ".dict")
    if not source.is_file():
        raise RuntimeError("英文发音词典未安装，请运行 scripts/setup-runtime.sh --alignment")
    needed = {"<unk>", "<eps>", "<bracketed>", "<cutoff>"}
    for cue in job["cues"]:
        for token in cue["tokens"]:
            word = token["text"].lower().replace("’", "'")
            needed.add(word)
            needed.update(re.split(r"[-']", word))
    # MFA imports its lexicon into a per-job DB. A pronunciation-preserving
    # subset avoids importing the full language dictionary for every small chunk.
    target = working / "english_subset.dict"
    count = 0
    with source.open(encoding="utf-8") as original, target.open("w", encoding="utf-8") as subset:
        for line in original:
            parts = line.split(maxsplit=1)
            if parts and parts[0].lower() in needed:
                subset.write(line); count += 1
    if not count:
        raise RuntimeError("本段单词在发音词典中均未找到")
    return target


def run_job(job, working):
    global STAGE
    STAGE = "ffmpeg"
    started = time.monotonic()
    corpus, aligned = working / "corpus", working / "aligned"
    corpus.mkdir(); aligned.mkdir()
    cues = job["cues"]
    if not cues:
        return {"words": [], "completed": [], "failures": {}, "elapsed": 0, "peakMemoryMB": 0}
    segment_start = max(0.0, min(c["start"] for c in cues) - 0.2)
    segment_end = max(c["end"] for c in cues) + 0.2
    audio = working / "segment.wav"
    subprocess.run([job["ffmpeg"], "-nostdin", "-v", "error", "-y", "-ss", str(segment_start), "-i", job["video"], "-t", str(segment_end - segment_start), "-map", "0:" + str(job["stream"]), "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(audio)], check=True)
    windows, failures = {}, {}
    with wave.open(str(audio), "rb") as source:
        rate, frames = source.getframerate(), source.getnframes()
        for index, cue in enumerate(cues):
            label = "cue_%05d" % index
            start = max(segment_start, cue["start"] - 0.15)
            end = min(segment_end, cue["end"] + 0.15)
            start_frame = min(frames, max(0, round((start - segment_start) * rate)))
            count = min(frames - start_frame, max(0, round((end - start) * rate)))
            if count < 160 or not cue["tokens"] or cue["end"] <= cue["start"]:
                failures[cue["id"]] = "本句没有有效音频或可对齐单词"
                continue
            source.setpos(start_frame)
            with wave.open(str(corpus / (label + ".wav")), "wb") as target:
                target.setnchannels(1); target.setsampwidth(2); target.setframerate(rate)
                target.writeframes(source.readframes(count))
            transcript = " ".join(token["text"].replace("’", "'") for token in cue["tokens"])
            (corpus / (label + ".lab")).write_text(transcript, encoding="utf-8")
            windows[cue["id"]] = (label, start_frame / rate + segment_start)
    if not windows:
        return {"words": [], "completed": [c["id"] for c in cues], "failures": failures, "elapsed": time.monotonic() - started, "peakMemoryMB": 0}
    STAGE = "dictionary"
    environment = os.environ.copy()
    environment["PATH"] = str(Path(job["mfa"]).parent) + os.pathsep + environment.get("PATH", "")
    environment["MFA_ROOT_DIR"] = job["modelRoot"]
    dictionary = prepare_dictionary(job, working)
    STAGE = "mfa"
    command = [job["mfa"], "align", str(corpus), str(dictionary), job["acousticModel"], str(aligned), "--output_format", "json", "--single_speaker", "--no_use_mp", "--num_jobs", "1", "--clean", "--temporary_directory", str(working / "mfa-temp")]
    # File output bounds memory and avoids pipe deadlocks. stderr remains diagnostic.
    with (working / "mfa.log").open("w") as log:
        process = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, env=environment)
    if process.returncode:
        log = (working / "mfa.log").read_text(errors="replace")
        # A corpus with no alignable speech is a content failure. Configuration,
        # database and model exceptions still stop the worker for explicit retry.
        if "NoAlignmentsError" not in log and "No utterances" not in log and "No files were found" not in log:
            raise RuntimeError("MFA 非零退出（%s），详见本地日志。\n%s" % (process.returncode, log))
        for cue in cues:
            failures.setdefault(cue["id"], "MFA 未找到可对齐的语音，保留整句")
    STAGE = "word-mapping"
    words = []
    for cue in cues:
        if cue["id"] in failures:
            continue
        label, audio_start = windows[cue["id"]]
        files = list(aligned.rglob(label + ".json"))
        try:
            if not files:
                raise ValueError("本句未生成对齐结果")
            words.extend(map_words(cue, read_entries(files[0]), audio_start))
        except (ValueError, KeyError, TypeError) as error:
            failures[cue["id"]] = str(error)
    memory = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    divisor = 1024 * 1024 if sys.platform == "darwin" else 1024
    return {"words": words, "completed": [c["id"] for c in cues], "failures": failures, "elapsed": time.monotonic() - started, "peakMemoryMB": memory / divisor}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--keep-workdir", action="store_true", help="Preserve per-job logs for developer diagnostics")
    args = parser.parse_args()
    # MFA compares absolute workflow paths when selecting its final archives.
    # Relative temporary paths can silently skip all exported word intervals.
    args.request = str(Path(args.request).resolve())
    args.output = str(Path(args.output).resolve())
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    # Cancellation from Swift terminates this process and all ffmpeg/MFA descendants.
    if os.getpgrp() != os.getpid():
        os.setsid()
    def terminate_group(signum, frame):
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        os.killpg(os.getpgrp(), signal.SIGTERM)
    signal.signal(signal.SIGTERM, terminate_group)
    job = json.loads(Path(args.request).read_text())
    folder_args = {"prefix": "alignment-", "dir": str(Path(args.output).parent)}
    context = contextlib.nullcontext(tempfile.mkdtemp(**folder_args)) if args.keep_workdir else tempfile.TemporaryDirectory(**folder_args)
    with context as folder:
        try:
            result = run_job(job, Path(folder))
            if result["failures"]:
                with Path(args.output).with_suffix(".error.log").open("w") as diagnostic:
                    for log in sorted(Path(folder).rglob("*.log")):
                        diagnostic.write("\n=== " + str(log.relative_to(folder)) + " ===\n" + log.read_text(errors="replace"))
        except Exception as error:
            # Copy text diagnostics before TemporaryDirectory removes audio and
            # MFA's working database. Never copy corpus WAVs into retained logs.
            log_files = sorted(Path(folder).rglob("*.log"))
            with Path(args.output).with_suffix(".error.log").open("w") as diagnostic:
                for log in log_files:
                    diagnostic.write("\n=== " + str(log.relative_to(folder)) + " ===\n")
                    diagnostic.write(log.read_text(errors="replace"))
            Path(args.output).with_suffix(".error.json").write_text(json.dumps({"stage": STAGE, "message": str(error), "exitCode": getattr(error, "returncode", None)}, ensure_ascii=False))
            raise
    output = Path(args.output)
    temporary = output.with_suffix(".tmp")
    temporary.write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
    temporary.replace(output)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
