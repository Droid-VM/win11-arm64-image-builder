# windows/ — 路線 A(x64 Windows,DISM 離線)

在 **x64 Windows** 上把 **Win11 ARM64 ISO + 驅動**直接做成可開機、已含驅動的 qcow2 —— **不跑 Setup、不開 qemu**,靠 `dism` 套用映像 + 離線注入驅動 + `bcdboot`。入口是根目錄的 `windows_build.ps1`。

## 為什麼用這個(vs 路線 B 的 qemu 流程)

| | 路線 A(DISM 離線) | 路線 B(qemu 跑 Setup) |
|---|---|---|
| 驅動簽章提示 | **完全沒有**(離線注入不經互動 PnP) | 需匯入憑證到 TrustedPublisher |
| 時間 | ~5–10 分(無裝機 reboot) | ~30 分 |
| boot-press / 點擊器 | 不需要 | 需要 |
| 環境 | 要 x64 Windows | Apple Silicon Mac |

> 離線 `dism /Add-Driver /ForceUnsigned` 不會跳「Windows can't verify the publisher」(那是互動式 PnP 才有的)。但自簽驅動要能在**開機時載入**仍需 BCD `testsigning on`(流程第 6 步設)。

> 產物約 **14 GB**(比路線 B 的 ~7 GB 大);想要更小的映像可改走 macOS(路線 B)。

## 需求
- **x64 Windows,系統管理員**(內建 `dism` / `bcdboot` / `diskpart`)
- **`qemu-img`**(QEMU for Windows,需在 PATH)—— 最後 VHDX→qcow2 轉檔用
- Win11 ARM64 ISO

## 用法
```powershell
# 編輯 windows_build.ps1 頂部變數($env:SRC_ISO 必填、$env:DRIVERS_DIR、$env:OUT_QCOW …)
powershell -ExecutionPolicy Bypass -File windows_build.ps1   # 會自動提權
```
變數清單見根目錄 README。**Windows 專屬注意**:帳號名用 `$env:DVM_USERNAME`(**不是** Windows 內建的 `$env:USERNAME`＝目前登入者);密碼 `$env:DVM_PASSWORD`(空密碼會擋 RDP/SSH;相容舊 `$env:SSH_PASSWORD`)。

## 流程(build.ps1,全程離線不開機)
1. 解析驅動來源 → 掛 ISO 取 `install.wim`
2. 建 + 掛 VHDX,GPT 分割 ESP(FAT32)+ MSR + Windows(NTFS)
3. `dism /Apply-Image` 套用映像
4. `dism /Add-Driver /ForceUnsigned` 離線注入 `DRIVER_INSTALL` 指定的驅動;從 `.cat` 萃取簽章憑證 → `C:\DroidVM\certs`
5. debloat:移除多餘 Appx、關 hibernate、開 RDP、停用 Reserved Storage(全部離線改 hive)
6. `bcdboot` + `bcdedit` 開 `testsigning` / `nointegritychecks`
7. 放入 `unattend.xml`(注入帳號)+ staging `setup-ssh.ps1` / OpenSSH / `authorized_keys` / `pvmpower-devnode.ps1` → `C:\DroidVM`
8. 卸載 VHDX → `qemu-img convert` 成 qcow2

產物是 **OOBE-pending**:第一次開機在 **Gunyah 目標機**上跑 —— 建帳號、autologon、匯憑證、裝 SSH、設「永不睡眠 / 永不關螢幕」,並全新偵測硬體安裝驅動(含把 `rdmapool` 綁到目標機才有的 `ACPI\RDMA0000`),因此驅動能在開機階段正確載入。

## 遠端連線
- **RDP**:離線就開好(`fDenyTSConnections=0`),首次開機只補防火牆;USER 是管理員,預設可連。
- **SSH**:`$env:OPENSSH_SRC` 指安裝檔來源(URL 下載 / 本地路徑),預設抓 arm64 `.msi`(一鍵裝服務 / host key / 防火牆,也接受 `.zip`);設空字串 = 不裝 SSH。
- 匯入 Root/TrustedPublisher 只消掉「日後更新驅動的發行者警告」;自簽驅動開機載入仍靠 `testsigning`,別因此關掉。
