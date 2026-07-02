# win11-arm64-image-builder

半成品警告: 尚未完工，仍為半成品

把 **Win11 ARM64 ISO + 自簽 virtio/gunyah 驅動** 全自動建成一顆**可直接開機的 qcow2**
（預設帳號 `USER`、無密碼、自動登入；testsigning + nointegritychecks 已開；
已裝驅動、debloat、TRIM 壓縮）。

## 兩條路線（二選一）
| 路線 | 環境 | 怎麼做 | 時間 |
|---|---|---|---|
| **A. windows/（DISM 離線）** | **單台 x64 Windows** | DISM 套用映像 + 離線注入驅動 + bcdboot/bcdedit，**不跑 Setup、不開 VM、不跳簽章提示** | ~5–10 分 |
| **B. macos/（Setup）** | **單台 Apple Silicon Mac** | Colima 容器產 BCD patch（hivex）→ qemu HVF 跑 Setup 裝機 | ~30 分 |

> **有 x64 Windows 就走 A，最快且最省事**；A 完全獨立、單機自足。
> 只有 Mac 走 B：hivex 那步用 **Colima 容器**代跑，一樣單機自足（不再需要另一台 Linux）。
> 兩條路線產物相同（可開機、已含驅動的 qcow2）。

```
windows/   【路線 A】改 build_runme.ps1 變數後執行 -> 直接產 qcow2（自足）
macos/     【路線 B】改 build_runme.sh 變數後執行 -> 自動產 patch + 裝機 -> qcow2
           （make-patches.sh / Dockerfile / bcd-testsigning.py = Colima 容器代跑的 hivex 產 BCD）
files/     兩路線共用快取：URL 下載 / zip 解壓 / BCD patch（已 gitignore）
```
> 檔案類設定都在各自的 `build_runme.*`：填 URL 會自動下載到 `files/`，或填本地路徑。

## 設定
- **路線 A（windows/）**：改 `windows\build_runme.ps1` 的 `$env:...` 變數（或 `windows\config.ps1`）。
  細節見 [`windows/README.md`](windows/README.md)。
- **路線 B（macos/）**：改 `macos/build_runme.sh` 的 `export ...` 變數。
  主要變數：`SRC_ISO`、`DRIVERS_DIR`、`DRIVER_DIR`/`DRIVER_INSTALL`/`DRIVER_CERT`、`OUT_QCOW`、
  `MEM`/`SMP`/`DISK_SIZE`/`DISPLAY_OPT`。

### 驅動來源 `DRIVERS_DIR`（兩條路線共用的三選一邏輯）
| 寫法 | 行為 |
|---|---|
| **GitHub repo URL**（預設 `https://github.com/HuJK-Data/gunyah-guest-drivers-windows`） | 自動下載該 repo **`dev` release** 的驅動 zip → `inputs/drivers.zip` → 解開 |
| 本地 `*.zip` 路徑 | 複製到 `inputs/drivers.zip` → 解開 |
| 本地資料夾 | 直接使用（每個驅動一個子資料夾） |
> 未設定時：有 `inputs/drivers/` 或 `inputs/drivers.zip` 就用本地，否則才走 URL 下載。
> 私有 repo 下載需先 `gh auth login`；公開 repo 用 curl 即可。憑證會從驅動 `.cat` 自動萃取。

## 用法 A — windows/（單台 x64 Windows，推薦）
詳見 [`windows/README.md`](windows/README.md)。需要 x64 Windows（系統管理員）+ `qemu-img`。
```powershell
# 1) 設定（build.ps1 會 dot-source windows\config.ps1）
copy windows\config.example.ps1 windows\config.ps1   # 編輯 $SRC_ISO（必填）、$DRIVERS_DIR（預設自動下載）

# 2) 執行（會自動提權；不跑 Setup、不開 VM）
powershell -ExecutionPolicy Bypass -File windows\build.ps1
#    -> win11-droidvm-final.qcow2
```
> 這條完全自足：用 Windows 內建 `dism`/`bcdboot`/`bcdedit`/`diskpart` 取代了路線 B 對 Linux hivex 與 macOS qemu 的依賴。

## 用法 B — macos/（單台 Mac）
- 為什麼還需要 hivex：設 testsigning 必須改 BCD（registry hive 格式），靠 **hivex**——只有 Linux 方便；
  跑 Setup 要 **ARM64 原生加速**——Apple Silicon Mac 的 **qemu HVF** 最快。所以 hivex 那「小小的 BCD
  patch」（~25KB）改用 **Colima 容器**代跑，其餘重活在 Mac host（容器不需硬體加速，故無巢狀虛擬化問題）。
- 需求：`brew install qemu wimlib xorriso colima docker`
```bash
# 編輯 macos/build_runme.sh 的變數（SRC_ISO / DRIVERS_DIR / OUT_QCOW），然後：
bash macos/build_runme.sh
#   - testsigning BCD 由 Colima 容器自動產生（macos/make-patches.sh 在容器內跑）
#   - 檔案類變數填 URL 會自動下載到 files/，或填本地路徑
#   -> win11-droidvm-final.qcow2
```

## 關鍵技術點
**路線 A（windows/ DISM 離線）**
- **不跑 Setup**：`dism /Apply-Image` 直接解開 install.wim 到分割好的 VHDX，省掉整段裝機 + reboot。
- **離線注入無簽章提示**：`dism /Add-Driver /ForceUnsigned` 寫進離線 DriverStore，不經互動式 PnP，
  所以不會跳「Windows can't verify the publisher」——也因此**不需要匯入憑證**。
- **testsigning 用 bcdedit 直接設**：`bcdboot` 建好 BCD 後 `bcdedit /store ... testsigning on`，
  Windows 原生工具搞定，**不需要 hivex**（這就是不需要 Linux 的原因）。
- 健壯性：native 指令失敗即時中止（檢查 `$LASTEXITCODE`）、磁碟代號自動挑空的（避開 MountedDevices 殘留保留）。

**路線 B（macos/ Setup）**
- **第一次開機的 testsigning**：不能用 autounattend 設（windowsPE RunSynchronous 跑在
  套用映像「前」，bcdedit 會失敗中止 Setup）。改成 **patch install.wim 裡的
  `BCD-Template`**（bcdboot 建 BCD 的範本）→ 裝好就自帶 testsigning。
- **WinPE 載自簽 viostor**：安裝媒體的 BCD 也 patch testsigning。
- **無簽章提示**：在 **specialize（SYSTEM 權限）** 匯入測試憑證到 Root+TrustedPublisher，
  FirstLogon 裝驅動時就不跳「無法驗證發行者」。（另有影像識別點擊器當後備。）
- **開機順序**：安裝媒體 `bootindex=0`、目標磁碟 `bootindex=1`，且 ISO 用「會提示」的
  `efisys.bin`。首次磁碟空 → CD「Press any key」→ 點擊器前 28 秒按鍵進 Setup；套用映像後
  reboot → 提示逾時 → fallthrough 到已可開機的磁碟 → Windows。
  （反過來讓空磁碟先開，edk2 失敗會停在 UEFI 前頁、不 fallthrough；用 efisys_noprompt 則
  套用後會直接重進 Setup 形成重裝迴圈。）
- **縮小**：qemu `discard=unmap` + debloat 的 `Optimize-Volume -ReTrim` + `qemu-img convert`。
- 開機碟 virtio-blk(viostor)；vioscsi/NetKVM 在受保護 VM 無 restricted DMA，僅供一般 VM。
