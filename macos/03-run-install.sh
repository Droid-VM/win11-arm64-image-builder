#!/usr/bin/env bash
# =====================================================================
# 03-run-install.sh  (Apple Silicon Mac, qemu HVF 原生加速)
# 跑無人值守安裝 -> 第一次開機(testsigning 已在 BCD-Template) -> 桌面 ->
# FirstLogon(裝驅動、debloat、TRIM) -> 自動關機。產出 ../win11-droidvm.qcow2。
# target 碟啟用 discard=unmap：guest TRIM 會即時釋放 qcow2 cluster。
# 需求：brew install qemu
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
[ -f "$ROOT/load-env.sh" ] && . "$ROOT/load-env.sh"   # 自動載入 .env

SETUP_ISO="${SETUP_ISO:-$ROOT/win11-droidvm-setup.iso}"
QCOW="${QCOW:-$ROOT/win11-droidvm.qcow2}"
DISK_SIZE="${DISK_SIZE:-40G}"; MEM="${MEM:-8G}"; SMP="${SMP:-6}"
DISPLAY_OPT="${DISPLAY_OPT:--vnc 127.0.0.1:5}"   # Mac 內建螢幕共享佔 :0，用 :5

[ -f "$SETUP_ISO" ] || { echo "缺少 setup ISO: $SETUP_ISO, 先跑 02-make-iso.sh"; exit 1; }
command -v qemu-system-aarch64 >/dev/null || { echo "需要 qemu：brew install qemu"; exit 1; }

BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
CODE=""; for c in "$BREW/share/qemu/edk2-aarch64-code.fd" /usr/local/share/qemu/edk2-aarch64-code.fd; do [ -f "$c" ] && CODE="$c" && break; done
[ -n "$CODE" ] || { echo "找不到 edk2-aarch64-code.fd（brew install qemu）"; exit 1; }
VARS="$ROOT/edk2-arm-vars.fd"; [ -f "$VARS" ] || dd if=/dev/zero of="$VARS" bs=1m count=64 2>/dev/null
[ -f "$QCOW" ] || qemu-img create -f qcow2 "$QCOW" "$DISK_SIZE"

QMP="$ROOT/qmp.sock"; rm -f "$QMP"
echo "[qemu] HVF accel, display=${DISPLAY_OPT} (VNC: localhost:5905)"
# 開機順序：安裝媒體 bootindex=0（先），目標磁碟 bootindex=1。
#   首次：磁碟空 -> 安裝媒體的「Press any key to boot from CD」-> 點擊器前 28 秒按鍵
#         -> 進 Setup。（若反過來讓空磁碟先，edk2 開機失敗會停在 UEFI 前頁，不會 fallthrough。）
#   套用映像後 reboot：點擊器已過按鍵窗 -> CD 提示逾時 -> fallthrough 到磁碟 -> Windows。
qemu-system-aarch64 \
  -machine virt,accel=hvf,gic-version=3,highmem=on \
  -cpu host -smp "$SMP" -m "$MEM" \
  -drive "if=pflash,format=raw,readonly=on,file=$CODE" \
  -drive "if=pflash,format=raw,file=$VARS" \
  -device ramfb -device qemu-xhci,id=xhci -device usb-kbd -device usb-tablet \
  -device virtio-blk-pci,drive=target,bootindex=1 \
  -drive "if=none,id=target,file=$QCOW,format=qcow2,cache=writeback,discard=unmap,detect-zeroes=unmap" \
  -device usb-storage,bus=xhci.0,drive=instmedia,removable=on,bootindex=0 \
  -drive "if=none,id=instmedia,file=$SETUP_ISO,format=raw,media=cdrom" \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -rtc base=localtime -qmp "unix:$QMP,server,nowait" \
  $DISPLAY_OPT &
QEMU_PID=$!

# 後備：偵測驅動簽章提示並點「Install anyway」（憑證已於 specialize 匯入，
# 正常不該跳；此為保險）
python3 "$HERE/auto-click-prompt.py" "$QMP" >"$ROOT/clicker.log" 2>&1 &
CLICK_PID=$!

wait "$QEMU_PID"
kill "$CLICK_PID" 2>/dev/null || true
echo "[qemu] 安裝完成、guest 已關機 -> $QCOW"
