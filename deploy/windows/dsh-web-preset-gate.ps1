# dsh-web-preset-gate.ps1
# Windows port of deploy/macos/dsh-web-preset-gate.sh.
# Keep sessions startable when the default agent preset stops mounting.
# Called before dsh web starts (dsh-autostart.cmd) and right after a dsh
# upgrade (dsh-web-update.ps1). It NEVER blocks the start: every path logs and
# exits 0.
#
#  1. probe the effective default preset with the shared mount probe
#     (agentPresets.standingKeyFor - the same call a session creation makes);
#  2. FAIL(config) -> repair the known row-key rename (persona text: -> prefix:)
#     in place, file backed up first, then probe again;
#  3. still FAIL(config) -> fall back agent-presets.default to "standard"
#     (settings backed up first) so sessions work while the preset is fixed;
#  4. FAIL(host) / INCONCLUSIVE -> log only; an ambiguous signal never rewrites
#     a user file.
param(
  [string]$Preset = '',
  [string]$Fallback = 'standard',
  [string]$Settings = '',
  [switch]$DryRun,
  [switch]$NoNotify,
  [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$dshHome = Join-Path $env:USERPROFILE '.dsh'
$log = Join-Path $dshHome 'autostart-update.log'
# mount probe is the single cross-platform source at <repo>\deploy\shared\
$probe = Join-Path (Split-Path -Parent $PSScriptRoot) 'shared\dsh-agent-preset-mount-probe.mjs'
if (-not $Settings) { $Settings = Join-Path $dshHome 'settings.yaml' }

function Log($m) {
  try { Add-Content -Path $log -Value ("[{0}] preset-gate: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 -ErrorAction Stop } catch {}
}
function Notify($m) {
  if ($NoNotify) { return }
  try {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($m))
    $inner = "Add-Type -AssemblyName System.Windows.Forms;[System.Windows.Forms.MessageBox]::Show([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64')), 'DeepSeek Harness', 0, 48)|Out-Null"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    Start-Process -WindowStyle Hidden -FilePath 'powershell' -ArgumentList @('-NoProfile','-EncodedCommand',$enc) | Out-Null
  } catch {}
}

# --- read/write a UTF-8 text file, preserving its BOM ---
function Read-TextPreserve($file) {
  $raw = [System.IO.File]::ReadAllBytes($file)
  $hasBom = ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)
  $skip = if ($hasBom) { 3 } else { 0 }
  return @{ text = [System.Text.Encoding]::UTF8.GetString($raw, $skip, $raw.Length - $skip); bom = $hasBom }
}
function Write-TextPreserve($file, $text, $bom) {
  $body = [System.Text.Encoding]::UTF8.GetBytes($text)
  if ($bom) { $body = [byte[]]([System.Text.Encoding]::UTF8.GetPreamble() + $body) }
  [System.IO.File]::WriteAllBytes($file, $body)
}

# --- repair the known persona config-key rename (text: -> prefix:) ---
function Repair-PersonaPrefix($file) {
  if (-not (Test-Path $file)) { return $false }
  $p = Read-TextPreserve $file
  $m = [regex]::Matches($p.text, '(?m)^ +text:')
  if ($m.Count -ne 1) { Log "persona repair skipped (candidate text: rows=$($m.Count) in $file)"; return $false }
  if ($DryRun) { Log "[dry-run] would rewrite $file (persona text: -> prefix:)"; return $true }
  Copy-Item $file ("$file.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  $new = [regex]::Replace($p.text, '(?m)^( +)text:', '${1}prefix:')
  Write-TextPreserve $file $new $p.bom
  Log "rewrote $file (persona text: -> prefix:), backup beside it"
  return $true
}

# --- read/rewrite agent-presets.default in settings.yaml ---
function Get-SettingsDefault($path) {
  if (-not (Test-Path $path)) { return '' }
  $lines = (Read-TextPreserve $path).text -split [char]10
  $inBlock = $false
  foreach ($l in $lines) {
    if ($l -match '^agent-presets: *$') { $inBlock = $true; continue }
    if ($inBlock -and $l -match '^[^ ]') { break }
    if ($inBlock -and $l -match '^ +default: *(.+?) *$') { return $Matches[1].Trim([char]0x27, [char]0x22) }
  }
  return ''
}
function Set-SettingsDefault($path, $value) {
  if (-not (Test-Path $path)) { return $false }
  $p = Read-TextPreserve $path
  $lines = @($p.text -split [char]10)
  $inBlock = $false; $hit = -1; $count = 0
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if ($l -match '^agent-presets: *$') { $inBlock = $true; continue }
    if ($inBlock -and $l -match '^[^ ]') { break }
    if ($inBlock -and $l -match '^ +default:') { $count++; $hit = $i }
  }
  if ($count -ne 1) { Log "settings fallback skipped (agent-presets.default rows=$count in $path)"; return $false }
  if ($DryRun) { Log "[dry-run] would set $path agent-presets.default -> $value"; return $true }
  Copy-Item $path ("$path.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  $lines[$hit] = [regex]::Replace($lines[$hit], '^( +default: *).*$', ('${1}' + $value))
  Write-TextPreserve $path ($lines -join [char]10) $p.bom
  Log "set agent-presets.default -> $value ($path), backup beside it"
  return $true
}

# --- is this preset shipped (and re-synced at boot) by an installed plugin? ---
# Plugin-bundled presets are copied into ~/.dsh/.agent-presets at web start, a
# one-way overwrite: repairing such a file in place is reverted on the next
# boot, so the gate falls the default back instead of pretending to fix it.
function Test-PluginShippedPreset($id) {
  $root = Join-Path $dshHome "profiles"
  if (-not (Test-Path $root)) { return "" }
  foreach ($prof in Get-ChildItem $root -Directory -ErrorAction SilentlyContinue) {
    $nm = Join-Path $prof.FullName "node_modules"
    if (-not (Test-Path $nm)) { continue }
    foreach ($entry in Get-ChildItem $nm -Directory -ErrorAction SilentlyContinue) {
      if ($entry.Name.StartsWith("@")) {
        foreach ($pkg in Get-ChildItem $entry.FullName -Directory -ErrorAction SilentlyContinue) {
          if (Test-Path (Join-Path $pkg.FullName ("presets\" + $id))) { return $pkg.FullName }
        }
      }
    }
  }
  return ""
}

# --- probe one preset through the shared mount probe (real mount path) ---
function Probe-Verdict($id) {
  $json = & node $probe --preset $id --json 2>$null | Out-String
  try {
    $obj = $json | ConvertFrom-Json
    $r = @($obj.results | Where-Object { $_.id -eq $id })
    if ($r.Count -gt 0) { return @{ status = $r[0].status; error = $r[0].error } }
    return @{ status = 'INCONCLUSIVE'; error = 'no result for preset' }
  } catch { return @{ status = 'INCONCLUSIVE'; error = 'probe output unparsable' } }
}

# --- main ------------------------------------------------------------------
if (-not (Test-Path $probe)) { Log "probe missing ($probe) - run deploy/windows/install.ps1; skipping"; exit 0 }
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Log 'node not on PATH - skipping'; exit 0 }
if (-not (Test-Path $Settings)) { Log "no $Settings - nothing user-owned to guard"; exit 0 }

if (-not $Preset) { $Preset = Get-SettingsDefault $Settings }
if (-not $Preset) { Log 'no agent-presets.default set (composition default applies) - nothing to guard'; exit 0 }
$presetDir = Join-Path (Join-Path $dshHome '.agent-presets') $Preset
if (-not $Quiet) { Log "guarding preset '$Preset' ($presetDir)" }

$v = Probe-Verdict $Preset
if ($v.status -eq 'OK') { if (-not $Quiet) { Log "preset '$Preset' mounts OK" }; exit 0 }

if ($v.status -eq 'FAIL(config)') {
  Log "preset '$Preset' failed config validation - $($v.error)"
  $shipped = Test-PluginShippedPreset $Preset
  if ($shipped) {
    Log "preset '$Preset' is shipped by an installed plugin ($shipped); an in-place repair would be re-synced and lost - falling back"
  } elseif ("$($v.error)" -match 'dsh-persona') {
    $cfg = Join-Path $presetDir 'agent.cordis.yml'
    if (Repair-PersonaPrefix $cfg) {
      if ($DryRun) { Log '[dry-run] repair not applied - stopping here'; exit 0 }
      $v2 = Probe-Verdict $Preset
      if ($v2.status -eq 'OK') {
        Log "repaired preset '$Preset' - sessions can start again"
        Notify (([char]0x9884 + [char]0x8BBE + [char]0x300C) + $Preset + ([char]0x300D + ' 与当前 dsh 不兼容（配置键改名），已自动修复并保留原文件备份。'))
        exit 0
      }
      Log "preset '$Preset' still failing after repair - $($v2.status)"
    }
  }
  if (Set-SettingsDefault $Settings $Fallback) {
    Log "fell back to '$Fallback' (previous default: '$Preset')"
    Notify ('默认预设「' + $Preset + '」无法挂载（会导致所有会话打不开），已把默认预设临时改为「' + $Fallback + '」；原值见日志与备份文件。')
  } else {
    Log 'WARN fallback failed; manual action required'
  }
  exit 0
}

Log "verdict=$($v.status) for '$Preset' - not acting on it ($($v.error))"
exit 0
