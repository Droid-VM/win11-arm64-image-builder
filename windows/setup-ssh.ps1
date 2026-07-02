<#
  setup-ssh.ps1 — runs on first boot (as USER, with administrator privileges):
    - Install OpenSSH Server: prefer the arm64 .msi (one-click installs service/host key/ACL/firewall), otherwise the arm64 .zip (the manual approach)
    - authorized_keys -> C:\ProgramData\ssh\administrators_authorized_keys (the administrator key path) + tighten ACL
    - Open the SSH(22) and RDP firewall (RDP fDenyTSConnections already set to 0 offline by build.ps1)
  The installer and keys are staged to C:\DroidVM\ by step 8c of build.ps1; the key source is the environment variable $SSH_PUBKEY.
  When no OpenSSH installer is present, only RDP is configured, which is not fatal.
#>
$ErrorActionPreference = 'Stop'

$msi = Get-ChildItem 'C:\DroidVM' -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
$zip = Get-ChildItem 'C:\DroidVM' -Filter '*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
$sshInstalled = $false

if ($msi) {
    # MSI one-click: install binaries + register sshd/ssh-agent services + generate host key + fix ACL + create firewall rule
    $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$($msi.FullName)`"", '/qn', '/norestart') -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "msiexec failed (exit $($p.ExitCode))" }
    $sshInstalled = $true
}
elseif ($zip) {
    # ZIP manual: extract -> install-sshd -> host key -> fix ACL
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
    Write-Host 'No OpenSSH installer staged (no msi/zip in C:\DroidVM) -> skip SSH, configure RDP only'
}

if ($sshInstalled) {
    Set-Service sshd      -StartupType Automatic
    Set-Service ssh-agent -StartupType Automatic -ErrorAction SilentlyContinue

    # An administrator account key is not read from the home directory but from administrators_authorized_keys, and the ACL must contain only SYSTEM+Administrators
    if (Test-Path 'C:\DroidVM\authorized_keys') {
        $ak = 'C:\ProgramData\ssh\administrators_authorized_keys'
        New-Item -ItemType Directory -Force (Split-Path $ak) | Out-Null
        Copy-Item 'C:\DroidVM\authorized_keys' $ak -Force
        icacls $ak /inheritance:r /grant 'Administrators:F' 'SYSTEM:F' | Out-Null
    }

    # Ensure port 22 is allowed (MSI usually ships its own rule; use a separate name to avoid conflicts / duplicates are harmless)
    if (-not (Get-NetFirewallRule -Name 'DroidVM-sshd' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'DroidVM-sshd' -DisplayName 'OpenSSH Server (sshd) [DroidVM]' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }
    Start-Service sshd
    Write-Host 'OpenSSH Server ready (port 22, auto-start).'
}

# ---- RDP firewall (fDenyTSConnections already set to 0 offline by build.ps1) ----
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
Write-Host 'RDP firewall enabled.'
