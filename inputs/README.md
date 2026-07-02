# inputs/ — 放這裡

- Win11 ARM64 ISO：`*arm64*dvd*.iso`（如 en-us_windows_11_iot_enterprise_ltsc_2024_arm64_dvd_*.iso）
- 驅動：`drivers/` 內含 8 個資料夾
  viostor vioscsi vioserial viosock NetKVM vioinput viorng rdmapool
  每個含 inf/sys/cat（viosock 另含 lib+exe、NetKVM 含 netkvmp.exe、viorng 含 viorngum.dll）
- 測試憑證：`drivers/DroidVM_Test.cer`（與驅動同一張簽章憑證）
- 或整包成 `drivers.zip`（build.sh 會自動解開）

## windows/ 遠端連線用（皆走環境變數，只影響 windows/build.ps1）
- `OPENSSH_SRC`：OpenSSH 安裝檔來源。**預設抓 arm64 `.msi`**（一鍵裝好服務/host key/防火牆）。
  可為 URL（build 時下載）或本地路徑（複製）；空字串 = 不裝 SSH，只有 RDP。也接受 `.zip`。
- `SSH_PASSWORD`：USER 密碼，預設 `DroidVM`。空密碼會被擋掉 RDP/SSH 網路登入，故必填。
- `SSH_PUBKEY`：SSH 公鑰（多把用換行分隔）。設了 = 金鑰登入；不設 = 只密碼登入。
- 三者也可在 windows/config.ps1 設 `$OPENSSH_SRC` / `$SSH_PASSWORD` / `$SSH_PUBKEY`。
  → 預設情況下 inputs\ 不需放任何 SSH 相關檔案。
