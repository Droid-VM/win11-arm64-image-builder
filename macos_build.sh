#!/usr/bin/env bash
# =====================================================================
# macos_build.sh — the single entry point for route B (Apple Silicon Mac).
#   Requires: brew install qemu wimlib xorriso colima docker
#   Usage:  bash macos_build.sh
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export SRC_ISO="/Users/user/Documents/DroidVMBuild/SW_DVD9_Win_Pro_11_25H2_Arm64_English_Pro_Ent_EDU_N_MLF_X24-13111.ISO"
# export IMAGE_INDEX="1"
export DRIVERS_DIR="https://github.com/HuJK/gunyah-guest-drivers-windows/releases/download/dev/gunyah-arm64-drivers.zip"

export USERNAME="USER"
export PASSWORD="DroidVM"
export SSH_PUBKEY="ssh-ed25519 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA root@ReplaceMe"
export OPENSSH_SRC="https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-ARM64-v10.0.0.0.msi"

export DISK_SIZE="40G"
export OUT_QCOW="$HERE/macos/win11-droidvm-final.qcow2"
# export COMPRESS=1   # ship a compressed qcow2 (crosvm can't read it directly; DroidVM import/pre-flight decompresses)

export BACKGROUND=false

export DRIVER_DIR="ZIP/drivers"                            # Directory containing each driver subfolder
export DRIVER_INSTALL="NetKVM rdmapool pvmpower vioinput viostor vioscsi"   # Install only these (empty = all)
export DRIVER_CERT="ZIP/DroidVM_Test.cer"                  # Signing certificate to use (empty = auto-extract from .cat)

"$HERE/macos/build.sh"
