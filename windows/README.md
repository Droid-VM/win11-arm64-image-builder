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
# 1) 編輯 windows\build_runme.ps1 的變數（$SRC_ISO、$DRIVERS_DIR、$OUT_QCOW …）
#    檔案類變數可填 URL（自動下載到 files\）或本地路徑；zip 會自動解壓到 files\。

# 2) 執行（會自動提權到系統管理員）
powershell -ExecutionPolicy Bypass -File windows\build_runme.ps1
#   -> win11-droidvm-final.qcow2
```

## 流程（build.ps1）
1. 解析驅動來源（URL→下載到 files\ / 本地 zip→解壓到 files\ / 本地資料夾直接用）
2. 掛載 ISO 取 `install.wim`
3. 建 + 掛 VHDX，GPT 分割 ESP(FAT32)+MSR+Windows(NTFS)
4. `dism /Apply-Image` 套用映像
5. `dism /Add-Driver /Recurse /ForceUnsigned` **離線注入驅動**
   - 5b. 從 `.cat` 萃取簽章者憑證 → staging 到 `C:\DroidVM\certs`（specialize 匯入 Root+TrustedPublisher，日後更新驅動不跳警告）
6. 離線移除多餘 provisioned Appx（debloat）；離線改 SYSTEM hive：關 hibernate、**開 RDP**（fDenyTSConnections=0）
7. `bcdboot` 做開機檔，`bcdedit /store` 開 testsigning + nointegritychecks
8. 放入 `unattend.xml`（注入密碼；首次開機 OOBE 建 USER、autologon、匯入憑證）
   - 8c. staging `setup-ssh.ps1` + OpenSSH 安裝檔 + `authorized_keys`（來自 `$SSH_PUBKEY`）→ `C:\DroidVM`（首次開機裝 sshd、開防火牆）
9. 卸載 VHDX → `qemu-img convert` 成 qcow2

## 遠端連線（RDP + OpenSSH）
- **RDP**：離線開好（步驟 6 設 `fDenyTSConnections=0`），首次開機只補防火牆。USER 為管理員，預設可 RDP。
- **SSH**：`$env:OPENSSH_SRC` 指安裝檔來源（URL 下載 / 本地路徑複製），**預設抓 arm64 `.msi`**
  （一鍵裝好服務/host key/防火牆，也接受 `.zip`）；設空字串 = 不裝 SSH。
- **密碼 / 公鑰走環境變數**：`$env:SSH_PASSWORD`（預設 `DroidVM`，必填、空密碼會被擋）、`$env:SSH_PUBKEY`（設了才有金鑰登入）。三者也可寫進 config.ps1。
- 自簽驅動仍靠 `testsigning`；匯入 Root/TrustedPublisher 只消掉「更新時的發行者警告」，不能因此關 testsigning。

