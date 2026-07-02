#!/usr/bin/env bash
# =====================================================================
# build_runme.sh — 路線 B（Apple Silicon Mac）的唯一入口。
#   改下面的變數成你的，然後直接執行本檔（它會呼叫 build.sh）。
#   檔案類變數都可填「URL」（自動下載到 files/）或「本地路徑」。
#   testsigning BCD 會用 Colima 容器自動產生（免另一台 Linux）。
#   需求：brew install qemu wimlib xorriso colima docker
#   用法：  bash macos/build_runme.sh
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 必要：Win11 ARM64 ISO（URL 或本地路徑）---
export SRC_ISO="/path/to/win11_arm64.iso"

# --- 必要：驅動 zip 來源（URL 或本地 zip / 資料夾）；下面的 ZIP/ 就是它解壓後的根目錄 ---
export DRIVERS_DIR="https://github.com/Droid-VM/gunyah-guest-drivers-windows/releases/download/dev/gunyah-arm64-drivers.zip"

# --- install.wim 版本 index：留空 = 偵測 install.wim 內的版本並讓你選；或直接填數字（如 1= LTSC）---
export IMAGE_INDEX=""

# --- 產物 ---
export OUT_QCOW="$HERE/win11-droidvm-final.qcow2"

# --- 選用：qemu 參數（不設就用預設）---
# export MEM="8G"
# export SMP="6"
# export DISK_SIZE="40G"
# 安裝畫面顯示：預設 true = headless（用 VNC 看：open vnc://127.0.0.1:5905）。
# 設 false 會開原生 qemu 視窗，構建時直接看得到 —— 但要在 Mac「桌面的 Terminal」跑，純 SSH 會失敗。
# export BACKGROUND=false
# export DISPLAY_OPT="-vnc 127.0.0.1:5"   # 完全自訂顯示參數（覆蓋 BACKGROUND）

# --- 要安裝的驅動（ZIP/ = DRIVERS_DIR 解壓後的根目錄）---
export DRIVER_DIR="ZIP/drivers"                            # 含各驅動子資料夾的目錄
export DRIVER_INSTALL="NetKVM rdmapool pvmpower vioinput viostor vioscsi"   # 只裝這幾個（留空=全部）
export DRIVER_CERT="ZIP/DroidVM_Test.cer"                  # 指定簽章憑證（留空=從 .cat 自動萃取）

# --- 帳號 / 遠端 ---
export USERNAME="USER"          # 建立的本機管理員帳號名
export PASSWORD="DroidVM"       # 密碼（空密碼會擋掉 SSH 網路登入）
export SSH_PUBKEY=""            # SSH 公鑰（多把換行分隔；留空=只密碼登入）
# OpenSSH 安裝檔（URL 下載到 files/ 或本地路徑）；留空=不裝 SSH。預設抓 arm64 .msi。
export OPENSSH_SRC="https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-ARM64-v10.0.0.0.msi"

"$HERE/build.sh"
