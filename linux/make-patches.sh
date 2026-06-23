#!/usr/bin/env bash
# =====================================================================
# make-patches.sh  (在 Linux 執行，需要 hivex / wimlib)
# 從 inputs/ 的 Win11 ARM64 ISO 產出兩個已 patch testsigning 的 BCD：
#   patches/bcd-patched          安裝媒體 BCD（讓 WinPE/Setup 載入自簽 viostor）
#   patches/bcd-template-patched install.wim 內的 BCD-Template（bcdboot 建 BCD
#                                的範本 -> 裝好的系統第一次開機就有 testsigning）
# 這兩個檔很小（~25KB），交給 macOS 端 build（macOS 沒有 hivex，所以在這裡先做）。
#
# 需求：apt install -y libhivex-bin wimtools
# 用法：cd linux && ./make-patches.sh
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
IN="$ROOT/inputs"
OUT="$ROOT/patches"
mkdir -p "$OUT"
[ -f "$ROOT/load-env.sh" ] && . "$ROOT/load-env.sh"   # 自動載入 .env

SRC_ISO="${SRC_ISO:-$(ls "$IN"/*arm64*dvd*.iso "$IN"/*ARM64*.iso "$IN"/*.iso 2>/dev/null | head -1 || true)}"
[ -f "$SRC_ISO" ] || { echo "在 inputs/ 找不到 Win11 ARM64 ISO"; exit 1; }
for t in hivexregedit wimlib-imagex; do
  command -v "$t" >/dev/null || { echo "缺 $t — apt install -y libhivex-bin wimtools"; exit 1; }
done
echo "SRC_ISO = $SRC_ISO"

MNT="$(mktemp -d)"; mount -o loop,ro "$SRC_ISO" "$MNT"
trap 'umount "$MNT" 2>/dev/null; rmdir "$MNT"' EXIT

# --- 安裝媒體 BCD ---
echo "[1/2] 安裝媒體 BCD -> testsigning"
cp "$MNT/efi/microsoft/boot/bcd" "$OUT/bcd-patched"
python3 "$HERE/bcd-testsigning.py" "$OUT/bcd-patched"

# --- install.wim 的 BCD-Template（index 2 = IoT Enterprise LTSC）---
echo "[2/2] install.wim BCD-Template -> testsigning"
TMP="$(mktemp -d)"
wimlib-imagex extract "$MNT/sources/install.wim" 2 \
  "/Windows/System32/config/BCD-Template" --dest-dir="$TMP" --no-acls >/dev/null
cp "$TMP/BCD-Template" "$OUT/bcd-template-patched"
python3 "$HERE/bcd-testsigning.py" "$OUT/bcd-template-patched"
rm -rf "$TMP"

echo
echo "完成。patches/:"
ls -la "$OUT"
echo "把整個專案（含 patches/）同步到 Mac，於 macos/ 跑 build.sh。"
