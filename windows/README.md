# windows/ — DISM 離線版（x64 Windows）

在 **x64 Windows** 上把 **Win11 ARM64 ISO + 驅動** 直接做成**可開機、已含驅動的 qcow2**，
**不跑 Setup、不開 qemu**。靠 DISM 套用映像 + 離線注入驅動 + bcdboot。

## 為什麼用這個（vs macos/ 的 qemu 流程）
| | windows/（DISM 離線） | macos/（qemu 跑 Setup） |
|---|---|---|
| 驅動簽章提示 | **完全沒有**（離線注入不經互動 PnP） | 需 CA:FALSE 憑證 + 匯入 TrustedPublisher |
| 時間 | ~5–10 分（無裝機 reboot） | ~30 分 |
| boot-press / 點擊器 | 不需要 | 需要 |
| 環境 | **要 x64 Windows** | Mac / 任何能跑 qemu |

> 離線 `DISM /Add-Driver` 不會跳「Windows can't verify the publisher」——那是互動式 PnP 才有的。
> 自簽驅動要能在開機時**載入**仍需 BCD `testsigning on`（腳本第 7 步直接設）。

## 需求
- **x64 Windows，系統管理員**（diskpart / dism / bcdboot 內建）
- **qemu-img**（QEMU for Windows，需加入 PATH）——最後 VHDX→qcow2 轉檔用
- Win11 ARM64 ISO（IoT Enterprise LTSC，index 2）

## 用法
```powershell
# 1) 設定（PowerShell 原生：build.ps1 會 dot-source windows\config.ps1）
copy windows\config.example.ps1 windows\config.ps1   # 編輯 $SRC_ISO（必填）、$DRIVERS_DIR（預設抓 dev release）

# 2) 執行（會自動提權到系統管理員）
powershell -ExecutionPolicy Bypass -File windows\build.ps1
#   -> win11-droidvm-final.qcow2
```
> 設定優先序：環境變數 / CLI　>　`windows\config.ps1`　>　內建預設。
> 也可以完全不用 config.ps1，直接設環境變數後跑，例如 `$env:SRC_ISO='...'; .\windows\build.ps1`。

## 流程（build.ps1）
1. 解析驅動來源（URL→下載 dev release zip / 本地 zip / 資料夾）
2. 掛載 ISO 取 `install.wim`
3. 建 + 掛 VHDX，GPT 分割 ESP(FAT32)+MSR+Windows(NTFS)
4. `dism /Apply-Image` 套用映像
5. `dism /Add-Driver /Recurse /ForceUnsigned` **離線注入驅動**
6. 離線移除多餘 provisioned Appx（debloat）
7. `bcdboot` 做開機檔，`bcdedit /store` 開 testsigning + nointegritychecks
8. 放入 `unattend.xml`（首次開機 OOBE 建 USER、autologon）
9. 卸載 VHDX → `qemu-img convert` 成 qcow2

## 快速換驅動（不重做整顆）
現有 qcow2 → 轉 vhdx → 掛載 → 注入 → 轉回，不用開機、不跳提示、~2–3 分：
```powershell
qemu-img convert -O vhdx win11-droidvm-final.qcow2 tmp.vhdx
Mount-VHD tmp.vhdx            # 記下 Windows 分割的磁碟機代號，假設 W:
dism /Image:W:\ /Add-Driver /Driver:C:\newdrivers /Recurse /ForceUnsigned
Dismount-VHD tmp.vhdx
qemu-img convert -O qcow2 tmp.vhdx win11-droidvm-final.qcow2
```

## 跨架構提醒
x64 host 套用/注入 ARM64 映像 + `bcdboot` **多半可行**（apply 是解檔、add-driver 寫離線 DriverStore、
BCD 格式中性）。少數環境會踩坑——若 bcdboot 失敗或開機不了，改在 **ARM64 Windows 或 ARM64 WinPE**
上跑這幾步最保險。
