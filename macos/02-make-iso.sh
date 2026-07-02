#!/usr/bin/env bash
# =====================================================================
# 02-make-iso.sh  (run on Apple Silicon Mac)
# Use the Win11 ARM64 ISO + drivers + testsigning BCD resolved by build.sh to package an unattended install ISO
# (Inject: autounattend, $WinpeDriver$ boot drivers, DRIVER_INSTALL selected drivers + DRIVER_CERT into $OEM$,
#  install media testsigning BCD, and the testsigning BCD-Template for install.wim).
# Requires: brew install wimlib xorriso
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="${FILES:-$HERE/files}"; mkdir -p "$FILES"   # intermediate files all go in macos/files

# File-type variables are resolved and exported by build.sh (URLs downloaded to files/, zips extracted, all absolute paths).
# To run this file standalone, export these absolute paths yourself first (or use build_runme.sh instead).
: "${SRC_ISO:?SRC_ISO not set — run via build_runme.sh / build.sh}"
: "${DRIVER_DIR:?DRIVER_DIR not set}"
: "${BCD_PATCHED:?BCD_PATCHED not set}"
: "${BCD_TEMPLATE:?BCD_TEMPLATE not set}"
OUT_ISO="${OUT_ISO:-$FILES/win11-droidvm-setup.iso}"
WINPE_DRIVERS="${WINPE_DRIVERS:-viostor vioscsi}"
SWM_SIZE_MB="${SWM_SIZE_MB:-3800}"
DRIVER_INSTALL="${DRIVER_INSTALL:-}"   # driver subfolders to install (empty=all)
DRIVER_CERT="${DRIVER_CERT:-}"         # specific signing certificate (empty=auto-extract from the .cat of drivers to install)
IMAGE_INDEX="${IMAGE_INDEX:-1}"        # passed in after build.sh detects/selects; injected into autounattend /IMAGE/INDEX
USERNAME="${USERNAME:-USER}"           # account name (injected into autounattend)
PASSWORD="${PASSWORD:-}"               # password (injected into autounattend; empty=no password)
SSH_PUBKEY="${SSH_PUBKEY:-}"           # SSH public key (written to C:\DroidVM\authorized_keys; empty=do not deploy key)
OPENSSH_SRC="${OPENSSH_SRC:-}"         # resolved OpenSSH installer path (empty=do not install SSH)

for f in "$SRC_ISO" "$BCD_PATCHED" "$BCD_TEMPLATE" "$HERE/autounattend.xml" "$HERE/debloat.ps1" "$HERE/setup-ssh.ps1"; do
  [ -e "$f" ] || { echo "Missing: $f"; exit 1; }
done
[ -d "$DRIVER_DIR" ] || { echo "Missing driver folder: $DRIVER_DIR"; exit 1; }
for t in xorriso wimlib-imagex; do command -v "$t" >/dev/null || { echo "Need $t, please brew install wimlib xorriso"; exit 1; }; done
echo "SRC_ISO=$SRC_ISO  OUT_ISO=$OUT_ISO"

WORK="$(mktemp -d)"; MNT=""; DEV=""
cleanup(){ [ -n "$DEV" ] && hdiutil detach "$DEV" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

ATTACH="$(hdiutil attach -readonly -nobrowse -noverify "$SRC_ISO")"
DEV="$(echo "$ATTACH" | grep -oE '/dev/disk[0-9]+' | head -1)"
MNT="$(echo "$ATTACH" | grep -oE '/Volumes/.*' | head -1)"
[ -n "$MNT" ] && [ -f "$MNT/sources/install.wim" ] || { echo "Mount failed or install.wim not found"; exit 1; }
echo "[mount] $MNT"

mkdir -p "$WORK/WinpeDriver" "$WORK/OEM/DroidVM"
# Inject autounattend tokens. Use perl for a literal replace and XML-escape the credentials:
# Avoids bash ${//} treating & as a match in newer versions and the sed /&\ pitfall, and keeps XML valid when credentials contain &<>".
UA_IMAGE_INDEX="$IMAGE_INDEX" UA_USERNAME="$USERNAME" UA_PASSWORD="$PASSWORD" \
perl -pe '
  BEGIN { for my $k (qw(UA_USERNAME UA_PASSWORD)) {
    $ENV{$k} =~ s/&/&amp;/g; $ENV{$k} =~ s/</&lt;/g; $ENV{$k} =~ s/>/&gt;/g; $ENV{$k} =~ s/"/&quot;/g; } }
  s/\@\@IMAGE_INDEX\@\@/$ENV{UA_IMAGE_INDEX}/g;
  s/\@\@USERNAME\@\@/$ENV{UA_USERNAME}/g;
  s/\@\@PASSWORD\@\@/$ENV{UA_PASSWORD}/g;
' "$HERE/autounattend.xml" > "$WORK/autounattend.xml"
for d in $WINPE_DRIVERS; do
  [ -d "$DRIVER_DIR/$d" ] && cp -R "$DRIVER_DIR/$d" "$WORK/WinpeDriver/$d" || echo "  [warn] boot driver $d does not exist!"
done
cp "$HERE/debloat.ps1" "$WORK/OEM/DroidVM/debloat.ps1"

# pvmpower binds to root-enumerated ROOT\PVMPOWER: the devnode must be created at first boot via SetupAPI
# (INF injection does not produce a devnode). The script is provided at the driver zip root; old zips without it are skipped (autounattend
# side also has an if-exist guard).
ZIPROOT="$(dirname "$DRIVER_DIR")"
if [ -f "$ZIPROOT/pvmpower-devnode.ps1" ]; then
  cp "$ZIPROOT/pvmpower-devnode.ps1" "$WORK/OEM/DroidVM/pvmpower-devnode.ps1"
  echo "[pvmpower] staged pvmpower-devnode.ps1"
fi

# SSH: the setup script is always staged (it self-skips when there is no installer); the OpenSSH installer + public key are staged as needed.
cp "$HERE/setup-ssh.ps1" "$WORK/OEM/DroidVM/setup-ssh.ps1"
if [ -n "$OPENSSH_SRC" ] && [ -f "$OPENSSH_SRC" ]; then
  cp "$OPENSSH_SRC" "$WORK/OEM/DroidVM/$(basename "$OPENSSH_SRC")"
  echo "[ssh] staged $(basename "$OPENSSH_SRC")"
else
  echo "[ssh] OPENSSH_SRC empty -> not installing SSH (account only)"
fi
if [ -n "$SSH_PUBKEY" ]; then
  printf '%s\n' "$SSH_PUBKEY" > "$WORK/OEM/DroidVM/authorized_keys"
  echo "[ssh] staged authorized_keys"
fi

# Copy only the drivers selected for install (DRIVER_INSTALL empty=all) to $OEM$ -> C:\DroidVM\drivers
mkdir -p "$WORK/OEM/DroidVM/drivers"
if [ -n "$DRIVER_INSTALL" ]; then
  for d in $DRIVER_INSTALL; do
    [ -d "$DRIVER_DIR/$d" ] && cp -R "$DRIVER_DIR/$d" "$WORK/OEM/DroidVM/drivers/$d" \
      || echo "  [warn] driver to install $d does not exist in $DRIVER_DIR"
  done
else
  cp -R "$DRIVER_DIR/"* "$WORK/OEM/DroidVM/drivers/"
fi

# Certificate: import the specified DRIVER_CERT -> Root/TrustedPublisher (zero prompts during later install).
# If not specified, fall back to auto-extracting all unique signer certificates from the .cat of the drivers to install.
mkdir -p "$WORK/OEM/DroidVM/certs"
if [ -n "$DRIVER_CERT" ] && [ -f "$DRIVER_CERT" ]; then
  cp "$DRIVER_CERT" "$WORK/OEM/DroidVM/certs/$(basename "$DRIVER_CERT")"
  echo "[cert] using specified DRIVER_CERT: $(basename "$DRIVER_CERT")"
else
  SEEN="$(mktemp)"; ncert=0
  for cat in "$WORK/OEM/DroidVM/drivers"/*/*.cat; do
    [ -f "$cat" ] || continue
    # One .cat may contain multiple certificates (leaf+chain); split each out and dedupe by fingerprint
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
  echo "[cert] extracted $ncert certificates from the drivers .cat"
  rm -f "$SEEN"
fi
cp "$BCD_PATCHED" "$WORK/bcd"

echo "[wim] copying install.wim + injecting patched BCD-Template (testsigning)..."
cp "$MNT/sources/install.wim" "$WORK/install.wim"; chmod u+w "$WORK/install.wim"
wimlib-imagex update "$WORK/install.wim" 2 \
  --command="add \"$BCD_TEMPLATE\" /Windows/System32/config/BCD-Template" >/dev/null
echo "[wim] splitting install.wim ..."
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

echo "[iso] generating $OUT_ISO ..."
  # Use the prompting efisys.bin (contains "Press any key to boot from CD"). Combined with 03's
  # install media bootindex=0: at first boot press a key at the prompt -> enter Setup; after applying the image the reboot does not press
  # -> prompt times out -> fallthrough to the now-bootable disk (bootindex=1) -> Windows. Avoids a reinstall loop.
xorriso -as mkisofs -iso-level 3 -J -joliet-long -R -V "WIN11ARM_DROIDVM" \
  -m "$MNT/sources/install.wim" -m "$MNT/efi/microsoft/boot/bcd" \
  -e efi/microsoft/boot/efisys.bin -no-emul-boot \
  -o "$OUT_ISO" "${GRAFT[@]}"
echo "Done: $OUT_ISO"
