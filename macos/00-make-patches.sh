#!/usr/bin/env bash
# =====================================================================
# 00-make-patches.sh — 把原本的「Linux 端」流程併進 Mac：用 Colima 容器跑
# macos/make-patches.sh（hivex），產生兩個 testsigning BCD 到 files/patches/。免另一台 Linux。
#   需求：brew install colima docker
#   用法：00-make-patches.sh <iso-path>   （或設 SRC_ISO；FORCE=1 可強制重做）
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

ISO="${1:-${SRC_ISO:-}}"
[ -n "$ISO" ] && [ -f "$ISO" ] || { echo "[patches] 需要有效的 ISO（第一個參數或 SRC_ISO）: '$ISO'"; exit 1; }
ISO_ABS="$(cd "$(dirname "$ISO")" && pwd)/$(basename "$ISO")"
OUTDIR="$ROOT/files/patches"; mkdir -p "$OUTDIR"

# 已產好就跳過（FORCE=1 強制重做）
if [ -z "${FORCE:-}" ] && [ -f "$OUTDIR/bcd-patched" ] && [ -f "$OUTDIR/bcd-template-patched" ]; then
  echo "[patches] 已存在，略過（FORCE=1 可重做）：$OUTDIR"
  exit 0
fi

command -v colima >/dev/null || { echo "缺 colima — brew install colima docker"; exit 1; }
command -v docker >/dev/null || { echo "缺 docker CLI — brew install docker"; exit 1; }

# 確保 Colima（Linux VM）有跑
if ! colima status >/dev/null 2>&1; then
  echo "[patches] 啟動 Colima ..."
  colima start
fi

echo "[patches] 建 patcher image（首次較久，之後有快取）..."
docker build -q -t droidvm-patcher "$HERE" >/dev/null

echo "[patches] 容器內產生 testsigning BCD ..."
# --privileged：make-patches.sh 用 loop mount 讀 ISO（Colima 的 Lima VM 有真 kernel + loop）。
# 掛：整個專案 -> /work（拿 macos/ 腳本、寫 files/patches）；ISO -> /iso.iso。
docker run --rm --privileged \
  -v "$ROOT:/work" \
  -v "$ISO_ABS:/iso.iso:ro" \
  -e SRC_ISO=/iso.iso -e OUT_DIR=/work/files/patches -e "IMAGE_INDEX=${IMAGE_INDEX:-1}" \
  -w /work/macos \
  droidvm-patcher ./make-patches.sh

[ -f "$OUTDIR/bcd-patched" ] && [ -f "$OUTDIR/bcd-template-patched" ] \
  || { echo "[patches] 容器跑完但沒產出，檢查上面訊息"; exit 1; }
echo "[patches] 完成 -> $OUTDIR"
