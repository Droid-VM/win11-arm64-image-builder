#!/usr/bin/env bash
# =====================================================================
# 00-make-patches.sh — folds the original Linux-side workflow into the Mac: runs via a Colima container
# macos/make-patches.sh (hivex), producing two testsigning BCDs into files/patches/. No separate Linux needed.
#   Requires: brew install colima docker
#   Usage: 00-make-patches.sh <iso-path>   (or set SRC_ISO; FORCE=1 to force a rebuild)
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="${FILES:-$HERE/files}"

ISO="${1:-${SRC_ISO:-}}"
[ -n "$ISO" ] && [ -f "$ISO" ] || { echo "[patches] need a valid ISO (first argument or SRC_ISO): '$ISO'"; exit 1; }
ISO_ABS="$(cd "$(dirname "$ISO")" && pwd)/$(basename "$ISO")"
OUTDIR="$FILES/patches"; mkdir -p "$OUTDIR"

# Skip if already produced (FORCE=1 forces a rebuild)
if [ -z "${FORCE:-}" ] && [ -f "$OUTDIR/bcd-patched" ] && [ -f "$OUTDIR/bcd-template-patched" ]; then
  echo "[patches] already exists, skipping (FORCE=1 to rebuild): $OUTDIR"
  exit 0
fi

command -v colima >/dev/null || { echo "missing colima — brew install colima docker"; exit 1; }
command -v docker >/dev/null || { echo "missing docker CLI — brew install docker"; exit 1; }

# Ensure Colima (the Linux VM) is running
if ! colima status >/dev/null 2>&1; then
  echo "[patches] starting Colima ..."
  colima start
fi

echo "[patches] building patcher image (slow the first time, cached afterwards) ..."
docker build -q -t droidvm-patcher "$HERE" >/dev/null

echo "[patches] generating testsigning BCD inside the container ..."
# --privileged: make-patches.sh uses a loop mount to read the ISO (the Colima Lima VM has a real kernel + loop).
# Mount macos/ -> /work (scripts live in /work, writing to /work/files/patches); ISO -> /iso.iso.
docker run --rm --privileged \
  -v "$HERE:/work" \
  -v "$ISO_ABS:/iso.iso:ro" \
  -e SRC_ISO=/iso.iso -e OUT_DIR=/work/files/patches -e "IMAGE_INDEX=${IMAGE_INDEX:-1}" \
  -w /work \
  droidvm-patcher ./make-patches.sh

[ -f "$OUTDIR/bcd-patched" ] && [ -f "$OUTDIR/bcd-template-patched" ] \
  || { echo "[patches] container finished but produced no output, check the messages above"; exit 1; }
echo "[patches] done -> $OUTDIR"
