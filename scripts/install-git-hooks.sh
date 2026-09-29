#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
TASK_EXISTING="$(git config --get core.hooksPath || true)"
if [ -n "$TASK_EXISTING" ] && [ "$TASK_EXISTING" != '.githooks' ]; then
  echo "已有自定义 Git 钩子路径，未覆盖：$TASK_EXISTING" >&2
  exit 1
fi
if [ -z "$TASK_EXISTING" ]; then
  for TASK_HOOK in "$(git rev-parse --git-path hooks)"/*; do
    case "$TASK_HOOK" in *.sample) continue ;; esac
    if [ -f "$TASK_HOOK" ] && [ -x "$TASK_HOOK" ]; then
      echo "已有 Git 钩子，未覆盖：$TASK_HOOK" >&2
      exit 1
    fi
  done
fi
git config --local core.hooksPath .githooks
echo '已启用本仓库的自动提交版本号。'
