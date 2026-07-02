#!/bin/bash
# patch-esp-bcd.sh — runs inside a Colima container: offline, add testsigning to the "installed system's" ESP BCD.
# Why it is needed: when bcdboot creates the BCD it uses a brand-new osloader object, and does not carry over the
# testsigning/nointegritychecks we patched into BCD-Template (testing shows the built BCD has 0 hits). Without testsigning,
# on first boot winload blocks the self-signed viostor (boot-critical storage driver) -> INACCESSIBLE_BOOT_DEVICE -> reboot loop.
# So patch this BCD offline "after applying the image and before the first boot into the system".
#   Usage (called by 03): docker run -v macos:/work ... droidvm-patcher bash /work/patch-esp-bcd.sh /work/files/win11-droidvm.qcow2
set -euo pipefail
QCOW="${1:?qcow2 path (container path, e.g. /work/win11-droidvm.qcow2)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Converting the whole qcow2 -> raw needs several GB. If the Colima VM disk is full it will I/O error here (the BCD cannot be patched -> reboot loop).
avail=$(df -Pk /tmp | awk 'NR==2{print $4}')
[ "${avail:-0}" -ge 10000000 ] || echo "[bcd] Warning: container /tmp only has $((avail/1024/1024))GB left; insufficient space will fail the conversion. Rebuild Colima: colima delete -f && colima start --disk 120"

echo "[bcd] qcow2 -> raw"
qemu-img convert -f qcow2 -O raw "$QCOW" /tmp/d.raw
kpartx -av /tmp/d.raw >/dev/null; sleep 1
LP=$(ls /dev/mapper/ | grep -E 'loop[0-9]+p1$' | head -1 | sed 's/p1$//')
[ -n "$LP" ] || { echo "[bcd] cannot find ESP partition"; exit 1; }
mkdir -p /mnt/esp
mount -t vfat "/dev/mapper/${LP}p1" /mnt/esp
BCD=/mnt/esp/EFI/Microsoft/Boot/BCD
[ -f "$BCD" ] || { echo "[bcd] cannot find $BCD"; umount /mnt/esp; kpartx -d /tmp/d.raw; exit 1; }
before=$(hivexregedit --export "$BCD" '\Objects' 2>/dev/null | grep -ic 16000049 || true)
python3 "$HERE/bcd-testsigning.py" "$BCD"
after=$(hivexregedit --export "$BCD" '\Objects' 2>/dev/null | grep -ic 16000049 || true)
echo "[bcd] testsigning elements: $before -> $after"
umount /mnt/esp; kpartx -d /tmp/d.raw >/dev/null
# Abort if not patched (do not write back a BCD without testsigning -> otherwise 03 continues to Phase B and then reboot loops)
[ "${after:-0}" -gt 0 ] || { echo "[bcd] failed: BCD still has no testsigning, aborting"; rm -f /tmp/d.raw; exit 1; }
echo "[bcd] raw -> qcow2 (overwrite)"
qemu-img convert -f raw -O qcow2 /tmp/d.raw "$QCOW"
rm -f /tmp/d.raw
echo "[bcd] done"
