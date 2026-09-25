#!/usr/bin/env python3
"""Collect measured outputs for the checked-in validation record."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
local = root / "verification/local"
read = lambda path: json.loads(path.read_text())
alignment = read(local / "clear-result.json")
gui, metrics = {}, {}
for scenario in ("mp4", "mkv"):
    folder = local / ("ui-" + scenario)
    gui[scenario] = read(folder / "smoke.json")
    logs = list(folder.glob("state-*/alignment-metrics.jsonl"))
    latest = max(logs, key=lambda path: path.stat().st_mtime)
    metrics[scenario] = [json.loads(line) for line in latest.read_text().splitlines()]
versions = {}
for path in (root / ".runtime/aligner/conda-meta").glob("*.json"):
    data = read(path)
    if data.get("name") in ("python", "ffmpeg", "montreal-forced-aligner", "kalpy", "sqlalchemy"):
        versions[data["name"]] = data["version"]
checksum = hashlib.sha256()
for path in sorted((root / "Sources").rglob("*")):
    if path.suffix in (".swift", ".c", ".h", ".py"):
        checksum.update(str(path.relative_to(root)).encode()); checksum.update(path.read_bytes())
test_log = (local / "tests.log").read_text()
swift_tests = re.search(r"Test run with (\d+) tests.*passed", test_log)
python_tests = re.search(r"Ran (\d+) tests", test_log)
if not swift_tests or not python_tests or not re.search(r"^OK$", test_log, re.MULTILINE):
    raise RuntimeError("Expected successful Swift and Python test output in verification/local/tests.log")
report = {
    "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
    "os": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
    "cpu": "Intel Core i5-8259U @ 2.30GHz", "memory_gib": 8,
    "runtime_versions": versions,
    "source_sha256": checksum.hexdigest(),
    "tests": {"swift": int(swift_tests[1]), "python": int(python_tests[1]), "passed": True, "command": "bash scripts/test.sh", "log_sha256": hashlib.sha256(test_log.encode()).hexdigest()},
    "fixture": read(local / "provenance.json"),
    "dictionary": read(root / ".runtime/ecdict.source.json"),
    "model_load": read(local / "model-load.json"),
    "whole_clip_alignment": {"word_count": len(alignment["words"]), "elapsed_seconds": alignment["elapsed"], "child_peak_memory_mb": alignment["peakMemoryMB"], "failed_cues": alignment["failures"]},
    "gui": gui, "application_batches": metrics,
    "accuracy_acceptance": {"status": "pending", "human_annotated_words": 0, "clear_within_200ms_fraction": None, "reason": "No independent human word-onset labels; fast/music movie scenarios not evaluated."},
    "online_subtitle_acceptance": {"status": "pending", "reason": "No personal OpenSubtitles credentials supplied; local discovery and mock API failures verified."}
}
report["fixture"]["translation_note"] = "Chinese translations authored for this integration fixture, not part of the LibriSpeech reference corpus."
(root / "verification/results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
(root / "verification/word-times-clear.json").write_text(json.dumps(alignment, indent=2) + "\n")
print(json.dumps({name: {"passed": data["passed"], "checks": len(data["checks"])} for name, data in gui.items()}, indent=2))
