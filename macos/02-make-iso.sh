#!/usr/bin/env bash
# =====================================================================
# 02-make-iso.sh  (在 Apple Silicon Mac 執行)
# 用 build.sh 解析好的 Win11 ARM64 ISO + 驅動 + testsigning BCD，封裝無人值守安裝 ISO
# （注入：autounattend、$WinpeDriver$ 開機驅動、DRIVER_INSTALL 指定驅動 + DRIVER_CERT 到 $OEM$、
#  安裝媒體 testsigning BCD、install.wim 的 testsigning BCD-Template）。
# 需求：brew install wimlib xorriso
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="${FILES:-$HERE/files}"; mkdir -p "$FILES"   # 中間檔都放 macos/files

# 檔案類變數由 build.sh 解析並 export（URL 已下載到 files/、zip 已解壓、皆為絕對路徑）。
# 若要單獨執行本檔，請自行先 export 這些絕對路徑（或改用 build_runme.sh）。
: "${SRC_ISO:?SRC_ISO 未設 — 請透過 build_runme.sh / build.sh 執行}"
: "${DRIVER_DIR:?DRIVER_DIR 未設}"
: "${BCD_PATCHED:?BCD_PATCHED 未設}"
: "${BCD_TEMPLATE:?BCD_TEMPLATE 未設}"
OUT_ISO="${OUT_ISO:-$FILES/win11-droidvm-setup.iso}"
WINPE_DRIVERS="${WINPE_DRIVERS:-viostor vioscsi}"
SWM_SIZE_MB="${SWM_SIZE_MB:-3800}"
DRIVER_INSTALL="${DRIVER_INSTALL:-}"   # 要安裝的驅動子資料夾（空=全部）
DRIVER_CERT="${DRIVER_CERT:-}"         # 指定簽章憑證（空=從要裝的驅動 .cat 自動萃取）
IMAGE_INDEX="${IMAGE_INDEX:-1}"        # 由 build.sh 偵測/選定後傳入；注入 autounattend 的 /IMAGE/INDEX
USERNAME="${USERNAME:-USER}"           # 帳號名（注入 autounattend）
PASSWORD="${PASSWORD:-}"               # 密碼（注入 autounattend；空=無密碼）
SSH_PUBKEY="${SSH_PUBKEY:-}"           # SSH 公鑰（寫成 C:\DroidVM\authorized_keys；空=不佈署金鑰）
OPENSSH_SRC="${OPENSSH_SRC:-}"         # 已解析的 OpenSSH 安裝檔路徑（空=不裝 SSH）

for f in "$SRC_ISO" "$BCD_PATCHED" "$BCD_TEMPLATE" "$HERE/autounattend.xml" "$HERE/debloat.ps1" "$HERE/setup-ssh.ps1"; do
  [ -e "$f" ] || { echo "缺少：$f"; exit 1; }
done
[ -d "$DRIVER_DIR" ] || { echo "缺少驅動資料夾: $DRIVER_DIR"; exit 1; }
for t in xorriso wimlib-imagex; do command -v "$t" >/dev/null || { echo "需要 $t, 請 brew install wimlib xorriso"; exit 1; }; done
echo "SRC_ISO=$SRC_ISO  OUT_ISO=$OUT_ISO"

WORK="$(mktemp -d)"; MNT=""; DEV=""
cleanup(){ [ -n "$DEV" ] && hdiutil detach "$DEV" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

ATTACH="$(hdiutil attach -readonly -nobrowse -noverify "$SRC_ISO")"
DEV="$(echo "$ATTACH" | grep -oE '/dev/disk[0-9]+' | head -1)"
MNT="$(echo "$ATTACH" | grep -oE '/Volumes/.*' | head -1)"
[ -n "$MNT" ] && [ -f "$MNT/sources/install.wim" ] || { echo "掛載失敗或找不到 install.wim"; exit 1; }
echo "[mount] $MNT"

mkdir -p "$WORK/WinpeDriver" "$WORK/OEM/DroidVM"
# 注入 autounattend token。用 perl 做「字面」取代並 XML-escape 帳密：
# 避免 bash ${//} 在新版把 & 當成 match、以及 sed 的 /&\ 雷，也保證帳密含 &<>" 時 XML 仍合法。
UA_IMAGE_INDEX="$IMAGE_INDEX" UA_USERNAME="$USERNAME" UA_PASSWORD="$PASSWORD" \
perl -pe '
  BEGIN { for my $k (qw(UA_USERNAME UA_PASSWORD)) {
    $ENV{$k} =~ s/&/&amp;/g; $ENV{$k} =~ s/</&lt;/g; $ENV{$k} =~ s/>/&gt;/g; $ENV{$k} =~ s/"/&quot;/g; } }
  s/\@\@IMAGE_INDEX\@\@/$ENV{UA_IMAGE_INDEX}/g;
  s/\@\@USERNAME\@\@/$ENV{UA_USERNAME}/g;
  s/\@\@PASSWORD\@\@/$ENV{UA_PASSWORD}/g;
' "$HERE/autounattend.xml" > "$WORK/autounattend.xml"
for d in $WINPE_DRIVERS; do
  [ -d "$DRIVER_DIR/$d" ] && cp -R "$DRIVER_DIR/$d" "$WORK/WinpeDriver/$d" || echo "  [warn] 開機驅動 $d 不存在！"
done
cp "$HERE/debloat.ps1" "$WORK/OEM/DroidVM/debloat.ps1"

# SSH：setup 腳本一律放（沒 installer 會自我略過）；OpenSSH 安裝檔 + 公鑰視情況放。
cp "$HERE/setup-ssh.ps1" "$WORK/OEM/DroidVM/setup-ssh.ps1"
if [ -n "$OPENSSH_SRC" ] && [ -f "$OPENSSH_SRC" ]; then
  cp "$OPENSSH_SRC" "$WORK/OEM/DroidVM/$(basename "$OPENSSH_SRC")"
  echo "[ssh] staged $(basename "$OPENSSH_SRC")"
else
  echo "[ssh] OPENSSH_SRC 空 -> 不裝 SSH（僅建帳號）"
fi
if [ -n "$SSH_PUBKEY" ]; then
  printf '%s\n' "$SSH_PUBKEY" > "$WORK/OEM/DroidVM/authorized_keys"
  echo "[ssh] staged authorized_keys"
fi

# 只複製「指定要安裝」的驅動（DRIVER_INSTALL 空=全部）到 $OEM$ -> C:\DroidVM\drivers
mkdir -p "$WORK/OEM/DroidVM/drivers"
if [ -n "$DRIVER_INSTALL" ]; then
  for d in $DRIVER_INSTALL; do
    [ -d "$DRIVER_DIR/$d" ] && cp -R "$DRIVER_DIR/$d" "$WORK/OEM/DroidVM/drivers/$d" \
      || echo "  [warn] 要安裝的驅動 $d 不存在於 $DRIVER_DIR"
  done
else
  cp -R "$DRIVER_DIR/"* "$WORK/OEM/DroidVM/drivers/"
fi

# 憑證：匯入指定的 DRIVER_CERT -> Root/TrustedPublisher（後安裝零提示）。
# 沒指定就退回從「要安裝的那些驅動」的 .cat 自動萃取所有唯一簽章者憑證。
mkdir -p "$WORK/OEM/DroidVM/certs"
if [ -n "$DRIVER_CERT" ] && [ -f "$DRIVER_CERT" ]; then
  cp "$DRIVER_CERT" "$WORK/OEM/DroidVM/certs/$(basename "$DRIVER_CERT")"
  echo "[cert] 用指定的 DRIVER_CERT: $(basename "$DRIVER_CERT")"
else
  SEEN="$(mktemp)"; ncert=0
  for cat in "$WORK/OEM/DroidVM/drivers"/*/*.cat; do
    [ -f "$cat" ] || continue
    # 一個 .cat 可能含多張憑證（leaf+chain），逐張拆出、用指紋去重
    openssl pkcs7 -inform DER -in "$cat" -print_certs 2>/dev/null | awk '
      /-----BEGIN CERTIFICATE-----/{n++} n{print > ("'"$SEEN"'.c" n)}'
    for pem in "$SEEN".c*; do
      [ -f "$pem" ] || continue
      fp="$(openssl x509 -in "$pem" -noout -fingerprint -sha1 2>/dev/null | sed 's/.*=//;s/://g')"
      [ -n "$fp" ] || { rm -f "$pem"; continue; }
      if ! grep -qx "$fp" "$SEEN"; then
        echo "$fp" >> "$SEEN"
        openssl x509 -in "$pem" -out "$WORK/OEM/DroidVM/certs/$fp.cer" 2>/dev/null && ncert=$((ncert+1))
      fi
      rm -f "$pem"
    done
  done
  echo "[cert] 從要安裝的驅動 .cat 萃取 $ncert 張憑證"
  rm -f "$SEEN"
fi
cp "$BCD_PATCHED" "$WORK/bcd"

echo "[wim] 複製 install.wim + 注入 patched BCD-Template（testsigning）..."
cp "$MNT/sources/install.wim" "$WORK/install.wim"; chmod u+w "$WORK/install.wim"
wimlib-imagex update "$WORK/install.wim" 2 \
  --command="add \"$BCD_TEMPLATE\" /Windows/System32/config/BCD-Template" >/dev/null
echo "[wim] 切割 install.wim ..."
wimlib-imagex split "$WORK/install.wim" "$WORK/install.swm" "$SWM_SIZE_MB"

GRAFT=( '-graft-points'
  "/=$MNT"
  "/autounattend.xml=$WORK/autounattend.xml"
  '/$WinpeDriver$/='"$WORK/WinpeDriver/"
  '/droidvm-drivers/='"$WORK/OEM/DroidVM/drivers/"
  '/sources/$OEM$/$1/DroidVM/='"$WORK/OEM/DroidVM/"
  "/efi/microsoft/boot/bcd=$WORK/bcd"
)
for swm in "$WORK"/install*.swm; do GRAFT+=( "/sources/$(basename "$swm")=$swm" ); done

echo "[iso] 產生 $OUT_ISO ..."
  # 用「會提示」的 efisys.bin（含「Press any key to boot from CD」）。配合 03 的
  # 安裝媒體 bootindex=0：首次開機點擊器按鍵 -> 進 Setup；套用映像後的 reboot 不再按
  # -> 提示逾時 -> fallthrough 到已可開機的磁碟（bootindex=1）-> Windows。避免重裝迴圈。
xorriso -as mkisofs -iso-level 3 -J -joliet-long -R -V "WIN11ARM_DROIDVM" \
  -m "$MNT/sources/install.wim" -m "$MNT/efi/microsoft/boot/bcd" \
  -e efi/microsoft/boot/efisys.bin -no-emul-boot \
  -o "$OUT_ISO" "${GRAFT[@]}"
echo "完成：$OUT_ISO"
