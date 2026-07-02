#!/bin/bash
# patch-esp-bcd.sh — 在 Colima 容器內跑：離線把「已安裝系統」的 ESP BCD 補上 testsigning。
# 為什麼需要：bcdboot 建 BCD 時會用全新的 osloader 物件，不會把我們 patch 進 BCD-Template 的
# testsigning/nointegritychecks 帶過去（實測 build 出來的 BCD 是 0 hits）。少了 testsigning，
# 第一次開機 winload 會擋掉自簽的 viostor(開機關鍵儲存驅動) -> INACCESSIBLE_BOOT_DEVICE -> reboot loop。
# 故在「套用映像後、第一次開進系統前」離線補這個 BCD。
#   用法（03 呼叫）：docker run -v macos:/work ... droidvm-patcher bash /work/patch-esp-bcd.sh /work/files/win11-droidvm.qcow2
set -euo pipefail
QCOW="${1:?qcow2 path (container path, e.g. /work/win11-droidvm.qcow2)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[bcd] qcow2 -> raw"
qemu-img convert -f qcow2 -O raw "$QCOW" /tmp/d.raw
kpartx -av /tmp/d.raw >/dev/null; sleep 1
LP=$(ls /dev/mapper/ | grep -E 'loop[0-9]+p1$' | head -1 | sed 's/p1$//')
[ -n "$LP" ] || { echo "[bcd] 找不到 ESP 分割"; exit 1; }
mkdir -p /mnt/esp
mount -t vfat "/dev/mapper/${LP}p1" /mnt/esp
BCD=/mnt/esp/EFI/Microsoft/Boot/BCD
[ -f "$BCD" ] || { echo "[bcd] 找不到 $BCD"; umount /mnt/esp; kpartx -d /tmp/d.raw; exit 1; }
before=$(hivexregedit --export "$BCD" '\Objects' 2>/dev/null | grep -ic 16000049 || true)
python3 "$HERE/bcd-testsigning.py" "$BCD"
after=$(hivexregedit --export "$BCD" '\Objects' 2>/dev/null | grep -ic 16000049 || true)
echo "[bcd] testsigning elements: $before -> $after"
umount /mnt/esp; kpartx -d /tmp/d.raw >/dev/null
echo "[bcd] raw -> qcow2 (overwrite)"
qemu-img convert -f raw -O qcow2 /tmp/d.raw "$QCOW"
rm -f /tmp/d.raw
echo "[bcd] done"
