#!/usr/bin/env bash
# =====================================================================
# 03-run-install.sh  (Apple Silicon Mac, qemu HVF native acceleration) — two-phase install
#   Phase A: boot from install media (CD) -> WinPE applies image -> Setup creates BCD -> wants reboot.
#            After detecting "apply complete" (qcow2 grows then stalls), stop qemu.
#   BCD patch: offline, add testsigning to the installed system's ESP BCD (see patch-esp-bcd.sh;
#            bcdboot does not carry over BCD-Template's testsigning; without it, the self-signed viostor on first boot
#            gets blocked -> reboot loop).
#   Phase B: boot from disk only -> specialize/OOBE/FirstLogon(install drivers/certs/SSH/RDP/debloat) -> auto shutdown.
# target disk discard=unmap: guest TRIM instantly frees qcow2 clusters. Requires: brew install qemu; BCD patch needs colima+docker.
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="${FILES:-$HERE/files}"; mkdir -p "$FILES"   # intermediate files (setup ISO / working qcow2 / NVRAM / qmp / log) all go in macos/files
# Variables are provided by build.sh / macos_build.sh (environment variables).

SETUP_ISO="${SETUP_ISO:-$FILES/win11-droidvm-setup.iso}"
QCOW="${QCOW:-$FILES/win11-droidvm.qcow2}"
DISK_SIZE="${DISK_SIZE:-40G}"; MEM="${MEM:-8G}"; SMP="${SMP:-6}"
# Display mode: BACKGROUND=true(default)=headless(VNC); false=native qemu window(-display cocoa, must run in a Terminal on the Mac desktop).
# Setting DISPLAY_OPT directly fully overrides. auto-click goes through QMP, works in both modes.
BACKGROUND="${BACKGROUND:-true}"
if [ -z "${DISPLAY_OPT:-}" ]; then
  case "$BACKGROUND" in
    false|0|no) DISPLAY_OPT="-display cocoa" ;;
    *)          DISPLAY_OPT="-vnc 127.0.0.1:5" ;;   # Mac built-in screen sharing uses :0, use :5 = port 5905
  esac
fi

[ -f "$SETUP_ISO" ] || { echo "Missing setup ISO: $SETUP_ISO, run 02-make-iso.sh first"; exit 1; }
command -v qemu-system-aarch64 >/dev/null || { echo "qemu required: brew install qemu"; exit 1; }

BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
CODE=""; for c in "$BREW/share/qemu/edk2-aarch64-code.fd" /usr/local/share/qemu/edk2-aarch64-code.fd; do [ -f "$c" ] && CODE="$c" && break; done
[ -n "$CODE" ] || { echo "Cannot find edk2-aarch64-code.fd (brew install qemu)"; exit 1; }
# Every build uses a fresh working disk + NVRAM (a dirty disk/old NVRAM from a previous interruption causes a Phase B reboot loop)
VARS="$FILES/edk2-arm-vars.fd"; rm -f "$VARS"; dd if=/dev/zero of="$VARS" bs=1m count=64 2>/dev/null
rm -f "$QCOW"; qemu-img create -f qcow2 "$QCOW" "$DISK_SIZE" >/dev/null
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

# start_qemu <cd|disk>: cd = install media(bootindex0)+disk(1); disk = disk only(bootindex0). Also starts auto-click.
start_qemu() {
  local mode="$1"; rm -f "$QMP"
  if [ "$mode" = cd ]; then
    # -no-reboot: when Setup finishes applying the image and reboots, qemu exits directly, avoiding the "CD prompt times out -> unpatched disk
    # fails to boot -> reset" loop. Equivalent to the user's "shut down as soon as it boots", but uses qemu's built-in flag, no boot img needed.
    qemu-system-aarch64 "${QEMU_COMMON[@]}" -no-reboot \
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

# ---- Phase A: boot from install media, apply image ----
echo "[qemu] === Phase A: boot from install media, apply image ==="
echo "[qemu]   ⓘ After the image is applied, Setup reboots; -no-reboot makes qemu exit directly -> BCD patch. Do not interrupt this phase."
start_qemu cd
# Primary signal: -no-reboot makes qemu exit when Setup finishes applying the image and reboots (within seconds, screen no longer loops).
# Fallback: in case reboot does not trigger exit for some reason, still use "qcow2 grows then stalls for STALL seconds" to determine apply is complete.
MIN_APPLIED=$((3 * 1024 * 1024 * 1024)); STALL=75; MAXA=2400
t0=$(date +%s); last=0; laststamp=$t0
while :; do
  sleep 10
  if ! ps -p "$QEMU_PID" >/dev/null 2>&1; then echo "[qemu] image apply complete (reboot triggered -no-reboot exit)"; break; fi
  sz=$(stat -f %z "$QCOW" 2>/dev/null || echo 0); now=$(date +%s)
  [ "$sz" -gt "$last" ] && { last=$sz; laststamp=$now; }
  if [ "$sz" -gt "$MIN_APPLIED" ] && [ $((now - laststamp)) -ge "$STALL" ]; then
    echo "[qemu] image apply complete (size-stall fallback detection, $((sz/1048576))MB)"; break
  fi
  [ $((now - t0)) -ge "$MAXA" ] && { echo "[qemu] Phase A timed out"; stop_qemu; exit 1; }
done
stop_qemu
sz=$(stat -f %z "$QCOW" 2>/dev/null || echo 0)
[ "$sz" -gt "$MIN_APPLIED" ] || { echo "[qemu] Phase A did not apply the image (qcow2 is only $((sz/1048576))MB)"; exit 1; }

# ---- BCD patch: offline add testsigning to ESP BCD (using a Colima container) ----
echo "[bcd] === offline add ESP BCD testsigning ==="
command -v docker >/dev/null || { echo "docker missing (needed by BCD patch) — brew install colima docker"; exit 1; }
colima status >/dev/null 2>&1 || colima start
docker build -q -t droidvm-patcher "$HERE" >/dev/null
# Mount macos/ -> /work (scripts in /work, intermediate files in /work/files)
docker run --rm --privileged -v "$HERE:/work" droidvm-patcher \
  bash /work/patch-esp-bcd.sh "/work/files/$(basename "$QCOW")"

# ---- Phase B: boot from disk only, run through OOBE/FirstLogon ----
echo "[qemu] === Phase B: boot from disk, run through OOBE/FirstLogon (auto shutdown) ==="
start_qemu disk
wait "$QEMU_PID" 2>/dev/null || true
kill "${CLICK_PID:-}" 2>/dev/null || true
echo "[qemu] install complete, guest has shut down -> $QCOW"
