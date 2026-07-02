# =====================================================================
# windows_build.ps1 — entry point for Route A (x64 Windows). Edit the variables below to your own, then right-click "Run as administrator",
#   Requirements: x64 Windows (administrator), built-in dism/bcdboot/diskpart, qemu-img (QEMU for Windows on PATH).
#   Usage:  powershell -ExecutionPolicy Bypass -File windows_build.ps1
# =====================================================================
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell "-NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$env:SRC_ISO     = "C:\Users\USER\Documents\DroidVMBuild\SW_DVD9_Win_Pro_11_25H2_Arm64_English_Pro_Ent_EDU_N_MLF_X24-13111.ISO"
$env:DRIVERS_DIR = "https://github.com/HuJK/gunyah-guest-drivers-windows/releases/download/dev/gunyah-arm64-drivers.zip"
# $env:IMAGE_INDEX = "1"
$env:OUT_QCOW    = "C:\Users\USER\Documents\DroidVMBuild\win11-droidvm-final.qcow2"

$env:DVM_USERNAME = "USER"        # Name of the local administrator account to create
$env:DVM_PASSWORD = "DroidVM"     # Password (an empty password blocks RDP/SSH network logins)
$env:SSH_PUBKEY  = "ssh-ed25519 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA root@ReplaceMe"
$env:DISK_SIZE_MB = "40960"
# $env:COMPRESS = "1"   # ship a compressed qcow2 (crosvm can't read it directly; DroidVM import/pre-flight decompresses)

$env:DRIVER_DIR     = "ZIP/drivers"                                       # Directory containing each driver subfolder
$env:DRIVER_INSTALL = "NetKVM rdmapool pvmpower vioinput viostor vioscsi" # Install only these (empty = all); must include the viostor/vioscsi boot drivers
$env:DRIVER_CERT    = "ZIP/DroidVM_Test.cer"                              # Specify signing certificate (empty = auto-extract from .cat)

$env:OPENSSH_SRC = "https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-ARM64-v10.0.0.0.msi"

$env:PATH        = "C:\Program Files\qemu;" + $env:PATH

Write-Host "==== DroidVM Windows builder (DISM offline driver injection) ====" -ForegroundColor Cyan
& "$PSScriptRoot\windows\build.ps1"
