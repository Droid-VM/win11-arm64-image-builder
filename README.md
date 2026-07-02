# win11-arm64-image-builder

把 **Win11 ARM64 ISO + 自簽 gunyah/virtio 驅動**全自動建成一顆可直接在 **DroidVM（Gunyah/crosvm）上開機的 qcow2**。

產物預設:本機帳號 `USER`(自動登入)、testsigning + nointegritychecks 已開、驅動已裝、SSH/RDP 已開、已 debloat、永不睡眠 / 永不關螢幕、停用 Reserved Storage。

## 兩條路線(二選一,產物等價)

| 路線 | 環境 | 入口 | 做法 | 時間 |
|---|---|---|---|---|
| **A. Windows** | 單台 x64 Windows(系統管理員) | `windows_build.ps1` | DISM 離線套用映像 + 離線注入驅動 + bcdboot/bcdedit;不跑 Setup、不開 VM | ~5–10 分 |
| **B. macOS** | 單台 Apple Silicon Mac | `macos_build.sh` | qemu HVF 跑 Setup 裝機 + 裝驅動,再 `sysprep /generalize` 打回可部署狀態 | ~30 分 |

兩條路線都把映像做成 **OOBE-pending(尚未完成首次設定)**:真正的「第一次開機」發生在 **Gunyah 目標機**上,由它全新偵測硬體並安裝驅動 —— 尤其把 `rdmapool` 綁到目標機才有的 `ACPI\RDMA0000`(受保護 VM 的 restricted-DMA pool),讓 `viostor` 的 DMA 走 bounce、不打到 lent 記憶體。這是驅動能在開機階段正確載入的關鍵。

> **產物功能等價,但體積不同**:路線 B(macOS)約 **7 GB**,路線 A(Windows)約 **14 GB**。差在回收可用空間的方式 —— macOS 流程在 qemu 執行期即時 TRIM(`discard=unmap`)並線上 debloat,壓得較實;想更小可走 macOS。開 `-c` 壓縮(`COMPRESS=1`)後兩者都約 **6 GB**,但 crosvm 不能直讀,需 DroidVM 匯入 / pre-flight 解壓。

## 用法

兩邊都是「改入口腳本頂部的變數 → 執行」。

```powershell
# 路線 A(Windows,會自動提權)
powershell -ExecutionPolicy Bypass -File windows_build.ps1
```
```bash
# 路線 B(macOS)
bash macos_build.sh
```

## 設定(入口腳本裡的變數)

檔案類變數(`SRC_ISO` / `DRIVERS_DIR` / `OPENSSH_SRC`)可填 **URL**(自動下載到 `files/`)或**本地路徑**;zip 自動解壓。

| 變數 | 說明 |
|---|---|
| `SRC_ISO` | **必填**。Win11 ARM64 ISO(URL 或路徑) |
| `DRIVERS_DIR` | 驅動來源:GitHub release zip URL / 本地 zip / 本地資料夾。預設抓 `gunyah-guest-drivers-windows` 的 `dev` release |
| `DRIVER_INSTALL` | 只安裝這些驅動子資料夾(預設 `NetKVM rdmapool pvmpower vioinput viostor vioscsi`;必須含開機碟 `viostor`) |
| `DRIVER_CERT` | 簽章憑證(空 = 從驅動 `.cat` 自動萃取) |
| `IMAGE_INDEX` | install.wim 版本索引(空 = 列出讓你選) |
| `USERNAME` / `PASSWORD` | 建立的本機管理員帳號。macOS 用 `USERNAME` / `PASSWORD`;Windows 用 `$env:DVM_USERNAME` / `$env:DVM_PASSWORD` |
| `SSH_PUBKEY` | SSH 公鑰(空 = 只密碼登入) |
| `OUT_QCOW` | 輸出 qcow2 路徑 |

## 需求

- **macOS:** `brew install qemu wimlib xorriso colima docker`;另需約 **50 GB** 可用空間放中間產物(工作 qcow2 / 安裝 ISO / 驅動,位於 `macos/files`)。testsigning 的 BCD patch 用 Colima 容器內的 hivex 代跑,故無需另一台 Linux
- **Windows:** x64 Windows(系統管理員)、內建 `dism` / `bcdboot` / `diskpart`、`qemu-img`(QEMU for Windows,需在 PATH)

## 結構

```
macos_build.sh      路線 B 入口(改變數後 bash 執行)
windows_build.ps1   路線 A 入口(改變數後以系統管理員執行)
macos/              路線 B 實作:build.sh + 00/02/03 階段 + autounattend / gunyah-oobe + Colima BCD patch
windows/            路線 A 實作:build.ps1 + unattend(詳見 windows/README.md)
files/              各路線的中間產物快取(URL 下載 / zip 解壓,已 gitignore)
```
