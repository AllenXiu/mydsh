# Windows 部署（与 macOS 同等的"升级前人工确认 + 冲突插件自动卸载"能力）

> 适用：想在本仓库当前的 Windows 部署（`restart-dsh-web.cmd` + Startup 自启 VBS）上，
> 获得 macOS 侧已实现的**弹窗确认更新、冲突插件预检、冲突插件自动卸载、更新进度提示**。
> 本文档不涉及本仓库内 `deploy/macos/` 的任何改动——那些是 macOS 专用，**不会影响 Windows**。

## 1. 现状对照

| 能力 | macOS（已实现，deploy/macos/） | Windows（现状） | Windows 需要的改动 |
|---|---|---|---|
| 登录/开机自启 | launchd LaunchAgent | Startup 文件夹 `dsh-web-autostart.vbs` | 无需改，已具备 |
| 一键重启 | `restart-dsh-web.sh` / `.command` | `restart-dsh-web.cmd` | 无需改，已具备 |
| 每次启动检查官方新版 | `dsh-web-autostart.sh` 调用 `dsh-web-confirm-update.sh` | VBS 直接 `npm install -g @latest`（**静默升级**） | 需引入确认逻辑 |
| 检测到新版 → 弹窗询问 | osascript 原生对话框 | 无（直接升） | 需 PowerShell 弹窗 |
| 冲突插件预检 | `dsh-web-plugin-compat-check.mjs`（Node） | 无 | **可直接复用此文件** |
| 冲突插件自动卸载 | confirm 脚本内 `dsh plugin remove` | 无 | 需在确认脚本中调用同一条命令 |
| 更新进度提示 | `dsh-update-progress`（Swift 窗口） | 无 | 需 PowerShell 进度提示（可选） |
| 浏览器 token URL | `~/.dsh/current-url.txt` | 0.1.2 同样按进程生成 token | 建议在启动日志/命令窗打印 URL |

### 已提交内容是否影响 Windows？
不会。`git log origin/master..HEAD` 的全部改动都集中在 `deploy/macos/` 目录：
`dsh-web-autostart.sh / dsh-web-unlock.sh / dsh-web-confirm-update.sh / dsh-web-plugin-lock.sh /
dsh-web-plugin-compat-check.mjs / dsh-update-progress.swift / install.sh / uninstall.sh / README.md`
Windows 端使用的 `restart-dsh-web.cmd`（仓库根）与 Startup VBS 均未被修改。

## 2. Windows 复用 macOS 逻辑的最小方案

Windows 与 macOS 的差异只在**"弹窗/交互/后台触发"这些系统耦合层**；
版本比较、冲突判定、卸载动作**同一套逻辑可直接复用**（依赖 Node + 官方 dsh，Windows 同样具备）。

### 2.1 可直接复用的文件

`deploy/macos/dsh-web-plugin-compat-check.mjs` —— 纯 Node，跨平台。
- 输入：`--host <目标版本>`（要升级到的 dsh 版本）
- 输出：三行状态，`CONFLICT` 行表示与目标版本不兼容
- Windows 用法：`node dsh-web-plugin-compat-check.mjs --host 0.1.2-rc.1`
- 需先 `git pull` 拿到此文件，或直接复制到 Windows profile 目录旁。

### 2.2 Windows 需要新写的组件

| 组件 | macOS 用 | Windows 替代 |
|---|---|---|
| 确认弹窗 | `osascript` | PowerShell `System.Windows.Forms.MessageBox` |
| 进度提示 | Swift AppKit 窗口 | PowerShell `Write-Progress` 或简单 MessageBox（可选） |
| 自启触发 | LaunchAgent + 解锁 watcher | Startup VBS（已有，改为调用确认脚本） |
| 日志 | `~/.dsh/autostart-update.log` | 同一路径（`%USERPROFILE%\.dsh\autostart-update.log`，已存在） |

### 2.3 推荐的 Windows 目录结构

```
%USERPROFILE%\.dsh\bin\
    dsh-web-update.ps1              # 新增：确认更新 + 预检 + 卸载冲突 + 升级（核心）
    dsh-web-plugin-compat-check.mjs # 复用（复制自 deploy/macos/）
    dsh-web-autostart.vbs           # 已有 Startup 自启，改为调用 dsh-web-update.ps1
restart-dsh-web.cmd                 # 已有，不用改（它走 VBS）
```

## 3. 核心脚本参考：`dsh-web-update.ps1`

逻辑与 macOS `dsh-web-confirm-update.sh` 对齐：
1. 读当前版本 `dsh --version`
2. 读官方最新 `npm view @deepseek-ai/dsh@latest version`
3. 相同 → 直接返回（无提示）
4. 不同 → 运行 compat-check.mjs 得到冲突清单
5. MessageBox 询问（冲突项醒目列出）
6. 点"更新"：逐个 `dsh plugin --profile web remove <冲突插件>`，再 `npm install -g @deepseek-ai/dsh@latest`
7. 写日志 `%USERPROFILE%\.dsh\autostart-update.log`
```powershell
# dsh-web-update.ps1
# 用法: powershell -ExecutionPolicy Bypass -File dsh-web-update.ps1
$ErrorActionPreference = 'Stop'
$homeDir = $env:USERPROFILE
$log = "$homeDir\.dsh\autostart-update.log"
$profileDir = "$homeDir\.dsh\profiles\web"
$compatCheck = Join-Path $PSScriptRoot 'dsh-web-plugin-compat-check.mjs'
function Log($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }

Log '===== dsh web update check begin ====='
$installed = (dsh --version 2>$null | Out-String).Trim()
$latest = (npm view @deepseek-ai/dsh@latest version 2>$null | Out-String).Trim()
Log "installed=$installed latest=$latest"
if ($installed -eq $latest) { Log 'already up to date - no prompt'; exit 0 }
if (-not $latest) { Log 'registry unreachable - keeping current'; exit 0 }

# 1) 冲突预检
$compat = node $compatCheck --host $latest 2>$null | Out-String
Log "compat vs $latest`n$compat"
$conflicts = ($compat -split "`n") | Where-Object { $_ -match 'CONFLICT' }

# 2) 弹窗询问（冲突项醒目列出）
Add-Type -AssemblyName System.Windows.Forms
if ($conflicts) {
    $msg = "官方发布了新版本 dsh：$installed → $latest`n`n" +
           "⚠ 升级将自动卸载以下不兼容插件：`n    " + ($conflicts -join "`n    ") +
           "`n`n确认升级？"
} else {
    $msg = "官方发布了新版本 dsh：$installed → $latest`n`n✅ 已安装插件均兼容新版`n`n是否立即更新？"
}
$r = [System.Windows.Forms.MessageBox]::Show($msg, 'DeepSeek Harness 更新',
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Warning)
if ($r -ne 'Yes') { Log 'user chose No - keeping current'; exit 0 }

# 3) 卸载冲突插件（先匹配 scoped/非 scoped 包名整段，再去掉尾部 @版本）
if ($conflicts) {
    $conflictNames = $conflicts | ForEach-Object {
        if ($_ -match '(@[a-z0-9._-]+/[a-z0-9._-]+|[a-z0-9][a-z0-9._-]*)@[0-9][^ ]*') {
            ($matches[1] -replace '@[0-9][^@]*$', '')
        }
    } | Sort-Object -Unique
    foreach ($name in $conflictNames) {
        Log "uninstalling conflicting plugin $name"
        Push-Location $profileDir
        try { dsh plugin --profile web remove $name 2>&1 | Out-Null }
        catch { Log "WARN remove $name failed" }
        Pop-Location
    }
}

# 4) 升级 + 日志
Log "upgrading to $latest"
npm install -g "@deepseek-ai/dsh@latest" 2>&1 | ForEach-Object { Log "npm: $_" }
Log "updated to $((dsh --version | Out-String).Trim())"
Log '===== dsh web update check end ====='
exit 1   # 1 = 更新完成，调用方可据此重启 web
```

> 提示：`compat-check.mjs` 输出的冲突行形如
> `  !! @scope/pkg@1.2.3  CONFLICT on dsh X: reason`。
> PowerShell 提取包名建议用两步：先匹配 `@scope/name@ver`（scoped）或 `name@ver`（非 scoped）整段，
> 再去掉尾部 `@版本`：
> ```powershell
> $names = $conflicts | ForEach-Object {
>     if ($_ -match '(@[a-z0-9._-]+/[a-z0-9._-]+|[a-z0-9][a-z0-9._-]*)@[0-9][^ ]*') {
>         ($matches[1] -replace '@[0-9][^@]*$', '')
>     }
> } | Sort-Object -Unique
> ```
> 与 macOS `dsh-web-plugin-lock.sh` 中使用的提取逻辑保持一致。

## 4. 把确认逻辑接入 Windows 自启/重启

### 4.1 Startup VBS（登录自启）
把 VBS 中"直接 npm install"的步骤换成调用 PowerShell 脚本（示意）：
```vbs
' dsh-web-autostart.vbs（在 Startup 文件夹中的现有文件，改启动步骤）
Set shell = CreateObject("WScript.Shell")
' 1) 先询问/执行更新（阻塞等确认；返回码不适用则改为在 ps1 内自管重启）
shell.Run "powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & _
    "%USERPROFILE%\.dsh\bin\dsh-web-update.ps1""", 0, True
' 2) 启动 web（原有逻辑，建议加 --no-open 并把 token URL 落到 current-url.txt）
```
`dsh-web-update.ps1` 内部完成"确认→卸载冲突→升级"；VBS 只需随后启动 web。

### 4.2 手动重启
`restart-dsh-web.cmd` 第 3 步本来就调用 VBS 重启 → VBS 换成确认脚本后，手动重启也会先询问。

## 5. Windows 测试步骤（在 Windows 电脑上）

1. `git pull`（或手动复制）取得 `deploy/macos/dsh-web-plugin-compat-check.mjs`
2. 把 `dsh-web-update.ps1` 与 compat-check 放到 `%USERPROFILE%\.dsh\bin\`
3. 验证预检：`node dsh-web-plugin-compat-check.mjs --host 0.1.2-rc.1`（应列出当前插件兼容性）
4. 手动触发一次：`powershell -ExecutionPolicy Bypass -File dsh-web-update.ps1`
   - 若宿主已是官方最新 → 直接退出（日志记 `already up to date`）
   - 若低于官方最新 → 弹 MessageBox → 点 Yes 验证升级 +（如有冲突插件）自动卸载
5. 浏览器打开 `http://127.0.0.1:3080` 确认 web 正常、冲突插件已消失
6. 确认无误后，再把 Startup VBS 换成调用确认脚本（4.1）

## 6. 常见差异注意点

- **token 认证（dsh ≥ 0.1.2）**：Windows 与 macOS 一样，每次进程重启 token 变化。
  启动命令会打印 `?token=...` URL；自启/重启脚本应把该 URL 落到
  `%USERPROFILE%\.dsh\current-url.txt`（当前 Windows 部署可能还没有，建议补）。
- **路径**：脚本一律用 `%USERPROFILE%` / `$env:USERPROFILE`，勿硬编码 `C:\Users\xxx`。
- **PATH**：确认脚本运行前保证 `dsh`/`npm`/`node` 在 PATH（自启环境 PATH 可能不含；
  在 ps1 开头显式 prepend 对应 bin 目录最稳）。
- **官方版本线**：`latest` 目前 = 0.1.2 线；若将来需要跟 `next`，把两处 `@latest` 换成对应 tag，
  与 macOS 脚本的 `DSH_TAG` 保持一致即可。

