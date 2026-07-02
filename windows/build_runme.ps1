$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell "-NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# 檔案類變數可填「URL」（自動下載到 files\）或「本地路徑」；zip 會自動解壓到 files\。
$env:SRC_ISO     = "C:\Users\USER\Documents\DroidVMBuild\SW_DVD9_Win_Pro_11_25H2_Arm64_English_Pro_Ent_EDU_N_MLF_X24-13111.ISO"
# 驅動：直接給 dev release 的 zip URL（預設值），或改本地 zip / 資料夾：
$env:DRIVERS_DIR = "https://github.com/Droid-VM/gunyah-guest-drivers-windows/releases/download/dev/gunyah-arm64-drivers.zip"
$env:OUT_QCOW    = "C:\Users\USER\Documents\DroidVMBuild\win11-droidvm-other.qcow2"
# IMAGE_INDEX intentionally unset -> build.ps1 lists editions and prompts you to pick
$env:PATH        = "C:\Program Files\qemu;" + $env:PATH

# --- 遠端連線（選用）---
# USER 密碼（RDP/SSH 網路登入必填，空密碼會被擋）。
# $env:SSH_PASSWORD = "MyStr0ngPass"
# SSH 公鑰（設了才有金鑰登入；多把換行分隔）。例如讀檔：
# $env:SSH_PUBKEY   = Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub" -Raw
# OpenSSH 安裝檔來源（預設抓 arm64 .msi 的 URL）。改本地路徑或設 "" 不裝 SSH：
# $env:OPENSSH_SRC  = "C:\Users\USER\Documents\DroidVMBuild\OpenSSH-ARM64-v10.0.0.0.msi"

Write-Host "==== BUILD OTHER (uploaded driver) - interactive image index ====" -ForegroundColor Cyan
& "$PSScriptRoot\build.ps1"
