<#
  build.ps1 - Offline build of a bootable, driver-included qcow2 from a Win11 ARM64 ISO + drivers.
  No Setup, no qemu boot: DISM apply-image + offline driver injection (no signature prompt) + bcdboot + bcdedit.
  First boot runs OOBE via unattend to create USER/autologon (non-interactive).

  Requirements: x64 Windows (Administrator); built-in dism/bcdboot/diskpart; qemu-img (QEMU for Windows, on PATH).
  Config: config.ps1 next to this script (copy from config.example.ps1) sets $SRC_ISO / $DRIVERS_DIR / ...
  Usage: run as Administrator, or  powershell -ExecutionPolicy Bypass -File build.ps1
  Cross-arch note: x64 host applying/injecting an ARM64 image + bcdboot usually works; if not, use ARM64 Windows/WinPE.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

# --- Command echo helpers: print the command before executing it ---
function Format-CommandArg([AllowNull()][object]$Arg) {
    if ($null -eq $Arg) { return "''" }
    $s = [string]$Arg
    if ($s -eq '') { return "''" }
    if ($s -match '^[A-Za-z0-9_./:\\=-]+$') { return $s }
    return "'" + ($s -replace "'", "''") + "'"
}

function Format-CommandLine([string]$Command, [object[]]$Arguments = @()) {
    $parts = @((Format-CommandArg $Command))
    foreach ($a in $Arguments) { $parts += (Format-CommandArg $a) }
    return ($parts -join ' ')
}

function Show-CommandLine([string]$Command, [object[]]$Arguments = @()) {
    Write-Host ("> " + (Format-CommandLine $Command $Arguments)) -ForegroundColor DarkCyan
}


# --- Requires Administrator (diskpart/dism/bcdboot/mount all need it) ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Administrator required, relaunching elevated..." -ForegroundColor Yellow
    Show-CommandLine "Start-Process" @("powershell", "-ExecutionPolicy Bypass -File `"$PSCommandPath`"", "-Verb", "RunAs")
    Start-Process powershell "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$HERE = $PSScriptRoot
$ROOT = Split-Path $HERE -Parent

# --- Load config.ps1 (PowerShell's native "source .env": dot-source a script that sets the
#     $SRC_ISO / $DRIVERS_DIR / ... variables). Copy config.example.ps1 -> config.ps1 and edit.
#     Precedence (resolved below): environment variable / CLI  >  config.ps1  >  built-in default. ---
$cfgFile = Join-Path $HERE "config.ps1"
if (Test-Path $cfgFile) { . $cfgFile }

# --- File-type input resolution: URL -> download into files\ then use; local path -> use directly; zip -> extract into files\ (goes through the file handling flow) ---
function Resolve-InputFile([string]$Src, [string]$SaveAs = "") {
    if ($Src -match '^https?://') {
        $files = Join-Path $ROOT "files"
        New-Item -ItemType Directory -Force $files | Out-Null
        if (-not $SaveAs) { $SaveAs = Split-Path ($Src -replace '\?.*$', '') -Leaf }
        $dst = Join-Path $files $SaveAs
        if (Test-Path $dst) { Write-Host "[files] already exists, skip download: $dst" }
        else {
            Write-Host "[files] download $Src -> $dst"
            Invoke-WebRequest -Uri $Src -OutFile "$dst.part" -UseBasicParsing
            Move-Item "$dst.part" $dst -Force
        }
        return $dst
    }
    if (-not (Test-Path $Src)) { throw "file not found: $Src" }
    return $Src
}

# Driver zip/folder source -> the "root directory" after extraction. DRIVER_DIR / DRIVER_CERT reference this root via the ZIP/ prefix (mirrors macOS).
function Resolve-ZipRoot([string]$Src) {
    $p = Resolve-InputFile $Src "gunyah-arm64-drivers.zip"
    if (Test-Path $p -PathType Container) { return $p }
    if ($p -like "*.zip") {
        $dir = Join-Path (Join-Path $ROOT "files") ([IO.Path]::GetFileNameWithoutExtension($p))
        if (Test-Path $dir) { Write-Host "[files] already extracted: $dir" }
        else { Write-Host "[files] extract $p -> $dir"; Expand-Archive $p -DestinationPath $dir -Force }
        return $dir
    }
    throw "driver source is neither a folder nor a zip: $p"
}

# Expand a leading ZIP prefix in DRIVER_DIR / DRIVER_CERT -> the zip extraction root (mirrors macOS's ${VAR/#ZIP/$ZIP}).
# e.g.: ZIP/drivers -> <root>\drivers; ZIP/DroidVM_Test.cer -> <root>\DroidVM_Test.cer; non-ZIP prefix -> unchanged.
function Expand-ZipToken([string]$Path, [string]$ZipRoot) {
    if (-not $Path) { return $Path }
    if ($Path -eq 'ZIP') { return $ZipRoot }
    # String concatenation (not Join-Path, to avoid 'C:' being resolved as a PSDrive); normalize slashes after ZIP to backslashes.
    if ($Path -match '^ZIP[\\/](.*)$') { return ($ZipRoot.TrimEnd('\', '/') + '\' + ($Matches[1] -replace '/', '\')) }
    return $Path
}

# --- Helpers ---
# Native commands (diskpart/dism/bcdboot/bcdedit/qemu-img) do NOT honor $ErrorActionPreference,
# so a non-zero exit is otherwise silently swallowed by "| Out-Null". Call this right after them.
function Assert-Exit([string]$what) {
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit code $LASTEXITCODE)" }
}

function Invoke-ExternalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [object[]]$ArgumentList = @(),
        [switch]$OutNull,
        [string]$What = ''
    )

    Show-CommandLine $FilePath $ArgumentList
    if ($OutNull) {
        & $FilePath @ArgumentList | Out-Null
    }
    else {
        & $FilePath @ArgumentList
    }

    if ($What) { Assert-Exit $What }
}

function Invoke-DiskPartScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [switch]$OutNull
    )

    Show-CommandLine "diskpart" @("/s", $Path)
    Write-Host "> diskpart script:" -ForegroundColor DarkCyan
    Get-Content $Path | ForEach-Object { Write-Host ("    " + $_) -ForegroundColor DarkCyan }

    if ($OutNull) {
        & diskpart /s $Path | Out-Null
    }
    else {
        & diskpart /s $Path
    }
}


# Pick a drive letter that is genuinely free. "Free" must also exclude letters that are merely
# RESERVED in MountedDevices (left behind by a previously detached VHDX) - diskpart refuses to
# 'assign' those with "The specified drive letter is not free to be assigned", even though no
# volume currently shows them.
function Get-FreeDriveLetter([string[]]$Exclude = @()) {
    $used = New-Object System.Collections.Generic.HashSet[string]
    foreach ($l in (Get-Volume -ErrorAction SilentlyContinue).DriveLetter) { if ($l) { [void]$used.Add("$l".ToUpper()) } }
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name) { if ($d.Length -eq 1) { [void]$used.Add($d.ToUpper()) } }
    try {
        $md = Get-Item 'HKLM:\SYSTEM\MountedDevices' -ErrorAction SilentlyContinue
        if ($md) { foreach ($p in $md.Property) { if ($p -match '^\\DosDevices\\([A-Z]):$') { [void]$used.Add($Matches[1]) } } }
    } catch {}
    foreach ($e in $Exclude) { [void]$used.Add("$e".ToUpper()) }
    foreach ($c in @('W', 'X', 'Y', 'Z', 'V', 'U', 'T', 'S', 'R', 'Q', 'P', 'N', 'M', 'L', 'K', 'J', 'H', 'G')) {
        if (-not $used.Contains($c)) { return $c }
    }
    throw "no free drive letter available"
}

# Resolve the install.wim image index. IMAGE_INDEX <= 0 -> list editions and let the user pick.
# Uses Get-WindowsImage (native objects: ImageIndex/ImageName/ImageSize) - no text parsing.
function Resolve-ImageIndex([string]$wim, [int]$wanted) {
    Show-CommandLine "Get-WindowsImage" @("-ImagePath", $wim)
    $images = @(Get-WindowsImage -ImagePath $wim)
    $valid = @($images | ForEach-Object { [int]$_.ImageIndex })
    if ($wanted -gt 0) {
        if ($valid -notcontains $wanted) {
            throw ("IMAGE_INDEX=$wanted not in this ISO. Available: " +
                (($images | ForEach-Object { "$($_.ImageIndex)=$($_.ImageName)" }) -join ', '))
        }
        return $wanted
    }
    if ($images.Count -eq 1) {
        Write-Host "[image] one edition only -> index $($valid[0]) ($($images[0].ImageName))"
        return $valid[0]
    }
    Write-Host "`nEditions in install.wim:" -ForegroundColor Cyan
    foreach ($im in $images) {
        Write-Host ("  [{0}] {1}  ({2:N1} GB)" -f $im.ImageIndex, $im.ImageName, ($im.ImageSize / 1GB))
    }
    if ([Console]::IsInputRedirected) {
        throw ("IMAGE_INDEX not set and no interactive console. Set IMAGE_INDEX to one of: " + ($valid -join ', '))
    }
    do {
        $sel = (Read-Host "`nSelect image index").Trim()
        $n = 0
        $ok = [int]::TryParse($sel, [ref]$n) -and ($valid -contains $n)
        if (-not $ok) { Write-Host ("  invalid, choose from: " + ($valid -join ', ')) -ForegroundColor DarkYellow }
    } while (-not $ok)
    return $n
}

# --- Resolve config: environment variable  >  config.ps1 value  >  built-in default ---
$SRC_ISO     = if ($env:SRC_ISO)     { $env:SRC_ISO }          elseif ($SRC_ISO)     { $SRC_ISO }          else { $null }
$DRIVERS_DIR = if ($env:DRIVERS_DIR) { $env:DRIVERS_DIR }      elseif ($DRIVERS_DIR) { $DRIVERS_DIR }      else { "https://github.com/Droid-VM/gunyah-guest-drivers-windows/releases/download/dev/gunyah-arm64-drivers.zip" }
$IMAGE_INDEX = if ($env:IMAGE_INDEX) { [int]$env:IMAGE_INDEX } elseif ($IMAGE_INDEX) { [int]$IMAGE_INDEX } else { 0 }       # 0 = list editions and prompt
$DISK_MB     = if ($env:DISK_SIZE_MB){ [int]$env:DISK_SIZE_MB }elseif ($DISK_SIZE_MB){ [int]$DISK_SIZE_MB }else { 40960 }
$OUT_QCOW    = if ($env:OUT_QCOW)    { $env:OUT_QCOW }         elseif ($OUT_QCOW)    { $OUT_QCOW }         else { Join-Path $ROOT "win11-droidvm-final.qcow2" }
$LETTER_ESP  = if ($env:LETTER_ESP)  { $env:LETTER_ESP }       elseif ($LETTER_ESP)  { $LETTER_ESP }       else { Get-FreeDriveLetter }
$LETTER_WIN  = if ($env:LETTER_WIN)  { $env:LETTER_WIN }       elseif ($LETTER_WIN)  { $LETTER_WIN }       else { Get-FreeDriveLetter @($LETTER_ESP) }
# Driver install list/cert (mirrors macOS): DRIVER_DIR=directory containing the per-driver subfolders (ZIP/ = driver zip extraction root);
# DRIVER_INSTALL=offline-inject only these subfolders (empty=all); DRIVER_CERT=specify the signing cert (empty=auto-extract from .cat).
$DRIVER_DIR     = if ($env:DRIVER_DIR)     { $env:DRIVER_DIR }     elseif ($DRIVER_DIR)     { $DRIVER_DIR }     else { "ZIP/drivers" }
$DRIVER_INSTALL = if ($env:DRIVER_INSTALL) { $env:DRIVER_INSTALL } elseif ($DRIVER_INSTALL) { $DRIVER_INSTALL } else { "" }
$DRIVER_CERT    = if ($env:DRIVER_CERT)    { $env:DRIVER_CERT }    elseif ($DRIVER_CERT)    { $DRIVER_CERT }    else { "" }
# Account name. Use $env:DVM_USERNAME (not the built-in Windows $env:USERNAME = the current logged-in user); the plain
# variable $USERNAME in config.ps1 also works. If neither is set -> defaults to USER.
$USERNAME     = if ($env:DVM_USERNAME) { $env:DVM_USERNAME } elseif ($USERNAME) { $USERNAME } else { "USER" }
# Account password: network logon for RDP/SSH does not accept a blank password (Windows default LimitBlankPasswordUse=1). Use $env:DVM_PASSWORD
# (the @@PASSWORD@@ token is injected into unattend.xml, see step 8; compatible with the old SSH_PASSWORD).
$PASSWORD     = if ($env:DVM_PASSWORD) { $env:DVM_PASSWORD } elseif ($env:SSH_PASSWORD) { $env:SSH_PASSWORD } elseif ($PASSWORD) { $PASSWORD } elseif ($SSH_PASSWORD) { $SSH_PASSWORD } else { "DroidVM" }
# SSH public key(s) (multiple allowed, newline-separated); empty = password login only. Passed via environment variable, not written to inputs\.
$SSH_PUBKEY   = if ($env:SSH_PUBKEY)   { $env:SSH_PUBKEY }      elseif ($SSH_PUBKEY)   { $SSH_PUBKEY }        else { "" }
# OpenSSH installer source: URL (downloaded at build time) or local path (copied). Defaults to the arm64 .msi. Empty string = do not install SSH (RDP only).
$OPENSSH_SRC  = if ($env:OPENSSH_SRC)  { $env:OPENSSH_SRC }     elseif ($OPENSSH_SRC)  { $OPENSSH_SRC }       else { "https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-ARM64-v10.0.0.0.msi" }
Write-Host "[disk] drive letters: ESP=$LETTER_ESP Windows=$LETTER_WIN"

foreach ($t in @("dism", "bcdboot", "diskpart", "qemu-img")) {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { throw "$t not found (qemu-img needs QEMU for Windows installed and on PATH)" }
}
if (-not $SRC_ISO) { throw "Invalid SRC_ISO: set the Win11 ARM64 ISO (URL or local path) in config.ps1 / build_from_zip.ps1" }
$SRC_ISO = Resolve-InputFile $SRC_ISO "win11-arm64.iso"

$WORK = Join-Path $env:TEMP ("droidvm-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
Show-CommandLine "New-Item" @("-ItemType", "Directory", "-Force", $WORK)
New-Item -ItemType Directory -Force $WORK | Out-Null
$VHDX = Join-Path $WORK "w11.vhdx"
$isoMounted = $false; $vhdAttached = $false

function Cleanup {
    if ($script:vhdAttached) {
        # Release the drive letters first so they don't linger as stale MountedDevices reservations
        # that would make a later run's diskpart 'assign' fail. Best-effort.
        foreach ($L in @($script:LETTER_ESP, $script:LETTER_WIN)) {
            if ($L) {
                Show-CommandLine "cmd" @("/c", "mountvol ${L}: /D")
                & cmd /c "mountvol ${L}: /D" 2>$null | Out-Null
            }
        }
        $s = "select vdisk file=`"$VHDX`"`r`ndetach vdisk`r`nexit"
        $f = Join-Path $WORK "detach.txt"
        $s | Out-File -Encoding ascii $f
        Invoke-DiskPartScript -Path $f -OutNull
    }
    if ($script:isoMounted) {
        Show-CommandLine "Dismount-DiskImage" @("-ImagePath", $SRC_ISO)
        Dismount-DiskImage -ImagePath $SRC_ISO | Out-Null
    }
}

try {
    # === 1) Resolve driver source (URL -> download to files\; local zip/folder -> use directly; zip -> extract to files\) ===
    # Driver zip -> extraction root (ZIP); the ZIP/ prefix in DRIVER_DIR/DRIVER_CERT expands to that root directory.
    $zipRoot     = Resolve-ZipRoot $DRIVERS_DIR
    $DRIVER_DIR  = Expand-ZipToken $DRIVER_DIR  $zipRoot
    $DRIVER_CERT = Expand-ZipToken $DRIVER_CERT $zipRoot
    if (-not (Test-Path $DRIVER_DIR -PathType Container)) { throw "driver folder DRIVER_DIR not found: $DRIVER_DIR" }
    if ($DRIVER_CERT -and -not (Test-Path $DRIVER_CERT)) { throw "DRIVER_CERT not found: $DRIVER_CERT" }
    $drvDir = $DRIVER_DIR
    $instShow = if ($DRIVER_INSTALL) { $DRIVER_INSTALL } else { "(all)" }
    $certShow = if ($DRIVER_CERT) { Split-Path $DRIVER_CERT -Leaf } else { "(auto from .cat)" }
    Write-Host "[drivers] dir=$drvDir  install=$instShow  cert=$certShow"

    # === 2) Mount ISO, get install.wim, resolve image index ===
    Show-CommandLine "Mount-DiskImage" @("-ImagePath", $SRC_ISO, "-PassThru")
    $mr = Mount-DiskImage -ImagePath $SRC_ISO -PassThru; $isoMounted = $true
    $isoLetter = ($mr | Get-Volume).DriveLetter
    $wim = "${isoLetter}:\sources\install.wim"
    if (-not (Test-Path $wim)) { throw "$wim not found in ISO" }
    Write-Host "[iso] $SRC_ISO"
    $IMAGE_INDEX = Resolve-ImageIndex $wim $IMAGE_INDEX
    Write-Host "[image] using index $IMAGE_INDEX"

    # === 3) Create + attach VHDX, GPT partition: ESP(FAT32) + MSR + Windows(NTFS) ===
    Write-Host "[disk] creating and partitioning VHDX ..."
    $dp = @"
create vdisk file="$VHDX" maximum=$DISK_MB type=expandable
select vdisk file="$VHDX"
attach vdisk
convert gpt
create partition efi size=260
format fs=fat32 quick label=System
assign letter=$LETTER_ESP
create partition msr size=16
create partition primary
format fs=ntfs quick label=Windows
assign letter=$LETTER_WIN
exit
"@
    $dpFile = Join-Path $WORK "part.txt"
    $dp | Out-File -Encoding ascii $dpFile
    # diskpart exits 0 even when an 'assign letter' fails, so verify the volumes actually mounted.
    $dpOut = Invoke-DiskPartScript -Path $dpFile; $vhdAttached = $true
    $W = "${LETTER_WIN}:"; $S = "${LETTER_ESP}:"
    if (-not (Test-Path "$S\") -or -not (Test-Path "$W\")) {
        throw "diskpart did not mount $S and/or $W (likely a stale drive-letter reservation; set LETTER_ESP/LETTER_WIN to other letters). diskpart output:`n$(( $dpOut | Out-String ).Trim())"
    }

    # === 4) Apply image ===
    Write-Host "[dism] applying install.wim -> $W\ ..."
    Invoke-ExternalCommand -FilePath "dism" -ArgumentList @("/Apply-Image", "/ImageFile:$wim", "/Index:$IMAGE_INDEX", "/ApplyDir:$W\") -OutNull -What "dism /Apply-Image"

    # === 5) Offline driver injection (no signature prompt) ===
    # Offline-inject only the driver subfolders listed in DRIVER_INSTALL (empty=the whole $drvDir /Recurse). /ForceUnsigned skips the signature prompt.
    # Note: boot-critical drivers (viostor/vioscsi) must be included in DRIVER_INSTALL, otherwise the image will not boot.
    if ($DRIVER_INSTALL) {
        foreach ($d in ($DRIVER_INSTALL -split '\s+' | Where-Object { $_ })) {
            $sub = Join-Path $drvDir $d
            if (Test-Path $sub -PathType Container) {
                Write-Host "[dism] inject driver: $d"
                Invoke-ExternalCommand -FilePath "dism" -ArgumentList @("/Image:$W\", "/Add-Driver", "/Driver:$sub", "/Recurse", "/ForceUnsigned") -OutNull -What "dism /Add-Driver $d"
            } else { Write-Host "  [warn] driver $d to install does not exist in $drvDir" -ForegroundColor DarkYellow }
        }
    } else {
        Write-Host "[dism] injecting all drivers offline ..."
        Invoke-ExternalCommand -FilePath "dism" -ArgumentList @("/Image:$W\", "/Add-Driver", "/Driver:$drvDir", "/Recurse", "/ForceUnsigned") -OutNull -What "dism /Add-Driver"
    }

    # === 5b) Extract driver signer certs (offline) -> stage for first-boot trust ===
    # Offline injection (/ForceUnsigned) needs no cert, but that only lets "this batch" of drivers install. Later "interactive" driver updates
    # (Device Manager / pnputil / vendor installer) check TrustedPublisher; if the cert is absent -> the "cannot verify
    # publisher" prompt appears. Here we extract each distinct signer from the .cat, staging them to C:\DroidVM\certs, and unattend specialize then
    # imports them into Root+TrustedPublisher (mirrors macos/autounattend.xml). Note: this only removes the "install prompt"; self-signed drivers
    # still rely on BCD testsigning (step 7) to load at boot, so do not turn testsigning off because of this.
    Write-Host "[certs] staging driver signer cert(s) offline ..."
    $certDir = "$W\DroidVM\certs"
    New-Item -ItemType Directory -Force $certDir | Out-Null
    if ($DRIVER_CERT) {
        # Specified cert: just place it, and unattend specialize imports it into Root+TrustedPublisher (mirrors macOS's DRIVER_CERT).
        Copy-Item $DRIVER_CERT (Join-Path $certDir (Split-Path $DRIVER_CERT -Leaf)) -Force
        Write-Host "[certs] using the specified DRIVER_CERT: $(Split-Path $DRIVER_CERT -Leaf)"
    } else {
        # Not specified -> auto-extract every unique signer from the driver .cat/.sys
        # (.cat is most reliable: for catalog-signed drivers the .sys shows as unsigned when the catalog is not registered on the host, but the .cat itself reveals the signer)
        $seenThumb = @{}
        Get-ChildItem $drvDir -Recurse -Include *.cat, *.sys, *.dll, *.exe -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $cert = (Get-AuthenticodeSignature $_.FullName).SignerCertificate
                if ($cert -and -not $seenThumb.ContainsKey($cert.Thumbprint)) {
                    $seenThumb[$cert.Thumbprint] = $true
                    Export-Certificate -Cert $cert -FilePath (Join-Path $certDir "$($cert.Thumbprint).cer") | Out-Null
                }
            } catch {}
        }
        # Also collect any *.cer bundled directly in the driver package (e.g. DroidVM_Test.cer)
        Get-ChildItem $drvDir -Recurse -Filter *.cer -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName (Join-Path $certDir $_.Name) -Force }
        Write-Host "[certs] auto-extracted $($seenThumb.Count) cert(s) from driver .cat -> $certDir"
    }

    # === 6) Debloat (offline removal of provisioned Appx) ===
    Write-Host "[debloat] removing extra provisioned Appx offline ..."
    $keep = 'VCLibs|NET\.Native|UI\.Xaml|Store|SecHealth|Photos|Notepad|Terminal|WindowsTerminal'
    try {
        Get-AppxProvisionedPackage -Path "$W\" | Where-Object { $_.DisplayName -notmatch $keep } | ForEach-Object {
            try {
                Show-CommandLine "Remove-AppxProvisionedPackage" @("-Path", "$W\", "-PackageName", $_.PackageName)
                Remove-AppxProvisionedPackage -Path "$W\" -PackageName $_.PackageName | Out-Null
            } catch {}
        }
    } catch { Write-Host "  (skipping debloat: $($_.Exception.Message))" -ForegroundColor DarkYellow }

    # === 6b) Offline shrink: WinSxS ResetBase + disable hibernate ===
    # Mirrors the macOS debloat's WinSxS compaction and hibernate disable, here using the offline version (no boot needed).
    # Purely to shrink the image; failure does not affect usability, so everything is set as non-fatal.
    Write-Host "[debloat] WinSxS component cleanup (ResetBase, offline) ..."
    try {
        Invoke-ExternalCommand -FilePath "dism" -ArgumentList @("/Image:$W\", "/Cleanup-Image", "/StartComponentCleanup", "/ResetBase") -OutNull -What "dism /Cleanup-Image /ResetBase"
    } catch {
        Write-Host "  (skipping ResetBase: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }

    Write-Host "[debloat] disabling hibernate offline (no hiberfil.sys) ..."
    # Offline edit of the SYSTEM hive: HibernateEnabled=0 -> first boot will not create hiberfil.sys.
    $sysHive = "$W\Windows\System32\config\SYSTEM"
    $hiveLoaded = $false
    try {
        Invoke-ExternalCommand -FilePath "reg" -ArgumentList @("load", "HKLM\DVMOFF", $sysHive) -OutNull -What "reg load SYSTEM hive"
        $hiveLoaded = $true
        foreach ($cs in @("ControlSet001", "ControlSet002")) {
            $pk = "HKLM\DVMOFF\$cs\Control\Power"
            reg query $pk *> $null
            if ($LASTEXITCODE -eq 0) {
                Show-CommandLine "reg add" @($pk, "/v", "HibernateEnabled", "/t", "REG_DWORD", "/d", "0", "/f")
                reg add $pk /v HibernateEnabled        /t REG_DWORD /d 0 /f *> $null
                reg add $pk /v HibernateEnabledDefault /t REG_DWORD /d 0 /f *> $null
            }
            # Enable RDP (offline): fDenyTSConnections=0. The firewall rule is opened separately at first boot by setup-ssh.ps1.
            $tk = "HKLM\DVMOFF\$cs\Control\Terminal Server"
            reg query $tk *> $null
            if ($LASTEXITCODE -eq 0) {
                Show-CommandLine "reg add" @($tk, "/v", "fDenyTSConnections", "/t", "REG_DWORD", "/d", "0", "/f")
                reg add $tk /v fDenyTSConnections /t REG_DWORD /d 0 /f *> $null
            }
        }
    } catch {
        Write-Host "  (skipping hibernate-off: $($_.Exception.Message))" -ForegroundColor DarkYellow
    } finally {
        # The hive must be unloaded, otherwise step 9 dismount VHDX will fail.
        if ($hiveLoaded) {
            [gc]::Collect(); [gc]::WaitForPendingFinalizers()
            reg unload HKLM\DVMOFF *> $null
        }
    }

    # === 7) Boot files + BCD (bcdboot uses the ARM64 bootmgr from the image) ===
    Write-Host "[boot] bcdboot + BCD ..."
    Invoke-ExternalCommand -FilePath "bcdboot" -ArgumentList @("$W\Windows", "/s", $S, "/f", "UEFI") -OutNull -What "bcdboot"
    $BCD = "$S\EFI\Microsoft\Boot\BCD"
    Invoke-ExternalCommand -FilePath "bcdedit" -ArgumentList @("/store", $BCD, "/set", "{default}", "testsigning", "on") -OutNull -What "bcdedit testsigning"
    Invoke-ExternalCommand -FilePath "bcdedit" -ArgumentList @("/store", $BCD, "/set", "{default}", "nointegritychecks", "on") -OutNull -What "bcdedit nointegritychecks"

    # === 8) OOBE unattend (create USER / autologon) ===
    Show-CommandLine "New-Item" @("-ItemType", "Directory", "-Force", "$W\Windows\Panther")
    New-Item -ItemType Directory -Force "$W\Windows\Panther" | Out-Null
    $unattendSrc = Join-Path $HERE "unattend.xml"
    # Inject account/password (@@USERNAME@@ / @@PASSWORD@@ tokens). XML-escape keeps the XML valid when the credentials contain &<>"
    # (mirrors the macOS perl version). Write UTF-8 without BOM via .NET, matching the original file.
    $esc = { param($s) $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;') }
    $unattendXml = (Get-Content $unattendSrc -Raw).Replace('@@USERNAME@@', (& $esc $USERNAME)).Replace('@@PASSWORD@@', (& $esc $PASSWORD))
    Show-CommandLine "Set-Content" @("$W\Windows\Panther\unattend.xml", "(unattend.xml + password)")
    [System.IO.File]::WriteAllText("$W\Windows\Panther\unattend.xml", $unattendXml, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "[oobe] unattend.xml placed (first boot creates USER, autologon, imports certs)"

    # === 8c) Stage SSH payload into image (offline) ===
    # setup-ssh.ps1 is run by unattend FirstLogonCommands at first boot (installing the sshd service requires online registration).
    $stage = "$W\DroidVM"
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item (Join-Path $HERE "setup-ssh.ps1") "$stage\setup-ssh.ps1" -Force
    # pvmpower devnode: pvmpower.sys binds to the root-enumerated ROOT\PVMPOWER, so the devnode must be created at first boot via SetupAPI
    # (INF/DISM injection does not create a devnode). Stage it if the driver zip has it, skip if not (older drivers lack pvmpower, which is normal).
    $pvmDevnode = Join-Path $zipRoot "pvmpower-devnode.ps1"
    if (Test-Path $pvmDevnode) { Copy-Item $pvmDevnode "$stage\pvmpower-devnode.ps1" -Force; Write-Host "[pvmpower] staged pvmpower-devnode.ps1" }
    # OpenSSH installer: $OPENSSH_SRC can be a URL (downloaded to files\) or a local path; empty = do not install SSH. After resolving, copy it into the image.
    # An arm64 .msi is recommended (sets up service/host key/firewall in one step); .zip is also accepted. Non-fatal: if it cannot be obtained, only RDP is set up.
    if ($OPENSSH_SRC) {
        try {
            $sshLocal = Resolve-InputFile $OPENSSH_SRC
            Copy-Item $sshLocal (Join-Path $stage (Split-Path $sshLocal -Leaf)) -Force
            Write-Host "[ssh] staged $(Split-Path $sshLocal -Leaf)"
        } catch {
            Write-Host "[ssh] OpenSSH staging failed -> RDP only: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "[ssh] `$OPENSSH_SRC empty -> do not install SSH (RDP only)" -ForegroundColor DarkYellow
    }
    # authorized_keys is provided by the $SSH_PUBKEY environment variable (multiple keys newline-separated), UTF-8 without BOM + LF.
    if ($SSH_PUBKEY) {
        $akText = ($SSH_PUBKEY -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd("`n") + "`n"
        [System.IO.File]::WriteAllText("$stage\authorized_keys", $akText, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "[ssh] staged authorized_keys from `$SSH_PUBKEY (key login)"
    } else {
        Write-Host "[ssh] `$SSH_PUBKEY not set -> password login only" -ForegroundColor DarkYellow
    }

    # === 8b) ReTrim so debloat/cleanup actually shrinks the image ===
    # Mirrors macOS's Optimize-Volume -ReTrim: unmaps the clusters freed above by debloat/ResetBase.
    # Otherwise, although that space is marked free in NTFS, the VHDX still holds the old data (non-zero),
    # and step 9 qemu-img convert would copy it into the qcow2 too -> no shrink.
    Write-Host "[shrink] Optimize-Volume -ReTrim on $W ..."
    try {
        Show-CommandLine "Optimize-Volume" @("-DriveLetter", $LETTER_WIN, "-ReTrim")
        Optimize-Volume -DriveLetter $LETTER_WIN -ReTrim -ErrorAction Stop
    } catch {
        Write-Host "  (ReTrim skipped: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }

    # === 9) Detach VHDX -> convert to qcow2 ===
    Cleanup; $vhdAttached = $false; $isoMounted = $false
    Write-Host "[qcow2] converting -> $OUT_QCOW ..."
    Invoke-ExternalCommand -FilePath "qemu-img" -ArgumentList @("convert", "-p", "-O", "qcow2", $VHDX, $OUT_QCOW) -What "qemu-img convert"
    $sz = "{0:N1} GB" -f ((Get-Item $OUT_QCOW).Length / 1GB)
    Write-Host "Done  -> $OUT_QCOW ($sz)" -ForegroundColor Green
}
finally {
    Cleanup
    Show-CommandLine "Remove-Item" @("-Recurse", "-Force", $WORK, "-ErrorAction", "SilentlyContinue")
    Remove-Item -Recurse -Force $WORK -ErrorAction SilentlyContinue
}
