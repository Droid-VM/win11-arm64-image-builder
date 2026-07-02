# debloat.ps1 — slim down (LTSC IoT is already lean, so this does conservative cleanup)
# Called by autounattend on first login; failures are not fatal, continue as much as possible.
$ErrorActionPreference = 'SilentlyContinue'
Write-Host "[debloat] start"

# 1) Remove leftover provisioned/installed Appx (LTSC has few; keep Store/essential components)
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

# 2) Disable telemetry / ads / content push
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

# 3) Disable non-essential services (conservative: telemetry/diagnostics/Xbox/search indexing)
$svc = 'DiagTrack','dmwappushservice','WSearch','XblAuthManager','XblGameSave','XboxNetApiSvc','XboxGipSvc','MapsBroker','RetailDemo'
foreach ($s in $svc) {
  Set-Service -Name $s -StartupType Disabled
  Stop-Service -Name $s -Force
}

# 4) Disable scheduled telemetry tasks
$tasks = '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
         '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
         '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
         '\Microsoft\Windows\Feedback\Siuf\DmClient',
         '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'
foreach ($t in $tasks) { Disable-ScheduledTask -TaskPath (Split-Path $t) -TaskName (Split-Path $t -Leaf) | Out-Null }

# 5) Disable hibernation (removes hiberfil.sys, shrinks the image)
powercfg /h off

# 6) Clean up WinSxS and update leftovers, temp files
Dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet
Remove-Item -Recurse -Force "$env:WINDIR\Temp\*"      -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$env:WINDIR\SoftwareDistribution\Download\*" -ErrorAction SilentlyContinue

# 7) Disable Windows Update (including WaaSMedicSvc / UsoSvc, which auto-restart wuauserv),
#    and place enable_windows_update.bat on the "USER desktop" so the user can decide when to turn updates back on.
Write-Host "[debloat] disable Windows Update"
# wuauserv is disabled via sc; WaaSMedicSvc is protected and can only be changed via the registry Start value (4=disabled)
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
$desktop = Join-Path $env:USERPROFILE 'Desktop'   # Desktop of the build_runme.sh USERNAME account (FirstLogon runs as that account)
New-Item -ItemType Directory -Force $desktop | Out-Null
Set-Content -Path (Join-Path $desktop 'enable_windows_update.bat') -Value $enableBat -Encoding Ascii

# 8) Issue TRIM on freed space -> qemu(discard=unmap) shrinks qcow2 live, and the final convert is smaller
Write-Host "[debloat] ReTrim free space"
Optimize-Volume -DriveLetter C -ReTrim -ErrorAction SilentlyContinue

Write-Host "[debloat] done"
