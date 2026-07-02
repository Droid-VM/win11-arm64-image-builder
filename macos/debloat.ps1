# debloat.ps1 — 輕量化（LTSC IoT 本身已很精簡，這裡做保守清理）
# 由 autounattend 首次登入呼叫；失敗不致命，盡量繼續。
$ErrorActionPreference = 'SilentlyContinue'
Write-Host "[debloat] start"

# 1) 移除殘留的 provisioned/已安裝 Appx（LTSC 沒幾個；保留 Store/必要元件）
$keep = 'VCLibs|NET\.Native|UI\.Xaml|StorePurchaseApp|WindowsStore|SecHealthUI|Microsoft\.Windows\.Photos|Notepad|Microsoft\.WindowsTerminal'
Get-AppxProvisionedPackage -Online |
  Where-Object { $_.DisplayName -notmatch $keep } |
  ForEach-Object {
    Write-Host "  remove provisioned $($_.DisplayName)"
    Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName | Out-Null
  }
Get-AppxPackage -AllUsers |
  Where-Object { $_.Name -notmatch $keep -and $_.NonRemovable -ne $true } |
  ForEach-Object {
    Write-Host "  remove appx $($_.Name)"
    Remove-AppxPackage -AllUsers -Package $_.PackageFullName | Out-Null
  }

# 2) 關閉遙測 / 廣告 / 內容推送
$telemetry = @{
  'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' = @{ AllowTelemetry = 0 }
  'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'   = @{ DisableWindowsConsumerFeatures = 1; DisableCloudOptimizedContent = 1 }
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' = @{ Enabled = 0 }
}
foreach ($path in $telemetry.Keys) {
  New-Item -Path $path -Force | Out-Null
  foreach ($name in $telemetry[$path].Keys) {
    New-ItemProperty -Path $path -Name $name -Value $telemetry[$path][$name] -PropertyType DWord -Force | Out-Null
  }
}

# 3) 停用非必要服務（保守：遙測/診斷/Xbox/搜尋索引）
$svc = 'DiagTrack','dmwappushservice','WSearch','XblAuthManager','XblGameSave','XboxNetApiSvc','XboxGipSvc','MapsBroker','RetailDemo'
foreach ($s in $svc) {
  Set-Service -Name $s -StartupType Disabled
  Stop-Service -Name $s -Force
}

# 4) 停用排程的遙測工作
$tasks = '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
         '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
         '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
         '\Microsoft\Windows\Feedback\Siuf\DmClient',
         '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'
foreach ($t in $tasks) { Disable-ScheduledTask -TaskPath (Split-Path $t) -TaskName (Split-Path $t -Leaf) | Out-Null }

# 5) 關閉休眠（省掉 hiberfil.sys，縮小映像）
powercfg /h off

# 6) 清理 WinSxS 與更新殘留、暫存
Dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet
Remove-Item -Recurse -Force "$env:WINDIR\Temp\*"      -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$env:WINDIR\SoftwareDistribution\Download\*" -ErrorAction SilentlyContinue

# 7) 停用 Windows Update（含會自動把 wuauserv 重開的 WaaSMedicSvc / UsoSvc），
#    並在「USER 桌面」放 enable_windows_update.bat 讓使用者自己決定何時打開更新。
Write-Host "[debloat] disable Windows Update"
# wuauserv 用 sc 停用；WaaSMedicSvc 受保護只能改登錄檔 Start（4=disabled）
& sc.exe stop wuauserv | Out-Null
& sc.exe config wuauserv start= disabled | Out-Null
reg add "HKLM\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc" /v Start /t REG_DWORD /d 4 /f | Out-Null
reg add "HKLM\SYSTEM\CurrentControlSet\Services\UsoSvc"       /v Start /t REG_DWORD /d 4 /f | Out-Null
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -Value 1 -PropertyType DWord -Force | Out-Null

$enableBat = @'
@echo off
>nul 2>&1 net session || (powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" & exit /b)
echo Re-enabling Windows Update...
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /f >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc" /v Start /t REG_DWORD /d 3 /f >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Services\UsoSvc"       /v Start /t REG_DWORD /d 2 /f >nul
sc config wuauserv start= demand >nul
sc start wuauserv >nul 2>&1
echo Done. Windows Update re-enabled (a reboot is recommended).
pause
'@
$desktop = Join-Path $env:USERPROFILE 'Desktop'   # build_runme.sh 的 USERNAME 帳號桌面（FirstLogon 以該帳號執行）
New-Item -ItemType Directory -Force $desktop | Out-Null
Set-Content -Path (Join-Path $desktop 'enable_windows_update.bat') -Value $enableBat -Encoding Ascii

# 8) 對釋放空間發 TRIM -> qemu(discard=unmap) 即時縮 qcow2，最後 convert 更小
Write-Host "[debloat] ReTrim free space"
Optimize-Volume -DriveLetter C -ReTrim -ErrorAction SilentlyContinue

Write-Host "[debloat] done"
