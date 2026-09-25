#!/usr/bin/env python3
"""Fetch official IINA libmpv builds into this project's isolated runtime."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import platform
import subprocess

root = Path(__file__).resolve().parents[1]
destination = root / ".runtime" / "lib"
destination.mkdir(parents=True, exist_ok=True)
base = "https://iina.io/dylibs/" + platform.machine()
manifest = destination / "filelist.txt"
subprocess.run(["curl", "-fL", "--retry", "2", "--connect-timeout", "20", "--max-time", "120", base + "/filelist.txt", "-o", str(manifest)], check=True)
names = [line.strip() for line in manifest.read_text().splitlines() if line.strip()]
if not names or any(Path(name).name != name or not name.endswith(".dylib") for name in names):
    raise SystemExit("Unexpected IINA library manifest")

def download(name):
    target = destination / name
    if not target.exists():
        partial = target.with_suffix(target.suffix + ".download")
        subprocess.run(["curl", "-fL", "--retry", "2", "--connect-timeout", "20", "--max-time", "300", "--silent", "--show-error", base + "/" + name, "-o", str(partial)], check=True)
        partial.replace(target)
    # IINA libraries refer to sibling libraries using @rpath. Add a local rpath
    # instead of changing global linker settings or another installed app.
    result = subprocess.run(["otool", "-l", str(target)], capture_output=True, text=True, check=True)
    if "path @loader_path " not in result.stdout:
        subprocess.run(["install_name_tool", "-add_rpath", "@loader_path", str(target)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(target)], check=True, capture_output=True)
    return {"file": name, "sha256": hashlib.sha256(target.read_bytes()).hexdigest(), "source": base + "/" + name}

with ThreadPoolExecutor(max_workers=5) as pool:
    records = list(pool.map(download, names))
(destination / "provenance.json").write_text(json.dumps(records, indent=2))
print("Installed %d media libraries into %s" % (len(records), destination))
