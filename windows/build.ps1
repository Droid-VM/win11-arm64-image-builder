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

# --- 檔案類輸入解析：URL -> 下載到 files\ 再用；本地路徑 -> 直接用；zip -> 解壓到 files\（使用檔案的內部流程）---
function Resolve-InputFile([string]$Src, [string]$SaveAs = "") {
    if ($Src -match '^https?://') {
        $files = Join-Path $ROOT "files"
        New-Item -ItemType Directory -Force $files | Out-Null
        if (-not $SaveAs) { $SaveAs = Split-Path ($Src -replace '\?.*$', '') -Leaf }
        $dst = Join-Path $files $SaveAs
        if (Test-Path $dst) { Write-Host "[files] 已存在，略過下載: $dst" }
        else {
            Write-Host "[files] 下載 $Src -> $dst"
            Invoke-WebRequest -Uri $Src -OutFile "$dst.part" -UseBasicParsing
            Move-Item "$dst.part" $dst -Force
        }
        return $dst
    }
    if (-not (Test-Path $Src)) { throw "找不到檔案: $Src" }
    return $Src
}

function Resolve-DriverDir([string]$Src) {
    $p = Resolve-InputFile $Src "gunyah-arm64-drivers.zip"
    if (Test-Path $p -PathType Container) { $dir = $p }
    elseif ($p -like "*.zip") {
        $dir = Join-Path (Join-Path $ROOT "files") ([IO.Path]::GetFileNameWithoutExtension($p))
        if (Test-Path $dir) { Write-Host "[files] 已解壓: $dir" }
        else { Write-Host "[files] 解壓 $p -> $dir"; Expand-Archive $p -DestinationPath $dir -Force }
    }
    else { throw "驅動來源不是資料夾也不是 zip: $p" }
    if (Test-Path (Join-Path $dir "drivers")) { $dir = Join-Path $dir "drivers" }   # zip 頂層常是 drivers/
    if (-not (Get-ChildItem $dir -Recurse -Filter *.inf -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        throw "no .inf found in driver folder: $dir"
    }
    return $dir
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
# 給 USER 的密碼：RDP/SSH 的網路登入不接受空密碼（Windows 預設 LimitBlankPasswordUse=1），
# 所以一定要有真密碼。用 @@PASSWORD@@ token 注入 unattend.xml（見第 8 步）。改這裡或設 env/config。
$SSH_PASSWORD = if ($env:SSH_PASSWORD) { $env:SSH_PASSWORD }   elseif ($SSH_PASSWORD) { $SSH_PASSWORD }     else { "DroidVM" }
# SSH 公鑰（可多把，用換行分隔）；空 = 只密碼登入。走環境變數，不落地到 inputs\。
$SSH_PUBKEY   = if ($env:SSH_PUBKEY)   { $env:SSH_PUBKEY }      elseif ($SSH_PUBKEY)   { $SSH_PUBKEY }        else { "" }
# OpenSSH 安裝檔來源：URL(build 時下載) 或本地路徑(複製)。預設抓 arm64 .msi。空字串 = 不裝 SSH(僅 RDP)。
$OPENSSH_SRC  = if ($env:OPENSSH_SRC)  { $env:OPENSSH_SRC }     elseif ($OPENSSH_SRC)  { $OPENSSH_SRC }       else { "https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-ARM64-v10.0.0.0.msi" }
Write-Host "[disk] drive letters: ESP=$LETTER_ESP Windows=$LETTER_WIN"

foreach ($t in @("dism", "bcdboot", "diskpart", "qemu-img")) {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { throw "$t not found (qemu-img needs QEMU for Windows installed and on PATH)" }
}
if (-not $SRC_ISO) { throw "Invalid SRC_ISO: set the Win11 ARM64 ISO (URL 或本地路徑) in config.ps1 / build_from_zip.ps1" }
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
    # === 1) Resolve driver source (URL -> files\ 下載; 本地 zip/資料夾 -> 直接用; zip -> 解壓到 files\) ===
    $drvDir = Resolve-DriverDir $DRIVERS_DIR
    Write-Host "[drivers] using: $drvDir"

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
    Write-Host "[dism] injecting drivers offline ..."
    Invoke-ExternalCommand -FilePath "dism" -ArgumentList @("/Image:$W\", "/Add-Driver", "/Driver:$drvDir", "/Recurse", "/ForceUnsigned") -OutNull -What "dism /Add-Driver"

    # === 5b) Extract driver signer certs (offline) -> stage for first-boot trust ===
    # 離線注入(/ForceUnsigned)不需憑證，但那只讓「這批」驅動裝得進去。日後「互動式」更新驅動
    # (Device Manager / pnputil / 廠商 installer) 會比對 TrustedPublisher；憑證不在 -> 跳「無法驗證
    # 發行者」。這裡從 .cat 萃取每個獨立簽章者，staging 到 C:\DroidVM\certs，unattend specialize 再
    # 匯入 Root+TrustedPublisher(對照 macos/autounattend.xml)。注意：這只消掉「安裝提示」，自簽驅動
    # 開機載入仍靠 BCD testsigning(第 7 步)，不能因此關掉 testsigning。
    Write-Host "[certs] extracting driver signer certs offline ..."
    $certDir = "$W\DroidVM\certs"
    New-Item -ItemType Directory -Force $certDir | Out-Null
    $seenThumb = @{}
    # .cat 最可靠：catalog-signed 驅動的 .sys 在 host 上未註冊 catalog 會顯示未簽，.cat 本身讀得到簽章者
    Get-ChildItem $drvDir -Recurse -Include *.cat, *.sys, *.dll, *.exe -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $cert = (Get-AuthenticodeSignature $_.FullName).SignerCertificate
            if ($cert -and -not $seenThumb.ContainsKey($cert.Thumbprint)) {
                $seenThumb[$cert.Thumbprint] = $true
                Export-Certificate -Cert $cert -FilePath (Join-Path $certDir "$($cert.Thumbprint).cer") | Out-Null
            }
        } catch {}
    }
    # 也收 driver 包內直接附的 *.cer（如 DroidVM_Test.cer）
    Get-ChildItem $drvDir -Recurse -Filter *.cer -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item $_.FullName (Join-Path $certDir $_.Name) -Force }
    Write-Host "[certs] staged $($seenThumb.Count) signer cert(s) -> $certDir"

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
    # 對應 macOS debloat 的 WinSxS 壓實與關 hibernate，這裡用離線版（不需開機）。
    # 純為縮小映像，失敗不影響可用性，故全部設為非致命。
    Write-Host "[debloat] WinSxS component cleanup (ResetBase, offline) ..."
    try {
        Invoke-ExternalCommand -FilePath "dism" -ArgumentList @("/Image:$W\", "/Cleanup-Image", "/StartComponentCleanup", "/ResetBase") -OutNull -What "dism /Cleanup-Image /ResetBase"
    } catch {
        Write-Host "  (skipping ResetBase: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }

    Write-Host "[debloat] disabling hibernate offline (no hiberfil.sys) ..."
    # 離線改 SYSTEM hive：HibernateEnabled=0 -> 首次開機不會建立 hiberfil.sys。
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
            # 啟用 RDP（離線）：fDenyTSConnections=0。防火牆規則另在首次開機由 setup-ssh.ps1 開啟。
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
        # hive 一定要 unload，否則第 9 步 dismount VHDX 會失敗。
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
    # 注入 USER 密碼（@@PASSWORD@@ token）。用 .NET 寫 UTF-8 無 BOM，跟原檔一致。
    $unattendXml = (Get-Content $unattendSrc -Raw).Replace('@@PASSWORD@@', $SSH_PASSWORD)
    Show-CommandLine "Set-Content" @("$W\Windows\Panther\unattend.xml", "(unattend.xml + password)")
    [System.IO.File]::WriteAllText("$W\Windows\Panther\unattend.xml", $unattendXml, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "[oobe] unattend.xml placed (first boot creates USER, autologon, imports certs)"

    # === 8c) Stage SSH payload into image (offline) ===
    # setup-ssh.ps1 由 unattend FirstLogonCommands 於首次開機執行（裝 sshd 服務需線上註冊）。
    $stage = "$W\DroidVM"
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item (Join-Path $HERE "setup-ssh.ps1") "$stage\setup-ssh.ps1" -Force
    # OpenSSH 安裝檔：$OPENSSH_SRC 可為 URL(下載到 files\) 或本地路徑；空 = 不裝 SSH。解析後複製進映像。
    # 建議 arm64 .msi（一鍵裝好服務/host key/防火牆），也接受 .zip。非致命：拿不到就只設 RDP。
    if ($OPENSSH_SRC) {
        try {
            $sshLocal = Resolve-InputFile $OPENSSH_SRC
            Copy-Item $sshLocal (Join-Path $stage (Split-Path $sshLocal -Leaf)) -Force
            Write-Host "[ssh] staged $(Split-Path $sshLocal -Leaf)"
        } catch {
            Write-Host "[ssh] OpenSSH staging 失敗 -> 只設 RDP：$($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "[ssh] `$OPENSSH_SRC 空 -> 不裝 SSH（僅 RDP）" -ForegroundColor DarkYellow
    }
    # authorized_keys 由環境變數 $SSH_PUBKEY 提供（多把金鑰換行分隔），UTF-8 無 BOM + LF。
    if ($SSH_PUBKEY) {
        $akText = ($SSH_PUBKEY -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd("`n") + "`n"
        [System.IO.File]::WriteAllText("$stage\authorized_keys", $akText, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "[ssh] staged authorized_keys from `$SSH_PUBKEY (金鑰登入)"
    } else {
        Write-Host "[ssh] `$SSH_PUBKEY 未設 -> 僅密碼登入" -ForegroundColor DarkYellow
    }

    # === 8b) ReTrim so debloat/cleanup actually shrinks the image ===
    # 對應 macOS 的 Optimize-Volume -ReTrim：把上面 debloat/ResetBase 釋放的 cluster
    # unmap 掉。否則那些空間在 NTFS 雖標記 free，VHDX 裡仍是舊資料（非零），
    # 第 9 步 qemu-img convert 會把它們一起複製進 qcow2 → 縮不掉。
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
