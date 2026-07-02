# =====================================================================
# build_runme.ps1 — entry point for Route A (x64 Windows). Edit the variables below to your own, then right-click "Run as administrator",
#   or run this file directly (it will auto-elevate). File-type variables accept a "URL" (auto-downloaded to files\) or a "local path"; zips are auto-extracted.
#   Drivers are injected offline via DISM (no boot required, no signature prompt).
#   Requirements: x64 Windows (administrator), built-in dism/bcdboot/diskpart, qemu-img (QEMU for Windows on PATH).
#   Usage:  powershell -ExecutionPolicy Bypass -File windows\build_runme.ps1
# =====================================================================
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell "-NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# --- Required: Win11 ARM64 ISO (URL or local path) ---
$env:SRC_ISO     = "C:\Users\USER\Documents\DroidVMBuild\SW_DVD9_Win_Pro_11_25H2_Arm64_English_Pro_Ent_EDU_N_MLF_X24-13111.ISO"

# --- Required: driver zip source (URL or local zip / folder); the ZIP/ below is its extracted root directory ---
$env:DRIVERS_DIR = "https://github.com/Droid-VM/gunyah-guest-drivers-windows/releases/download/dev/gunyah-arm64-drivers.zip"

# --- install.wim edition index: leave empty = build.ps1 lists editions for you to choose; or enter a number (e.g. 1) ---
# $env:IMAGE_INDEX = "1"

# --- Output ---
$env:OUT_QCOW    = "C:\Users\USER\Documents\DroidVMBuild\win11-droidvm-final.qcow2"

# --- Drivers to inject offline (ZIP/ = extracted root directory of DRIVERS_DIR) ---
$env:DRIVER_DIR     = "ZIP/drivers"                                       # Directory containing each driver subfolder
$env:DRIVER_INSTALL = "NetKVM rdmapool pvmpower vioinput viostor vioscsi" # Install only these (empty = all); must include the viostor/vioscsi boot drivers
$env:DRIVER_CERT    = "ZIP/DroidVM_Test.cer"                              # Specify signing certificate (empty = auto-extract from .cat)

# --- Account / remote ---
# Use $env:DVM_USERNAME for the account name (not $env:USERNAME —— that is a Windows built-in = the current logged-in user); use $env:DVM_PASSWORD for the password.
$env:DVM_USERNAME = "USER"        # Name of the local administrator account to create
$env:DVM_PASSWORD = "DroidVM"     # Password (an empty password blocks RDP/SSH network logins)
# $env:SSH_PUBKEY  = Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub" -Raw   # SSH public key (separate multiple keys by newline; empty = password login only)
# OpenSSH installer (URL downloaded to files\ or local path); set "" to skip SSH (RDP only). Defaults to the arm64 .msi.
$env:OPENSSH_SRC = "https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-ARM64-v10.0.0.0.msi"

# --- Optional: disk size (MB) / output path override ---
# $env:DISK_SIZE_MB = "40960"

# qemu-img must be on PATH (QEMU for Windows)
$env:PATH        = "C:\Program Files\qemu;" + $env:PATH

Write-Host "==== DroidVM Windows builder (DISM offline driver injection) ====" -ForegroundColor Cyan
& "$PSScriptRoot\build.ps1"
