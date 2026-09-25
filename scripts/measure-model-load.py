#!/usr/bin/env python3
"""Measure one fresh Python process loading the actual MFA acoustic weights.

This is not a cold disk-cache benchmark and excludes feature extraction/alignment.
Run with .runtime/aligner/bin/python, whose Kalpy ABI matches the installed MFA.
"""
import argparse
import json
from pathlib import Path
import resource
import sys
import tempfile
import time
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument("--model", required=True, type=Path)
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
started = time.perf_counter()
from kalpy.gmm.utils import read_gmm_model, read_tree
imported = time.perf_counter()
with tempfile.TemporaryDirectory(prefix="model-load-", dir=args.output.parent.resolve()) as directory:
    folder = Path(directory)
    with zipfile.ZipFile(args.model) as archive:
        for name in ("final.alimdl", "tree"):
            candidates = [entry for entry in archive.namelist() if Path(entry).name == name]
            if len(candidates) != 1:
                raise RuntimeError("Expected one %s in model archive" % name)
            (folder / name).write_bytes(archive.read(candidates[0]))
    unpacked = time.perf_counter()
    transition, acoustic = read_gmm_model(folder / "final.alimdl")
    tree = read_tree(folder / "tree")
    loaded = time.perf_counter()
report = {
    "import_seconds": imported - started,
    "unpack_seconds": unpacked - imported,
    "acoustic_weights_and_tree_load_seconds": loaded - unpacked,
    "total_seconds": loaded - started,
    "peak_process_memory_mb": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1048576 if sys.platform == "darwin" else 1024),
    "method": "Fresh Python process; import Kalpy, extract final.alimdl and tree from english_mfa, deserialize actual GMM weights/transition model/tree. OS disk cache not cleared. Excludes features, lexicon and alignment."
}
args.output.write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
