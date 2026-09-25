#!/usr/bin/env python3
"""Evaluate independent HUMAN annotations; never treat MFA output as its reference.

CSV columns: cueID,tokenIndex,start,category. Category: clear / fast / music.
"""
import argparse
import csv
import json
from pathlib import Path
import statistics

parser = argparse.ArgumentParser()
parser.add_argument("--result", required=True, type=Path)
parser.add_argument("--reference", required=True, type=Path)
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
result = json.loads(args.result.read_text())
predictions = {(w["cueID"], int(w["tokenIndex"])): w["start"] for w in result["words"]}
with args.reference.open(newline="") as stream:
    reference = list(csv.DictReader(stream))
if not reference or not {"cueID", "tokenIndex", "start", "category"}.issubset(reference[0]):
    raise SystemExit("Reference CSV must contain cueID,tokenIndex,start,category")
seen = set()
for row in reference:
    key = (row["cueID"], int(row["tokenIndex"]))
    if key in seen:
        raise SystemExit("Duplicate reference word: %r" % (key,))
    seen.add(key)
    if row["category"] not in ("clear", "fast", "music"):
        raise SystemExit("Unknown category")
    if float(row["start"]) < 0:
        raise SystemExit("Reference time must be nonnegative")
report = {"reference_words": len(reference), "categories": {}}
for category in ("clear", "fast", "music"):
    rows = [r for r in reference if r["category"] == category]
    errors = [abs(predictions[(r["cueID"], int(r["tokenIndex"]))] - float(r["start"])) for r in rows if (r["cueID"], int(r["tokenIndex"])) in predictions]
    passing = sum(error <= 0.2 for error in errors)
    report["categories"][category] = {"reference_words": len(rows), "aligned_words": len(errors), "missing_words": len(rows) - len(errors), "within_200ms_fraction": passing / len(rows) if rows else None, "median_error_ms": statistics.median(errors) * 1000 if errors else None}
clear = report["categories"]["clear"]
report["acceptance_passed"] = len(reference) >= 100 and all(report["categories"][c]["reference_words"] > 0 for c in ("clear", "fast", "music")) and (clear["within_200ms_fraction"] or 0) >= 0.9
report["reference_requirement"] = "Reference word starts must be independently annotated by a human. Missing predictions count as failures."
args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False))
print(json.dumps(report, indent=2, ensure_ascii=False))
