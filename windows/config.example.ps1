# === windows/build.ps1 config (PowerShell-native) ===
# Copy to windows\config.ps1 (gitignored), edit, then run build.ps1 - it dot-sources this file.
# Precedence: environment variable / CLI  >  this file  >  built-in default.
# (So an env var like  $env:SRC_ISO='...'  still overrides what you set here.)

# Win11 ARM64 ISO path (required)
$SRC_ISO = 'C:\iso\en-us_windows_11_iot_enterprise_ltsc_2024_arm64.iso'

# Driver source (one of):
#   1) GitHub repo URL -> auto-fetch that repo's 'dev' release driver zip (default)
#   2) local .zip path
#   3) local folder (one subfolder per driver, each with .inf/.sys/.cat)
# $DRIVERS_DIR = 'https://github.com/HuJK-Data/gunyah-guest-drivers-windows'

# Install image index (Win11 IoT Enterprise LTSC = 2)
# $IMAGE_INDEX = 2

# Virtual disk size (MB)
# $DISK_SIZE_MB = 40960

# Output qcow2 path (default: <repo root>\win11-droidvm-final.qcow2)
# $OUT_QCOW = 'C:\out\win11-droidvm-final.qcow2'

# Temp drive letters (omit to auto-pick free letters)
# $LETTER_ESP = 'S'
# $LETTER_WIN = 'W'
