#!/usr/bin/env bash
# =====================================================================
# build.sh — Win11 ARM64 開機 qcow2「一鍵」建置（Apple Silicon Mac）
# 由 build_runme.sh 提供變數（或自行 export 後執行）。檔案類變數可為 URL 或本地路徑：
#   URL -> 下載到 files/ 再用；本地路徑 -> 直接用；zip -> 解壓到 files/。
# 流程：解析輸入 -> 02 封裝 ISO -> 03 HVF 安裝（自動關機）-> qemu-img 壓縮。
# 需求：brew install qemu wimlib xorriso
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export LC_ALL="${LC_ALL:-en_US.UTF-8}" LANG="${LANG:-en_US.UTF-8}"
# 結束時（成功或失敗）刪掉 build 自己建的 patcher image，不動使用者其他 image（不用 prune）
trap 'docker image rm -f droidvm-patcher >/dev/null 2>&1 || true' EXIT
. "$HERE/common.sh"

for t in qemu-system-aarch64 wimlib-imagex xorriso; do
  command -v "$t" >/dev/null || { echo "缺 $t — brew install qemu wimlib xorriso"; exit 1; }
done

# 解析 install.wim 的版本 index：IMAGE_INDEX 空或 0 -> 列出版本讓使用者選；有值 -> 驗證後採用。
# 用 wimlib-imagex 讀 ISO 內的 install.wim（macOS 有 wimlib，不需 Windows 的 DISM）。回傳選定 index 到 stdout。
resolve_image_index() {
  local iso="$1" want="${IMAGE_INDEX:-0}" attach dev mnt wim list valid sel
  attach="$(hdiutil attach -readonly -nobrowse -noverify "$iso")"
  dev="$(printf '%s\n' "$attach" | grep -oE '/dev/disk[0-9]+' | head -1)"
  mnt="$(printf '%s\n' "$attach" | grep -oE '/Volumes/.*' | head -1)"
  wim="$mnt/sources/install.wim"
  [ -f "$wim" ] || { hdiutil detach "$dev" >/dev/null 2>&1 || true; echo "找不到 install.wim" >&2; return 1; }
  list="$(wimlib-imagex info "$wim" | awk '
    /^Index:/ {idx=$2}
    /^Name:/  {n=$0; sub(/^Name:[[:space:]]*/,"",n); print idx"\t"n}')"
  valid="$(printf '%s\n' "$list" | cut -f1)"
  hdiutil detach "$dev" >/dev/null 2>&1 || true
  [ -n "$valid" ] || { echo "install.wim 沒有任何版本" >&2; return 1; }

  if [ "$want" -gt 0 ] 2>/dev/null; then
    printf '%s\n' "$valid" | grep -qx "$want" && { printf '%s\n' "$want"; return 0; }
    echo "IMAGE_INDEX=$want 不在此 ISO；可選：$(echo $valid)" >&2; return 1
  fi
  echo "install.wim 版本：" >&2
  printf '%s\n' "$list" | while IFS="$(printf '\t')" read -r i n; do echo "  [$i] $n" >&2; done
  [ -t 0 ] || { echo "IMAGE_INDEX 未設且非互動；請填其中之一：$(echo $valid)" >&2; return 1; }
  while :; do
    printf "選擇 image index: " >&2; read -r sel
    printf '%s\n' "$valid" | grep -qx "$sel" && { printf '%s\n' "$sel"; return 0; }
    echo "  無效，請從這些選：$(echo $valid)" >&2
  done
}

# --- 必要變數（建議用 build_runme.sh 設定）---
: "${SRC_ISO:?請設 SRC_ISO（Win11 ARM64 ISO 的 URL 或路徑）— 建議用 build_runme.sh}"
: "${DRIVERS_DIR:?請設 DRIVERS_DIR（驅動 zip/資料夾 的 URL 或路徑）}"

# --- 解析檔案類輸入成絕對路徑，export 給 02/03（不再掃描 inputs/）---
SRC_ISO="$(resolve_file "$SRC_ISO" "win11-arm64.iso")"

# --- install.wim 版本 index（空/0 = 偵測並詢問）。patches 與 autounattend 都會用到 ---
IMAGE_INDEX="$(resolve_image_index "$SRC_ISO")"
export IMAGE_INDEX   # 讓後面呼叫的 00-make-patches.sh 也拿得到
echo "[build] IMAGE_INDEX = $IMAGE_INDEX"

# --- 驅動：DRIVERS_DIR（zip/資料夾）解壓/解析成「ZIP 根目錄」；DRIVER_DIR / DRIVER_CERT
#     開頭的 ZIP 前綴展開成該根目錄。之後只安裝 DRIVER_INSTALL 指定的驅動 + DRIVER_CERT。---
ZIP="$(resolve_dir "$(resolve_file "$DRIVERS_DIR" "gunyah-arm64-drivers.zip")")"
DRIVER_DIR="${DRIVER_DIR:-ZIP/drivers}"
DRIVER_CERT="${DRIVER_CERT:-}"
DRIVER_DIR="${DRIVER_DIR/#ZIP/$ZIP}"
[ -n "$DRIVER_CERT" ] && DRIVER_CERT="${DRIVER_CERT/#ZIP/$ZIP}"
[ -d "$DRIVER_DIR" ] || { echo "找不到驅動資料夾 DRIVER_DIR: $DRIVER_DIR"; exit 1; }
[ -z "$DRIVER_CERT" ] || [ -f "$DRIVER_CERT" ] || { echo "找不到 DRIVER_CERT: $DRIVER_CERT"; exit 1; }

# --- testsigning BCD：沒指定就用 Colima 容器自動產生（原本的 Linux 端流程已併進來）。
#     有指定（URL 或路徑）就照用，交給下面的 resolve_file。---
if [ -z "${BCD_PATCHED:-}" ] || [ -z "${BCD_TEMPLATE:-}" ]; then
  echo "[build] === 1/4 產生 testsigning BCD（Colima 容器）==="
  bash "$HERE/00-make-patches.sh" "$SRC_ISO"
  BCD_PATCHED="$FILES/patches/bcd-patched"
  BCD_TEMPLATE="$FILES/patches/bcd-template-patched"
fi
BCD_PATCHED="$(resolve_file "$BCD_PATCHED" "bcd-patched")"
BCD_TEMPLATE="$(resolve_file "$BCD_TEMPLATE" "bcd-template-patched")"

# --- 帳號 / SSH：USERNAME/PASSWORD 注入 autounattend；OPENSSH_SRC 解析後 staging（空=不裝 SSH）---
USERNAME="${USERNAME:-USER}"
PASSWORD="${PASSWORD:-}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
OPENSSH_SRC="${OPENSSH_SRC:-}"
[ -n "$OPENSSH_SRC" ] && OPENSSH_SRC="$(resolve_file "$OPENSSH_SRC")"

export SRC_ISO IMAGE_INDEX DRIVER_DIR DRIVER_INSTALL DRIVER_CERT BCD_PATCHED BCD_TEMPLATE \
       USERNAME PASSWORD SSH_PUBKEY OPENSSH_SRC FILES

echo "[build] === 2/4 封裝安裝 ISO ==="
bash "$HERE/02-make-iso.sh"
echo "[build] === 3/4 HVF 安裝（全自動，跑完自動關機）==="
bash "$HERE/03-run-install.sh"

echo "[build] === 4/4 壓縮 qcow2 ==="
OUT_QCOW="${OUT_QCOW:-$HERE/win11-droidvm-final.qcow2}"   # 最終產物放 macos/
# convert 只寫已配置的 cluster -> 產物是精簡/sparse 的（安裝時 discard=unmap + debloat 的
# Optimize-Volume -ReTrim 已把 guest 釋放的空間即時 TRIM 掉，工作 qcow2 本身就不會膨脹）。
qemu-img convert -O qcow2 "$FILES/win11-droidvm.qcow2" "$OUT_QCOW"
sz=$(ls -lh "$OUT_QCOW" | awk '{print $5}')
echo "[build] 完成 ✅  -> $OUT_QCOW ($sz)"

# 收尾：把大中間檔（工作 qcow2 ~8G、setup ISO ~5G）刪掉還空間給 Mac；下載快取(files/patches、
# 驅動、msi)保留。要留著中間檔除錯就設 KEEP_WORK=1。
if [ -z "${KEEP_WORK:-}" ]; then
  rm -f "$FILES/win11-droidvm.qcow2" "$FILES/win11-droidvm-setup.iso" \
        "$FILES/edk2-arm-vars.fd" "$FILES/qmp.sock" "$FILES/clicker.log"
  echo "[build] 已清中間檔（KEEP_WORK=1 可保留）"
fi
# 把 Colima VM 內釋放的空間（BCD patch 的暫存 raw 等）trim 還給 Mac 的磁碟映像（best-effort）
colima ssh -- sudo fstrim -a >/dev/null 2>&1 || true
