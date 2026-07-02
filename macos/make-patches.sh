#!/usr/bin/env bash
# =====================================================================
# make-patches.sh  (需要 hivex / wimlib — 由 macos/00-make-patches.sh 在 Colima 容器內跑)
# 從 Win11 ARM64 ISO 產出兩個已 patch testsigning 的 BCD：
#   bcd-patched          安裝媒體 BCD（讓 WinPE/Setup 載入自簽 viostor）
#   bcd-template-patched install.wim 內的 BCD-Template（bcdboot 建 BCD 的範本
#                        -> 裝好的系統第一次開機就有 testsigning）
# 這兩個檔很小（~25KB）。macOS 沒有 hivex，所以在容器裡做。
#
# 需求：libhivex-bin wimtools（見 macos/Dockerfile）
# 輸入：SRC_ISO（ISO 路徑）、OUT_DIR（輸出目錄，預設 ../files/patches）
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/files/patches}"
IMAGE_INDEX="${IMAGE_INDEX:-1}"   # 由 build.sh 偵測/選定後傳入；預設 1 = Enterprise LTSC
mkdir -p "$OUT"

: "${SRC_ISO:?SRC_ISO 未設（由 00-make-patches.sh 以 /iso.iso 傳入）}"
[ -f "$SRC_ISO" ] || { echo "找不到 ISO: $SRC_ISO"; exit 1; }
for t in hivexregedit wimlib-imagex; do
  command -v "$t" >/dev/null || { echo "缺 $t — 見 macos/Dockerfile"; exit 1; }
done
echo "SRC_ISO = $SRC_ISO"

MNT="$(mktemp -d)"; mount -o loop,ro "$SRC_ISO" "$MNT"
# STAGE 在容器本地 native fs：hivex 對 hive「就地寫入」在 Colima 的 virtiofs 掛載上會失敗（exit 13），
# 所以在本地改好再複製到 $OUT（$OUT 通常在掛進來的專案目錄 = virtiofs）。
STAGE="$(mktemp -d)"
trap 'umount "$MNT" 2>/dev/null; rmdir "$MNT"; rm -rf "$STAGE"' EXIT

# ISO/wim 抽出的檔常是唯讀(0555)；hive 要可寫，複製出去也要能覆蓋舊檔（virtiofs 上 root 映射成
# 一般使用者，覆蓋唯讀檔會被拒），故一律 chmod u+w，並在寫回 $OUT 前先 rm -f。
# --- 安裝媒體 BCD ---
echo "[1/2] 安裝媒體 BCD -> testsigning"
cp "$MNT/efi/microsoft/boot/bcd" "$STAGE/bcd-patched"; chmod u+w "$STAGE/bcd-patched"
python3 "$HERE/bcd-testsigning.py" "$STAGE/bcd-patched"
rm -f "$OUT/bcd-patched"; cp "$STAGE/bcd-patched" "$OUT/bcd-patched"

# --- install.wim 的 BCD-Template（用選定的 IMAGE_INDEX）---
echo "[2/2] install.wim BCD-Template (index $IMAGE_INDEX) -> testsigning"
wimlib-imagex extract "$MNT/sources/install.wim" "$IMAGE_INDEX" \
  "/Windows/System32/config/BCD-Template" --dest-dir="$STAGE" --no-acls >/dev/null
chmod u+w "$STAGE/BCD-Template"
python3 "$HERE/bcd-testsigning.py" "$STAGE/BCD-Template"
rm -f "$OUT/bcd-template-patched"; cp "$STAGE/BCD-Template" "$OUT/bcd-template-patched"

echo
echo "完成 -> $OUT"
ls -la "$OUT"
