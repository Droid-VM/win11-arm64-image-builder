<#
  setup-ssh.ps1 — installs OpenSSH Server on first boot (as the created administrator account):
    - arm64 .msi preferred (one-click installs service/host key/ACL), .zip fallback (install-sshd + ssh-keygen -A + FixHostFilePermissions)
    - authorized_keys -> C:\ProgramData\ssh\administrators_authorized_keys (the administrator key path) + tighten ACL
    - Open the SSH(22) firewall, start sshd (auto-start on boot)
  The installer and keys are staged to C:\DroidVM\ by 02-make-iso.sh; the public key source is SSH_PUBKEY from build_runme.sh.
  When no OpenSSH installer is present, simply skip it (not fatal).
#>
$ErrorActionPreference = 'Stop'

$msi = Get-ChildItem 'C:\DroidVM' -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
$zip = Get-ChildItem 'C:\DroidVM' -Filter '*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
$sshInstalled = $false

if ($msi) {
    $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$($msi.FullName)`"", '/qn', '/norestart') -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "msiexec failed (exit $($p.ExitCode))" }
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
    Write-Host 'No OpenSSH installer staged (no msi/zip in C:\DroidVM) -> skip SSH'
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

    if (-not (Get-NetFirewallRule -Name 'DroidVM-sshd' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'DroidVM-sshd' -DisplayName 'OpenSSH Server (sshd) [DroidVM]' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }
    Start-Service sshd
    Write-Host 'OpenSSH Server ready (port 22, auto-start).'
}

# ---- RDP: enable Remote Desktop (FirstLogon runs with SYSTEM/administrator privileges, so HKLM is writable) ----
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0 -Type DWord -Force
# NLA on is more secure; for plain password without NLA, change the line below to 0
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1 -Type DWord -Force
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
Set-Service TermService -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service TermService -ErrorAction SilentlyContinue
# Add the current account (the FirstLogon runner) to Remote Desktop Users. Administrators can already RDP, so this is a safeguard / for clarity,
# and is required if the account is not an administrator. It errors when already a member/administrator, which is harmless, so it is ignored.
net localgroup "Remote Desktop Users" "$env:USERNAME" /add 2>$null | Out-Null
Write-Host 'RDP enabled (port 3389).'
