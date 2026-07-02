#!/usr/bin/env bash
# =====================================================================
# 03-run-install.sh  (Apple Silicon Mac, qemu HVF 原生加速) — 兩階段安裝
#   Phase A：安裝媒體(CD)開機 -> WinPE 套用映像 -> Setup 建 BCD -> 要 reboot。
#            偵測「套用完成」(qcow2 成長後停滯) 後停 qemu。
#   BCD patch：離線把已安裝系統的 ESP BCD 補上 testsigning（見 patch-esp-bcd.sh；
#            bcdboot 不會把 BCD-Template 的 testsigning 帶過去，少了它第一次開機自簽 viostor
#            會被擋 -> reboot loop）。
#   Phase B：只從磁碟開機 -> specialize/OOBE/FirstLogon(裝驅動/憑證/SSH/RDP/debloat) -> 自動關機。
# target 碟 discard=unmap：guest TRIM 即時釋放 qcow2 cluster。需求：brew install qemu；BCD patch 需 colima+docker。
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="${FILES:-$HERE/files}"; mkdir -p "$FILES"   # 中間檔（setup ISO / 工作 qcow2 / NVRAM / qmp / log）都放 macos/files
# 變數由 build.sh / build_runme.sh 提供（環境變數）。

SETUP_ISO="${SETUP_ISO:-$FILES/win11-droidvm-setup.iso}"
QCOW="${QCOW:-$FILES/win11-droidvm.qcow2}"
DISK_SIZE="${DISK_SIZE:-40G}"; MEM="${MEM:-8G}"; SMP="${SMP:-6}"
# 顯示模式：BACKGROUND=true(預設)=headless(VNC)；false=原生 qemu 視窗(-display cocoa，要在 Mac 桌面 Terminal 跑)。
# 直接設 DISPLAY_OPT 可完全覆蓋。auto-click 走 QMP，兩種模式都有效。
BACKGROUND="${BACKGROUND:-true}"
if [ -z "${DISPLAY_OPT:-}" ]; then
  case "$BACKGROUND" in
    false|0|no) DISPLAY_OPT="-display cocoa" ;;
    *)          DISPLAY_OPT="-vnc 127.0.0.1:5" ;;   # Mac 內建螢幕共享佔 :0，用 :5 = port 5905
  esac
fi

[ -f "$SETUP_ISO" ] || { echo "缺少 setup ISO: $SETUP_ISO, 先跑 02-make-iso.sh"; exit 1; }
command -v qemu-system-aarch64 >/dev/null || { echo "需要 qemu：brew install qemu"; exit 1; }

BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
CODE=""; for c in "$BREW/share/qemu/edk2-aarch64-code.fd" /usr/local/share/qemu/edk2-aarch64-code.fd; do [ -f "$c" ] && CODE="$c" && break; done
[ -n "$CODE" ] || { echo "找不到 edk2-aarch64-code.fd（brew install qemu）"; exit 1; }
VARS="$FILES/edk2-arm-vars.fd"; [ -f "$VARS" ] || dd if=/dev/zero of="$VARS" bs=1m count=64 2>/dev/null
[ -f "$QCOW" ] || qemu-img create -f qcow2 "$QCOW" "$DISK_SIZE"
QMP="$FILES/qmp.sock"
case "$DISPLAY_OPT" in *vnc*) VNC_NOTE=" (VNC: open vnc://127.0.0.1:5905)";; *) VNC_NOTE="";; esac
echo "[qemu] HVF accel, BACKGROUND=$BACKGROUND, display=${DISPLAY_OPT}${VNC_NOTE}"

QEMU_COMMON=(
  -machine virt,accel=hvf,gic-version=3,highmem=on
  -cpu host -smp "$SMP" -m "$MEM"
  -drive "if=pflash,format=raw,readonly=on,file=$CODE"
  -drive "if=pflash,format=raw,file=$VARS"
  -device ramfb -device qemu-xhci,id=xhci -device usb-kbd -device usb-tablet
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0
  -rtc base=localtime
)

# start_qemu <cd|disk>：cd = 安裝媒體(bootindex0)+磁碟(1)；disk = 只有磁碟(bootindex0)。同時起 auto-click。
start_qemu() {
  local mode="$1"; rm -f "$QMP"
  if [ "$mode" = cd ]; then
    qemu-system-aarch64 "${QEMU_COMMON[@]}" \
      -device virtio-blk-pci,drive=target,bootindex=1 \
      -drive "if=none,id=target,file=$QCOW,format=qcow2,cache=writeback,discard=unmap,detect-zeroes=unmap" \
      -device usb-storage,bus=xhci.0,drive=instmedia,removable=on,bootindex=0 \
      -drive "if=none,id=instmedia,file=$SETUP_ISO,format=raw,media=cdrom" \
      -qmp "unix:$QMP,server,nowait" $DISPLAY_OPT &
  else
    qemu-system-aarch64 "${QEMU_COMMON[@]}" \
      -device virtio-blk-pci,drive=target,bootindex=0 \
      -drive "if=none,id=target,file=$QCOW,format=qcow2,cache=writeback,discard=unmap,detect-zeroes=unmap" \
      -qmp "unix:$QMP,server,nowait" $DISPLAY_OPT &
  fi
  QEMU_PID=$!
  python3 "$HERE/auto-click-prompt.py" "$QMP" >"$FILES/clicker.log" 2>&1 &
  CLICK_PID=$!
}
stop_qemu() {
  kill "${CLICK_PID:-}" 2>/dev/null || true
  kill "${QEMU_PID:-}"  2>/dev/null || true
  wait "${QEMU_PID:-}"  2>/dev/null || true
}

# ---- Phase A：安裝媒體開機、套用映像 ----
echo "[qemu] === Phase A：安裝媒體開機、套用映像 ==="
start_qemu cd
# 等套用完成：qcow2 成長超過門檻後停滯 STALL 秒（Setup 套完映像要 reboot；此時 CD 會 loop，不會自己結束）。
MIN_APPLIED=$((3 * 1024 * 1024 * 1024)); STALL=75; MAXA=2400
t0=$(date +%s); last=0; laststamp=$t0
while :; do
  sleep 15
  sz=$(stat -f %z "$QCOW" 2>/dev/null || echo 0); now=$(date +%s)
  [ "$sz" -gt "$last" ] && { last=$sz; laststamp=$now; }
  if [ "$sz" -gt "$MIN_APPLIED" ] && [ $((now - laststamp)) -ge "$STALL" ]; then
    echo "[qemu] 映像套用完成（$((sz/1024/1024))MB，停滯 ${STALL}s）"; break
  fi
  if ! ps -p "$QEMU_PID" >/dev/null 2>&1; then echo "[qemu] Phase A qemu 提早結束"; break; fi
  [ $((now - t0)) -ge "$MAXA" ] && { echo "[qemu] Phase A 逾時"; stop_qemu; exit 1; }
done
stop_qemu

# ---- BCD patch：離線補 ESP BCD 的 testsigning（用 Colima 容器）----
echo "[bcd] === 離線補 ESP BCD testsigning ==="
command -v docker >/dev/null || { echo "缺 docker（BCD patch 需要）— brew install colima docker"; exit 1; }
colima status >/dev/null 2>&1 || colima start
docker build -q -t droidvm-patcher "$HERE" >/dev/null
# 掛 macos/ -> /work（scripts 在 /work，中間檔在 /work/files）
docker run --rm --privileged -v "$HERE:/work" droidvm-patcher \
  bash /work/patch-esp-bcd.sh "/work/files/$(basename "$QCOW")"

# ---- Phase B：只從磁碟開機、跑完 OOBE/FirstLogon ----
echo "[qemu] === Phase B：磁碟開機、跑完 OOBE/FirstLogon（會自動關機）==="
start_qemu disk
wait "$QEMU_PID" 2>/dev/null || true
kill "${CLICK_PID:-}" 2>/dev/null || true
echo "[qemu] 安裝完成、guest 已關機 -> $QCOW"
