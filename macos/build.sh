#!/usr/bin/env bash
# =====================================================================
# build.sh — Win11 ARM64 開機 qcow2「一鍵」建置（Apple Silicon Mac）
# 前置：1) inputs/ 放 Win11 ARM64 ISO + drivers/（或 drivers.zip）+ 憑證
#       2) 已在 Linux 端跑過 linux/make-patches.sh，產生 patches/
# 流程：02 封裝 ISO -> 03 HVF 安裝（全自動，跑完自動關機）-> qemu-img 壓縮
# 需求：brew install qemu wimlib xorriso
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export LC_ALL="${LC_ALL:-en_US.UTF-8}" LANG="${LANG:-en_US.UTF-8}"
[ -f "$ROOT/load-env.sh" ] && . "$ROOT/load-env.sh"   # 自動載入 .env

for t in qemu-system-aarch64 wimlib-imagex xorriso; do
  command -v "$t" >/dev/null || { echo "缺 $t — brew install qemu wimlib xorriso"; exit 1; }
done
[ -f "$ROOT/patches/bcd-template-patched" ] || { echo "缺 patches/ — 請先在 Linux 端跑 linux/make-patches.sh"; exit 1; }

# 驅動來源（URL / 本地 zip / 資料夾）由 02-make-iso.sh 解析：
# URL 或 zip 會正規化成 inputs/drivers.zip，再解開成 inputs/drivers/。

echo "[build] === 1/3 封裝安裝 ISO ==="
bash "$HERE/02-make-iso.sh"
echo "[build] === 2/3 HVF 安裝（全自動，跑完自動關機）==="
bash "$HERE/03-run-install.sh"

echo "[build] === 3/3 壓縮 qcow2 ==="
qemu-img convert -O qcow2 "$ROOT/win11-droidvm.qcow2" "$ROOT/win11-droidvm-final.qcow2"
sz=$(ls -lh "$ROOT/win11-droidvm-final.qcow2" | awk '{print $5}')
echo "[build] 完成 ✅  -> $ROOT/win11-droidvm-final.qcow2 ($sz)"
