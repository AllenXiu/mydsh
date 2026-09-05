# dsh-web-update.ps1
# Windows port of deploy/macos/dsh-web-confirm-update.sh:
# on every dsh web start, compare the installed official dsh with the npm
# release. If a newer one exists, run the plugin compat pre-check and ASK the
# human (MessageBox). "Yes" uninstalls every conflicting plugin, then upgrades.
# Never silently upgrades behind the user's back.
#
# Exit: 0 = up-to-date OR user chose skip OR registry unreachable
#       1 = an update was performed (caller may restart the web server)
param([string]$Tag = 'latest')

$ErrorActionPreference = 'Continue'
$homeDir = $env:USERPROFILE
$log = Join-Path $homeDir '.dsh\autostart-update.log'
$profileDir = Join-Path $homeDir '.dsh\profiles\web'
# compat-check is the single cross-platform source at <repo>\deploy\shared\;
# the Windows boot chain (and the macOS install) both read it from there, so a
# git pull ships new pre-check logic to both platforms together.
$compatCheck = Join-Path (Split-Path -Parent $PSScriptRoot) 'shared\dsh-web-plugin-compat-check.mjs'

# --- make sure node/npm/dsh are reachable (autostart PATH may lack them) ---
$nodeBin = $null
try { $nodeBin = Split-Path (Get-Command node -ErrorAction Stop).Source } catch {}
if (-not $nodeBin) {
  foreach ($c in @("$env:ProgramFiles\nodejs", "${env:ProgramFiles(x86)}\nodejs", "$env:LOCALAPPDATA\Programs\nodejs")) {
    if (Test-Path (Join-Path $c 'node.exe')) { $nodeBin = $c; break }
  }
}
if ($nodeBin -and ($env:Path -notlike "*$nodeBin*")) { $env:Path = "$nodeBin;$env:Path" }

function Log($m) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  try {
    Add-Content -Path $log -Value $line -Encoding UTF8 -ErrorAction Stop
  } catch {
    # log is held by the running web batch (only when invoked while web is up);
    # logging is best-effort in that case - never fail the update flow on it.
  }
}

Log '===== dsh web update check begin ====='
$installed = (& dsh --version 2>$null | Out-String).Trim()
$latest = (& npm view "@deepseek-ai/dsh@$Tag" version 2>$null | Out-String).Trim()
Log "installed=$installed latest($Tag)=$latest"

if (-not $latest -or $latest -eq 'unknown' -or $latest -eq '') {
  Log 'registry unreachable - keeping current (no prompt)'
  exit 0
}
if ($installed -eq $latest) {
  Log "already on $installed - no update needed"
  exit 0
}

# --- a newer official release exists: pre-check plugin compatibility ---
Log "newer official dsh available ($installed -> $latest), running compat check"
$compatReport = ''
if (Test-Path $compatCheck) {
  $compatReport = (& node $compatCheck --host $latest 2>$null | Out-String)
  Log "plugin compat vs $latest`:"
  Log $compatReport
}
# conflict package names come from the shared compat-check itself (its
# --conflict-names mode), so the name-extraction regex lives in exactly ONE
# place (deploy/shared/dsh-web-plugin-compat-check.mjs) for both platforms.
$conflictNames = @()
if (Test-Path $compatCheck) {
  $conflictNames = @((& node $compatCheck --host $latest --conflict-names 2>$null) | Where-Object { $_ })
}

# --- ask the human ---
Add-Type -AssemblyName System.Windows.Forms
if ($conflictNames.Count -gt 0) {
  $msg = "官方 dsh 发布新版本：$installed  →  $latest`n`n" +
         "⚠ 升级将自动卸载以下不兼容插件：`n    " + ($conflictNames -join "`n    ") +
         "`n`n确认升级？"
} else {
  $msg = "官方 dsh 发布新版本：$installed  →  $latest`n`n✅ 已安装插件均兼容新版`n`n是否立即更新？"
}
$choice = [System.Windows.Forms.MessageBox]::Show($msg, 'DeepSeek Harness 更新', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
if ($choice -ne 'Yes') { Log 'user chose No - keeping current'; exit 0 }

# --- uninstall conflicting plugins (so they cannot break the upgraded host) ---
foreach ($name in $conflictNames) {
  Log "uninstalling conflicting plugin $name"
  Push-Location $profileDir
  try {
    & dsh plugin --profile web remove $name 2>&1 | Out-Null
    Log "removed $name"
  } catch { Log "WARN remove $name failed; continuing" }
  Pop-Location
}

# --- upgrade the host with a live progress window (macOS parity) ---
Log "upgrading official dsh to $latest"
Add-Type -AssemblyName System.Windows.Forms
$script:npmLive = Join-Path $homeDir '.dsh\npm-install.live.log'
$script:npmJob = Start-Job -ScriptBlock { param($spec, $lf)
  & npm install -g $spec 2>&1 | Out-File -FilePath $lf -Encoding UTF8
} -ArgumentList "@deepseek-ai/dsh@$Tag", $script:npmLive

# small always-on-top dialog cycling canned phase text while npm installs
$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = 'DeepSeek Harness 更新'
$script:form.ClientSize = New-Object System.Drawing.Size(400, 96)
$script:form.FormBorderStyle = 'FixedDialog'
$script:form.ControlBox = $false
$script:form.StartPosition = 'CenterScreen'
$script:form.TopMost = $true
$script:label = New-Object System.Windows.Forms.Label
$script:label.Text = "正在更新官方 dsh（$installed  →  $latest）..."
$script:label.Size = New-Object System.Drawing.Size(370, 60)
$script:label.Location = New-Object System.Drawing.Point(15, 18)
$script:form.Controls.Add($script:label)

$script:phases = @('正在下载并安装新版本，请稍候...', '正在更新依赖包...', '即将完成...')
$script:phaseIdx = 0
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 800
$script:timer.Add_Tick({
  if ($script:npmJob.State -ne 'Running') {
    $script:timer.Stop()
    $script:label.Text = if ($script:npmJob.State -eq 'Completed') { '更新完成' } else { '更新失败' }
    $script:form.Close()
  } else {
    $script:label.Text = $script:phases[$script:phaseIdx % $script:phases.Length]
    $script:phaseIdx++
  }
})
$script:form.Add_Shown({ $script:timer.Start() })
try {
  [System.Windows.Forms.Application]::Run($script:form) | Out-Null
} catch {
  # no interactive desktop / STA unavailable - fall back to waiting on the job
  Log "progress window unavailable ($($_.Exception.Message)); waiting without it"
  Wait-Job $script:npmJob | Out-Null
}

# job finished
if ($script:npmJob.State -eq 'Failed') {
  Log 'WARN npm install job failed'
  Receive-Job $script:npmJob | ForEach-Object { Log "npm: $_" }
  Remove-Job $script:npmJob -Force
  Log 'update failed - keeping current version'
  Log '===== dsh web update check end ====='
  exit 0
}
Receive-Job $script:npmJob | ForEach-Object { Log "npm: $_" }
Remove-Job $script:npmJob -Force
$newVer = (& dsh --version 2>$null | Out-String).Trim()
Log "updated to $newVer"
Log '===== dsh web update check end ====='
exit 1
