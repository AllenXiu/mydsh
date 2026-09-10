# macOS 部署（与 Windows 部署流程一致；升级需人工确认）

Windows 上"每次开机更新官方 dsh"靠 Startup 自启；macOS 很少重启，所以这套部署把**更新检查**挂在每次**登录、重启与屏幕解锁**上。**不再静默自动升级**：检测到官方发布新版本时弹出原生对话框询问，你点"更新"才安装并重启 Web UI；点"跳过"保持当前版本不动。

| Windows | macOS | 作用 |
|---|---|---|
| `Startup\dsh-web-autostart.vbs` | `~/.dsh/bin/dsh-web-autostart.sh`（登录/重启时执行） | 先询问是否更新 → 再启动 Web UI |
| — | `dsh-web-confirm-update.sh` | 对比官方版本；有新版弹窗询问（Update/Skip），无新版直接放行 |
| — | `dsh-web-plugin-lock.sh` | **插件锁（手动工具）**：可手动禁用/恢复指定插件；升级流程默认"直接卸载"冲突插件，此脚本保留用于手动管理 |
| — | `dsh-update-progress`（Swift 编译） | **更新进度窗口**：点"更新"后显示转圈进度条与 npm 实时状态，完成后提示音并自动关闭 |
| — | `deploy/shared/dsh-web-plugin-compat-check.mjs`（install.sh 拷到 `~/.dsh/bin/`） | 升级前预检（**跨平台共享，唯一来源**）：扫描第三方插件对宿主版本的声明（engines/compatibility/peerDeps），冲突项在弹窗中**单独成区醒目显示** |
| — | `dsh-web-preset-gate.sh` | **预设门禁**（每次启动 web 前、以及升级 dsh 成功后都会跑）：用 `deploy/shared/dsh-agent-preset-mount-probe.mjs` 探默认预设能否挂载；`FAIL(config)` 时先幂等修复已知改名、再不行就把默认预设回退为 `standard`，并弹窗告知——因为默认预设挂不上等于**所有新建/恢复会话都打不开** |
| 每次开机都自启 | 每次登录 + **每次屏幕解锁后**（watcher 检查到新版会弹窗征询） | 有机会跟进官方新版，但由你决定 |
| — | `dsh-web-unlock-watcher`（Swift 编译，常驻） | 监听 `com.apple.screenIsUnlocked`/会话激活/唤醒 |
| `restart-dsh-web.cmd` | `restart-dsh-web.sh` / `restart-dsh-web.command`（双击） | 一键重启：停 3080 端口 → 重启 → 轮询等待 |
| `%USERPROFILE%\.dsh\autostart-update.log` | `~/.dsh/autostart-update.log` | 更新/启动日志 |
| — | `~/.dsh/current-url.txt` | 每次重启后写入当前有效 token URL（dsh 0.1.2 浏览器认证每次进程随机 token） |
| 官方 `@deepseek-ai/dsh` npm 发布版 | 同左（不使用本 fork 的定制代码） | 跟随 `latest`（现为 0.1.5 线）；是否安装由弹窗确认 |

LaunchAgent：
- `com.allern.dsh-web` — **持有** dsh web 进程（前台 `exec`，launchd 管理生命周期）；每次启动先跑更新确认。
- `com.allern.dsh-web-unlock` — 常驻 watcher（`KeepAlive`），解锁后检查更新并弹窗征询。

## 依赖（一次性）

- nvm（`~/.nvm`）+ Node 22 LTS（`nvm alias default`）
- 官方包：`npm install -g @deepseek-ai/dsh@latest`（每次登录/重启/解锁会弹窗确认是否更新 `latest` 线）
- Swift 编译器：macOS 自带 `/usr/bin/swiftc`（Command Line Tools）

## 安装

```sh
bash deploy/macos/install.sh
```

安装后：
- Web UI 在登录时自动启动（等价 Windows Startup）。
- 之后每次**重启 / 屏幕解锁**，若官方发布了新版本，会弹出对话框询问"是否更新"；弹窗中**冲突插件单独成区醒目列出**。
- **点更新时**：先自动**卸载**与新版冲突的插件（不再只是禁用），再弹出实时进度窗口完成升级，保证主项目干净升级运行；跳过则保持当前版本。
- 无 GUI/SSH 会话时默认**不升级**（fail-safe），避免后台静默变更。
- **预设门禁**：每次启动 web 前（以及升级 dsh 成功后）自动检查 `settings.yaml` 的 `agent-presets.default`
  能否挂载；发现配置类失败会先修已知改名、再不行就把默认预设临时回退为 `standard` 并弹窗告知
  （原文件与 settings 都留 `.bak-<时间戳>` 备份）。门禁从不阻塞 web 启动。
- 立即重启：`./restart-dsh-web.sh`（或双击 `restart-dsh-web.command`）。

## 手动命令

```sh
bash ~/.dsh/bin/dsh-web-confirm-update.sh  # 手动检查/确认更新（弹窗）
bash ~/.dsh/bin/dsh-web-plugin-lock.sh status   # 查看当前锁住的插件
bash ~/.dsh/bin/dsh-web-plugin-lock.sh unlock   # 恢复所有被锁插件（作者适配后）
bash ~/.dsh/bin/dsh-web-unlock.sh          # 手动模拟一次"解锁后检查"
bash ~/.dsh/bin/dsh-web-autostart.sh       # 手动：确认更新 → 启动 web
./restart-dsh-web.sh                       # 一键重启（杀 3080 进程 → 重启 → 轮询）
bash deploy/macos/uninstall.sh             # 卸载两个 LaunchAgent、watcher 与脚本

# 预设门禁（正常由上面两条自动调用）
bash ~/.dsh/bin/dsh-web-preset-gate.sh                 # 体检默认预设并按需修复/回退
bash ~/.dsh/bin/dsh-web-preset-gate.sh --preset <id>   # 指定预设
bash ~/.dsh/bin/dsh-web-preset-gate.sh --dry-run       # 只报告将会做什么，不写文件
node ~/.dsh/bin/dsh-agent-preset-compat-check.mjs      # 逐行 schema 校验（只读）
node ~/.dsh/bin/dsh-agent-preset-mount-probe.mjs       # 挂载探针（只读；细节见 deploy/shared/README.md）
```

日志：`~/.dsh/autostart-update.log`、`~/.dsh/web.log`。当前有效访问地址：`cat ~/.dsh/current-url.txt`（token 每次重启变化）。Web UI 默认 `http://127.0.0.1:3080`。

## 版本线：跟随官方 `latest`（现为 0.1.5 线）

官方 `latest` 当前是 **0.1.5-rc.1**（`next` = 0.1.5-rc.2）；`latest` 于 2026-09 由 0.1.1 → 0.1.2 → 0.1.5 逐级提升，
每一级都伴随插件 API 破坏（0.1.1 线插件在 0.1.2 崩、0.1.2 线 preset 在 0.1.5 因 `persona.text` 改名 `prefix` 而挂不上）。
两个脚本顶部 `DSH_TAG="${DSH_TAG:-latest}"` 可在环境变量中覆盖；安装哪个版本始终由确认弹窗决定，不会自动变。

## 开发说明

解锁监听用 Swift 实现（`dsh-web-unlock-watcher.swift`），理由是 macOS 没有面向 shell 的解锁事件通知；`swiftc` 编译产物很小（~60KB），`install.sh` 在源码更新后会自动重编译。更新确认用 `osascript` 原生对话框；launchd 执行时若进程无 GUI 会话权限则安全跳过更新。
