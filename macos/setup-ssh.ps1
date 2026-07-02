<#
  setup-ssh.ps1 — 首次開機（以建立的管理員帳號）裝 OpenSSH Server：
    - arm64 .msi 優先（一鍵裝好服務/host key/ACL），.zip 備援（install-sshd + ssh-keygen -A + FixHostFilePermissions）
    - authorized_keys -> C:\ProgramData\ssh\administrators_authorized_keys（管理員金鑰路徑）+ 收緊 ACL
    - 開 SSH(22) 防火牆、啟動 sshd（開機自動）
  安裝檔與金鑰由 02-make-iso.sh staging 到 C:\DroidVM\；公鑰來源是 build_runme.sh 的 SSH_PUBKEY。
  沒有 OpenSSH 安裝檔就直接略過（不致命）。
#>
$ErrorActionPreference = 'Stop'

$msi = Get-ChildItem 'C:\DroidVM' -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
$zip = Get-ChildItem 'C:\DroidVM' -Filter '*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
$sshInstalled = $false

if ($msi) {
    $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$($msi.FullName)`"", '/qn', '/norestart') -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "msiexec 失敗 (exit $($p.ExitCode))" }
    $sshInstalled = $true
}
elseif ($zip) {
    $ex = 'C:\DroidVM\openssh-extracted'
    Expand-Archive $zip.FullName -DestinationPath $ex -Force
    $bin = Split-Path (Get-ChildItem $ex -Recurse -Filter sshd.exe | Select-Object -First 1).FullName
    $dst = "$env:ProgramFiles\OpenSSH"
    New-Item -ItemType Directory -Force $dst | Out-Null
    Copy-Item "$bin\*" $dst -Recurse -Force
    & "$dst\install-sshd.ps1"
    & "$dst\ssh-keygen.exe" -A
    $fixPerm = Join-Path $dst 'FixHostFilePermissions.ps1'
    if (Test-Path $fixPerm) { & $fixPerm -Confirm:$false }
    $sshInstalled = $true
}
else {
    Write-Host 'No OpenSSH installer staged (C:\DroidVM 無 msi/zip) -> 跳過 SSH'
}

if ($sshInstalled) {
    Set-Service sshd      -StartupType Automatic
    Set-Service ssh-agent -StartupType Automatic -ErrorAction SilentlyContinue

    # 管理員帳號的金鑰不讀家目錄，而是 administrators_authorized_keys，且 ACL 必須只有 SYSTEM+Administrators
    if (Test-Path 'C:\DroidVM\authorized_keys') {
        $ak = 'C:\ProgramData\ssh\administrators_authorized_keys'
        New-Item -ItemType Directory -Force (Split-Path $ak) | Out-Null
        Copy-Item 'C:\DroidVM\authorized_keys' $ak -Force
        icacls $ak /inheritance:r /grant 'Administrators:F' 'SYSTEM:F' | Out-Null
    }

    if (-not (Get-NetFirewallRule -Name 'DroidVM-sshd' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'DroidVM-sshd' -DisplayName 'OpenSSH Server (sshd) [DroidVM]' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }
    Start-Service sshd
    Write-Host 'OpenSSH Server ready (port 22, auto-start).'
}

# ---- RDP：開遠端桌面（FirstLogon 以 SYSTEM/管理員權限，HKLM 寫得進）----
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0 -Type DWord -Force
# NLA 開著較安全；要純密碼免 NLA 可把下行改成 0
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1 -Type DWord -Force
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
Set-Service TermService -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service TermService -ErrorAction SilentlyContinue
# 把目前帳號(FirstLogon 執行者)加進 Remote Desktop Users。管理員本來就能 RDP，這條是保險/明確化，
# 帳號若非管理員則為必要。已是成員/管理員時會報錯，無害，故忽略。
net localgroup "Remote Desktop Users" "$env:USERNAME" /add 2>$null | Out-Null
Write-Host 'RDP enabled (port 3389).'
