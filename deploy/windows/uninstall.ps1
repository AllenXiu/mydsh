# uninstall.ps1 - stop booting from this repo\s deploy/windows chain.
# Removes the Startup VBS written by install.ps1. Repo files are left intact.
# Run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File deploy/windows/uninstall.ps1
$ErrorActionPreference = 'Continue'
$startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$vbs = Join-Path $startup 'dsh-web-autostart.vbs'
if (Test-Path $vbs) {
  Remove-Item $vbs -Force
  Write-Host "removed Startup entry: $vbs"
} else {
  Write-Host 'no Startup entry found (already removed?)'
}
