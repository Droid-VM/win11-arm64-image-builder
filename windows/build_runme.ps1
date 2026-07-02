# =====================================================================
# build_runme.ps1 — 路線 A（x64 Windows）的入口。改下面變數成你的，然後右鍵「以系統管理員身分執行」，
#   或直接跑本檔（會自動提權）。檔案類變數可填「URL」（自動下載到 files\）或「本地路徑」；zip 自動解壓。
#   驅動用 DISM 離線注入（不需開機、不跳簽章提示）。
#   需求：x64 Windows（系統管理員）、內建 dism/bcdboot/diskpart、qemu-img（QEMU for Windows 在 PATH）。
#   用法：  powershell -ExecutionPolicy Bypass -File windows\build_runme.ps1
# =====================================================================
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell "-NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# --- 必要：Win11 ARM64 ISO（URL 或本地路徑）---
$env:SRC_ISO     = "C:\Users\USER\Documents\DroidVMBuild\SW_DVD9_Win_Pro_11_25H2_Arm64_English_Pro_Ent_EDU_N_MLF_X24-13111.ISO"

# --- 必要：驅動 zip 來源（URL 或本地 zip / 資料夾）；下面的 ZIP/ 就是它解壓後的根目錄 ---
$env:DRIVERS_DIR = "https://github.com/Droid-VM/gunyah-guest-drivers-windows/releases/download/dev/gunyah-arm64-drivers.zip"

# --- install.wim 版本 index：留空 = build.ps1 列出版本讓你選；或填數字（如 1）---
# $env:IMAGE_INDEX = "1"

# --- 產物 ---
$env:OUT_QCOW    = "C:\Users\USER\Documents\DroidVMBuild\win11-droidvm-final.qcow2"

# --- 要離線注入的驅動（ZIP/ = DRIVERS_DIR 解壓後的根目錄）---
$env:DRIVER_DIR     = "ZIP/drivers"                                       # 含各驅動子資料夾的目錄
$env:DRIVER_INSTALL = "NetKVM rdmapool pvmpower vioinput viostor vioscsi" # 只裝這幾個（留空=全部）；務必含 viostor/vioscsi 開機驅動
$env:DRIVER_CERT    = "ZIP/DroidVM_Test.cer"                              # 指定簽章憑證（留空=從 .cat 自動萃取）

# --- 帳號 / 遠端 ---
# 注意：Windows 的 $env:USERNAME 是內建變數（目前登入者），故帳號名用「一般變數」$USERNAME（不加 $env:），
#       或改用非內建的 $env:DVM_USERNAME。build.ps1 會讀到（子scope 繼承）。
$USERNAME        = "USER"        # 建立的本機管理員帳號名
$env:PASSWORD    = "DroidVM"     # 密碼（空密碼會擋掉 RDP/SSH 網路登入）
# $env:SSH_PUBKEY  = Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub" -Raw   # SSH 公鑰（多把換行分隔；留空=只密碼登入）
# OpenSSH 安裝檔（URL 下載到 files\ 或本地路徑）；設 "" 不裝 SSH（僅 RDP）。預設抓 arm64 .msi。
$env:OPENSSH_SRC = "https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-ARM64-v10.0.0.0.msi"

# --- 選用：磁碟大小(MB) / 產物路徑覆蓋 ---
# $env:DISK_SIZE_MB = "40960"

# qemu-img 需在 PATH（QEMU for Windows）
$env:PATH        = "C:\Program Files\qemu;" + $env:PATH

Write-Host "==== DroidVM Windows builder（DISM 離線注入驅動）====" -ForegroundColor Cyan
& "$PSScriptRoot\build.ps1"
