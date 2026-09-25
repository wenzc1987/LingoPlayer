#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_RUNTIME="$TASK_ROOT/.runtime"
TASK_ARCH="$(uname -m)"
TASK_MINIFORGE_VERSION="25.3.1-0"
mkdir -p "$TASK_RUNTIME/downloads" "$TASK_RUNTIME/conda-pkgs" "$TASK_RUNTIME/mfa-models"
if [ ! -x "$TASK_RUNTIME/miniforge/bin/conda" ]; then
  TASK_INSTALLER="Miniforge3-${TASK_MINIFORGE_VERSION}-MacOSX-${TASK_ARCH}.sh"
  TASK_BASE="https://github.com/conda-forge/miniforge/releases/download/${TASK_MINIFORGE_VERSION}"
  curl -fL --retry 2 --connect-timeout 20 "$TASK_BASE/$TASK_INSTALLER" -o "$TASK_RUNTIME/downloads/$TASK_INSTALLER"
  curl -fL --retry 2 --connect-timeout 20 "$TASK_BASE/$TASK_INSTALLER.sha256" -o "$TASK_RUNTIME/downloads/$TASK_INSTALLER.sha256"
  (cd "$TASK_RUNTIME/downloads" && shasum -a 256 -c "$TASK_INSTALLER.sha256")
  bash "$TASK_RUNTIME/downloads/$TASK_INSTALLER" -b -p "$TASK_RUNTIME/miniforge"
fi
export CONDA_PKGS_DIRS="$TASK_RUNTIME/conda-pkgs"
export CONDA_ENVS_PATH="$TASK_RUNTIME/conda-envs"
TASK_CONDA_ACTION=install
if [ ! -x "$TASK_RUNTIME/aligner/bin/mfa" ]; then TASK_CONDA_ACTION=create; fi
# Keep the acoustic toolchain on one compatible release family. Newer kalpy
# changes its MFA API; do not silently resolve a future incompatible version.
"$TASK_RUNTIME/miniforge/bin/conda" "$TASK_CONDA_ACTION" -y --quiet --override-channels -c conda-forge -p "$TASK_RUNTIME/aligner" python=3.11 montreal-forced-aligner=3.3.9 kalpy=0.9 'sqlalchemy>=2.0,<2.1' ffmpeg
export PATH="$TASK_RUNTIME/aligner/bin:$PATH"
export MFA_ROOT_DIR="${LINGOPLAYER_DATA_DIR:-$HOME/Library/Application Support/LingoPlayer}/MFA"
mkdir -p "$MFA_ROOT_DIR"
"$TASK_RUNTIME/aligner/bin/mfa" model download acoustic english_mfa
"$TASK_RUNTIME/aligner/bin/mfa" model download dictionary english_us_mfa
"$TASK_RUNTIME/miniforge/bin/conda" list -p "$TASK_RUNTIME/aligner" --explicit > "$TASK_RUNTIME/aligner-lock.txt"
echo "Local alignment runtime is ready."
