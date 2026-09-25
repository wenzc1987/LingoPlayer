#!/usr/bin/env python3
"""Import the actual ECDICT CSV; never substitute invented dictionary entries."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--csv", type=Path)
parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / ".runtime/ecdict.sqlite")
args = parser.parse_args()
args.output.parent.mkdir(parents=True, exist_ok=True)
csv_path = args.csv or args.output.parent / "ecdict.csv"
source = "https://raw.githubusercontent.com/skywind3000/ECDICT/master/ecdict.csv"
if not csv_path.exists():
    subprocess.run(["curl", "-fL", "--retry", "2", "--connect-timeout", "20", "--max-time", "600", source, "-o", str(csv_path) + ".download"], check=True)
    Path(str(csv_path) + ".download").replace(csv_path)
temporary = args.output.with_suffix(".importing.sqlite")
started = time.monotonic()
with sqlite3.connect(temporary) as database, csv_path.open(encoding="utf-8-sig", newline="") as stream:
    database.execute("DROP TABLE IF EXISTS entries")
    database.execute("CREATE TABLE entries (word TEXT PRIMARY KEY COLLATE NOCASE, phonetic TEXT, definition TEXT, translation TEXT, exchange TEXT)")
    rows = csv.DictReader(stream)
    required = ["word", "phonetic", "definition", "translation", "exchange"]
    if not set(required).issubset(rows.fieldnames or []):
        raise SystemExit("ECDICT CSV columns are missing")
    database.executemany("INSERT OR IGNORE INTO entries VALUES (?,?,?,?,?)", ([row.get(key, "") or "" for key in required] for row in rows if row.get("word")))
    count = database.execute("SELECT COUNT(*) FROM entries").fetchone()[0]
    if count < 1000:
        raise SystemExit("Dictionary unexpectedly small; import aborted")
    database.execute("PRAGMA user_version=1")
    database.commit()
temporary.replace(args.output)
args.output.with_suffix(".source.json").write_text(json.dumps({"source": source if args.csv is None else "local CSV", "csv_sha256": hashlib.sha256(csv_path.read_bytes()).hexdigest(), "entries": count, "elapsed_seconds": time.monotonic() - started}, indent=2))
print("Imported %d ECDICT entries into %s" % (count, args.output))
