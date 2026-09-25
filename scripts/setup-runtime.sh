#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:---all}" in
  --media) python3 "$TASK_ROOT/scripts/download-media-runtime.py" ;;
  --alignment) bash "$TASK_ROOT/scripts/setup-aligner.sh" ;;
  --dictionary) python3 "$TASK_ROOT/scripts/import-ecdict.py" ;;
  --all)
    python3 "$TASK_ROOT/scripts/download-media-runtime.py"
    bash "$TASK_ROOT/scripts/setup-aligner.sh"
    python3 "$TASK_ROOT/scripts/import-ecdict.py"
    ;;
  *) echo "Usage: bash scripts/setup-runtime.sh [--all|--media|--alignment|--dictionary]" >&2; exit 2 ;;
esac
