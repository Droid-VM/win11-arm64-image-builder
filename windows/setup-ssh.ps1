<#
  setup-ssh.ps1 — 首次開機（以 USER，管理員身分）跑：
    - 裝 OpenSSH Server：優先 arm64 .msi（一鍵裝好服務/host key/ACL/防火牆），其次 arm64 .zip（手動那套）
    - authorized_keys -> C:\ProgramData\ssh\administrators_authorized_keys（管理員的金鑰路徑）+ 收緊 ACL
    - 開 SSH(22) 與 RDP 防火牆（RDP 的 fDenyTSConnections 已由 build.ps1 離線設 0）
  安裝檔與金鑰由 build.ps1 第 8c 步 staging 到 C:\DroidVM\；金鑰來源是環境變數 $SSH_PUBKEY。
  沒有 OpenSSH 安裝檔時只設 RDP，不致命。
#>
$ErrorActionPreference = 'Stop'

$msi = Get-ChildItem 'C:\DroidVM' -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
$zip = Get-ChildItem 'C:\DroidVM' -Filter '*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
$sshInstalled = $false

if ($msi) {
    # MSI 一鍵：裝二進位 + 註冊 sshd/ssh-agent 服務 + 產生 host key + 修 ACL + 建防火牆規則
    $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$($msi.FullName)`"", '/qn', '/norestart') -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "msiexec 失敗 (exit $($p.ExitCode))" }
    $sshInstalled = $true
}
elseif ($zip) {
    # ZIP 手動：解壓 -> install-sshd -> host key -> 修 ACL
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
    Write-Host 'No OpenSSH installer staged (C:\DroidVM 無 msi/zip) -> 跳過 SSH，只設 RDP'
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

    # 確保 port 22 放行（MSI 通常自帶規則；用獨立名稱避免衝突/重複無害）
    if (-not (Get-NetFirewallRule -Name 'DroidVM-sshd' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'DroidVM-sshd' -DisplayName 'OpenSSH Server (sshd) [DroidVM]' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }
    Start-Service sshd
    Write-Host 'OpenSSH Server ready (port 22, auto-start).'
}

# ---- RDP 防火牆（fDenyTSConnections 已由 build.ps1 離線設 0）----
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
Write-Host 'RDP firewall enabled.'
