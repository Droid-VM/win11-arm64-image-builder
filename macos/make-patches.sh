#!/usr/bin/env bash
# =====================================================================
# make-patches.sh  (needs hivex / wimlib — run by macos/00-make-patches.sh inside a Colima container)
# Produces two testsigning-patched BCDs from a Win11 ARM64 ISO:
#   bcd-patched          install media BCD (lets WinPE/Setup load the self-signed viostor)
#   bcd-template-patched BCD-Template inside install.wim (the template bcdboot uses to build the BCD
#                        -> so the installed system has testsigning on first boot)
# These two files are tiny (~25KB). macOS has no hivex, so this is done inside a container.
#
# Requires: libhivex-bin wimtools (see macos/Dockerfile)
# Inputs: SRC_ISO (ISO path), OUT_DIR (output directory, default ../files/patches)
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT_DIR:-$HERE/files/patches}"
IMAGE_INDEX="${IMAGE_INDEX:-1}"   # passed in after build.sh detects/selects it; default 1 = Enterprise LTSC
mkdir -p "$OUT"

: "${SRC_ISO:?SRC_ISO not set (passed by 00-make-patches.sh as /iso.iso)}"
[ -f "$SRC_ISO" ] || { echo "ISO not found: $SRC_ISO"; exit 1; }
for t in hivexregedit wimlib-imagex; do
  command -v "$t" >/dev/null || { echo "missing $t — see macos/Dockerfile"; exit 1; }
done
echo "SRC_ISO = $SRC_ISO"

MNT="$(mktemp -d)"; mount -o loop,ro "$SRC_ISO" "$MNT"
# STAGE lives on the container-local native fs: an hivex in-place write to a hive fails on the Colima virtiofs mount (exit 13),
# so we edit it locally and copy to $OUT ($OUT is usually the mounted-in project directory = virtiofs).
STAGE="$(mktemp -d)"
trap 'umount "$MNT" 2>/dev/null; rmdir "$MNT"; rm -rf "$STAGE"' EXIT

# Files extracted from ISO/wim are often read-only (0555); the hive must be writable, and copying out must overwrite old files (on virtiofs, root is mapped to
# a regular user, so overwriting a read-only file is denied), hence always chmod u+w, and rm -f before writing back to $OUT.
# --- Install media BCD ---
echo "[1/2] install media BCD -> testsigning"
cp "$MNT/efi/microsoft/boot/bcd" "$STAGE/bcd-patched"; chmod u+w "$STAGE/bcd-patched"
python3 "$HERE/bcd-testsigning.py" "$STAGE/bcd-patched"
rm -f "$OUT/bcd-patched"; cp "$STAGE/bcd-patched" "$OUT/bcd-patched"

# --- install.wim BCD-Template (using the selected IMAGE_INDEX) ---
echo "[2/2] install.wim BCD-Template (index $IMAGE_INDEX) -> testsigning"
wimlib-imagex extract "$MNT/sources/install.wim" "$IMAGE_INDEX" \
  "/Windows/System32/config/BCD-Template" --dest-dir="$STAGE" --no-acls >/dev/null
chmod u+w "$STAGE/BCD-Template"
python3 "$HERE/bcd-testsigning.py" "$STAGE/BCD-Template"
rm -f "$OUT/bcd-template-patched"; cp "$STAGE/BCD-Template" "$OUT/bcd-template-patched"

echo
echo "done -> $OUT"
ls -la "$OUT"
