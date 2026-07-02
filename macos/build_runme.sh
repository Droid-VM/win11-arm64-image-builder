#!/usr/bin/env bash
# =====================================================================
# build_runme.sh — the single entry point for route B (Apple Silicon Mac).
#   Change the variables below to your own, then run this file directly (it calls build.sh).
#   File variables accept a URL (auto-downloaded to files/) or a local path.
#   The testsigning BCD is generated automatically via a Colima container (no separate Linux needed).
#   Requires: brew install qemu wimlib xorriso colima docker
#   Usage:  bash macos/build_runme.sh
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Required: Win11 ARM64 ISO (URL or local path) ---
export SRC_ISO="/path/to/win11_arm64.iso"

# --- Required: driver zip source (URL or local zip / folder); the ZIP/ below is its extracted root directory ---
export DRIVERS_DIR="https://github.com/Droid-VM/gunyah-guest-drivers-windows/releases/download/dev/gunyah-arm64-drivers.zip"

# --- install.wim edition index: empty = detect the editions in install.wim and let you choose; or fill in a number directly (e.g. 1 = LTSC) ---
export IMAGE_INDEX=""

# --- Output ---
export OUT_QCOW="$HERE/win11-droidvm-final.qcow2"

# --- Optional: qemu parameters (leave unset to use defaults) ---
# export MEM="8G"
# export SMP="6"
# export DISK_SIZE="40G"
# Install screen display: default true = headless (view via VNC: open vnc://127.0.0.1:5905).
# Setting false opens a native qemu window so you can watch during the build -- but it must run in the Mac desktop Terminal; pure SSH will fail.
export BACKGROUND=false
# export DISPLAY_OPT="-vnc 127.0.0.1:5"   # Fully custom display parameters (overrides BACKGROUND)

# --- Drivers to install (ZIP/ = extracted root directory of DRIVERS_DIR) ---
export DRIVER_DIR="ZIP/drivers"                            # Directory containing each driver subfolder
export DRIVER_INSTALL="NetKVM rdmapool pvmpower vioinput viostor vioscsi"   # Install only these (empty = all)
export DRIVER_CERT="ZIP/DroidVM_Test.cer"                  # Signing certificate to use (empty = auto-extract from .cat)

# --- Account / remote ---
export USERNAME="USER"          # Name of the local administrator account to create
export PASSWORD="DroidVM"       # Password (an empty password blocks SSH network login)
export SSH_PUBKEY=""            # SSH public key (separate multiple keys with newlines; empty = password login only)
# OpenSSH installer (URL downloaded to files/ or a local path); empty = do not install SSH. Defaults to the arm64 .msi.
export OPENSSH_SRC="https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-ARM64-v10.0.0.0.msi"

"$HERE/build.sh"
