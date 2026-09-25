#!/usr/bin/env python3
"""Export source words for independent listening annotation, without predictions."""
import argparse
import csv
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--request", required=True, type=Path)
parser.add_argument("--category", required=True, choices=["clear", "fast", "music"])
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
job = json.loads(args.request.read_text())
with args.output.open("w", newline="", encoding="utf-8") as stream:
    writer = csv.writer(stream)
    writer.writerow(["cueID", "tokenIndex", "start", "category", "word", "cueStart", "cueEnd"])
    for cue in job["cues"]:
        for token in cue["tokens"]:
            if token.get("isWord", True):
                writer.writerow([cue["id"], token["id"], "", args.category, token["text"], cue["start"], cue["end"]])
print("Fill start with independently heard word-onset seconds; blank values are intentionally not predictions.")
