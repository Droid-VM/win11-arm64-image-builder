#!/usr/bin/env bash
# =====================================================================
# 02-make-iso.sh  (在 Apple Silicon Mac 執行)
# 用 inputs/ 的 Win11 ARM64 ISO + 驅動 + linux 端產的 patches/，
# 封裝無人值守安裝 ISO（注入：autounattend、$WinpeDriver$ 開機驅動、
# 全驅動 $OEM$、安裝媒體 testsigning BCD、install.wim 的 testsigning BCD-Template）。
# 需求：brew install wimlib xorriso
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
IN="$ROOT/inputs"; PATCHES="$ROOT/patches"
[ -f "$ROOT/load-env.sh" ] && . "$ROOT/load-env.sh"   # 自動載入 .env

SRC_ISO="${SRC_ISO:-$(ls "$IN"/*arm64*dvd*.iso "$IN"/*ARM64*.iso "$IN"/*.iso 2>/dev/null | head -1 || true)}"
OUT_ISO="${OUT_ISO:-$ROOT/win11-droidvm-setup.iso}"
BCD_PATCHED="${BCD_PATCHED:-$PATCHES/bcd-patched}"
BCD_TEMPLATE="${BCD_TEMPLATE:-$PATCHES/bcd-template-patched}"
WINPE_DRIVERS="${WINPE_DRIVERS:-viostor vioscsi}"
SWM_SIZE_MB="${SWM_SIZE_MB:-3800}"

# --- 驅動來源 DRIVERS_DIR：① GitHub repo URL ② 本地 .zip ③ 本地資料夾 ---
# 預設：本機 inputs/drivers 或 inputs/drivers.zip 優先，否則用 repo URL 抓 dev release。
DRIVERS_DIR="${DRIVERS_DIR:-}"
if [ -z "$DRIVERS_DIR" ]; then
  if   [ -d "$IN/drivers" ];     then DRIVERS_DIR="$IN/drivers"
  elif [ -f "$IN/drivers.zip" ]; then DRIVERS_DIR="$IN/drivers.zip"
  else                                DRIVERS_DIR="https://github.com/HuJK-Data/gunyah-guest-drivers-windows"
  fi
fi
# URL 或 .zip -> 正規化成 inputs/drivers.zip（下載 or 複製）；資料夾則原樣使用
case "$DRIVERS_DIR" in
  https://*|http://*)
    if [ ! -d "$IN/drivers" ]; then
      repo="$(printf '%s' "$DRIVERS_DIR" | sed -E 's#^https?://github.com/##; s#\.git$##; s#/+$##')"
      api="https://api.github.com/repos/$repo/releases/tags/dev"
      echo "[drivers] 解析 dev release: $api"
      mkdir -p "$IN"
      # 用一般手段抓資產 url，不依賴 gh；repo/release 需為公開
      json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$api" || true)"
      [ -n "$json" ] || { echo "缺: 取不到 release JSON, repo/release 需為公開: $api"; exit 1; }
      # 抽出第一個 .zip 資產的下載 url：jq -> python3 -> grep/sed（普通人不一定有 jq）
      if command -v jq >/dev/null 2>&1; then
        url="$(printf '%s' "$json" | jq -r '[.assets[]|select(.name|endswith(".zip"))][0].browser_download_url // empty')"
      elif command -v python3 >/dev/null 2>&1; then
        url="$(printf '%s' "$json" | python3 -c 'import sys,json;a=[x["browser_download_url"] for x in json.load(sys.stdin).get("assets",[]) if x["name"].endswith(".zip")];print(a[0] if a else "")')"
      else
        url="$(printf '%s' "$json" | grep -o '"browser_download_url"[^"]*"[^"]*\.zip"' | head -1 | sed -E 's/.*"(https[^"]*\.zip)".*/\1/')"
      fi
      [ -n "$url" ] || { echo "缺：dev release 沒有 .zip 資產"; exit 1; }
      echo "[drivers] 下載 $url -> inputs/drivers.zip"
      curl -fL "$url" -o "$IN/drivers.zip"
    fi
    DRIVERS_DIR="$IN/drivers" ;;
  *.zip)
    if [ ! -d "$IN/drivers" ]; then
      mkdir -p "$IN"
      [ "$DRIVERS_DIR" -ef "$IN/drivers.zip" ] 2>/dev/null || cp -f "$DRIVERS_DIR" "$IN/drivers.zip"
    fi
    DRIVERS_DIR="$IN/drivers" ;;
esac
# 從 inputs/drivers.zip 解開成 inputs/drivers/（zip 頂層即 drivers/）
if [ "$DRIVERS_DIR" = "$IN/drivers" ] && [ ! -d "$IN/drivers" ] && [ -f "$IN/drivers.zip" ]; then
  echo "[drivers] 解開 inputs/drivers.zip -> inputs/drivers/"
  ( cd "$IN" && unzip -q -o drivers.zip )
fi

# 憑證後備（通常免設；主要從驅動 .cat 自動萃取）。放在驅動解開「之後」才 glob 得到。
CERT="${CERT:-$(ls "$DRIVERS_DIR"/*.cer "$IN"/drivers/*.cer "$IN"/*.cer 2>/dev/null | head -1 || true)}"

for f in "$SRC_ISO" "$BCD_PATCHED" "$BCD_TEMPLATE" "$HERE/autounattend.xml" "$HERE/debloat.ps1"; do
  [ -e "$f" ] || { echo "缺少：$f"; exit 1; }
done
[ -d "$DRIVERS_DIR" ] || { echo "缺少驅動資料夾: $DRIVERS_DIR"; exit 1; }
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
cp "$HERE/autounattend.xml" "$WORK/autounattend.xml"
for d in $WINPE_DRIVERS; do
  [ -d "$DRIVERS_DIR/$d" ] && cp -R "$DRIVERS_DIR/$d" "$WORK/WinpeDriver/$d" || echo "  [warn] 開機驅動 $d 不存在！"
done
cp -R "$DRIVERS_DIR" "$WORK/OEM/DroidVM/drivers"
cp "$HERE/debloat.ps1" "$WORK/OEM/DroidVM/debloat.ps1"

# 憑證：直接從「實際簽署驅動的 .cat」萃取所有唯一簽章者憑證 -> 匯入 TrustedPublisher/Root
# 後安裝零提示。不可只依賴單一外部 .cer：實測不同驅動可能用不同（同名不同金鑰）測試憑證
# （例：viorng 用 CPDK 另簽，與其餘 7 個不同），漏掉就會跳「無法驗證發行者」。
mkdir -p "$WORK/OEM/DroidVM/certs"
SEEN="$(mktemp)"; ncert=0
for cat in "$DRIVERS_DIR"/*/*.cat; do
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
echo "[cert] 從驅動 .cat 萃取 $ncert 張唯一簽章者憑證"
# 萃取失敗才退回外部 CERT（保險）
if [ "$ncert" -eq 0 ] && [ -n "$CERT" ] && [ -f "$CERT" ]; then
  cp "$CERT" "$WORK/OEM/DroidVM/certs/fallback.cer"; echo "[cert] 退回外部 CERT"
fi
rm -f "$SEEN"
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
  '/droidvm-drivers/='"$DRIVERS_DIR/"
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
