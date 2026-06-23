# inputs/ — 放這裡

- Win11 ARM64 ISO：`*arm64*dvd*.iso`（如 en-us_windows_11_iot_enterprise_ltsc_2024_arm64_dvd_*.iso）
- 驅動：`drivers/` 內含 8 個資料夾
  viostor vioscsi vioserial viosock NetKVM vioinput viorng rdmapool
  每個含 inf/sys/cat（viosock 另含 lib+exe、NetKVM 含 netkvmp.exe、viorng 含 viorngum.dll）
- 測試憑證：`drivers/DroidVM_Test.cer`（與驅動同一張簽章憑證）
- 或整包成 `drivers.zip`（build.sh 會自動解開）
