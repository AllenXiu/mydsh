# macOS 部署（与 Windows 部署流程一致；升级需人工确认）

Windows 上"每次开机更新官方 dsh"靠 Startup 自启；macOS 很少重启，所以这套部署把**更新检查**挂在每次**登录、重启与屏幕解锁**上。**不再静默自动升级**：检测到官方发布新版本时弹出原生对话框询问，你点"更新"才安装并重启 Web UI；点"跳过"保持当前版本不动。

| Windows | macOS | 作用 |
|---|---|---|
| `Startup\dsh-web-autostart.vbs` | `~/.dsh/bin/dsh-web-autostart.sh`（登录/重启时执行） | 先询问是否更新 → 再启动 Web UI |
| — | `dsh-web-confirm-update.sh` | 对比官方版本；有新版弹窗询问（Update/Skip），无新版直接放行 |
| 每次开机都自启 | 每次登录 + **每次屏幕解锁后**（watcher 检查到新版会弹窗征询） | 有机会跟进官方新版，但由你决定 |
| — | `dsh-web-unlock-watcher`（Swift 编译，常驻） | 监听 `com.apple.screenIsUnlocked`/会话激活/唤醒 |
| `restart-dsh-web.cmd` | `restart-dsh-web.sh` / `restart-dsh-web.command`（双击） | 一键重启：停 3080 端口 → 重启 → 轮询等待 |
| `%USERPROFILE%\.dsh\autostart-update.log` | `~/.dsh/autostart-update.log` | 更新/启动日志 |
| — | `~/.dsh/current-url.txt` | 每次重启后写入当前有效 token URL（dsh 0.1.2 浏览器认证每次进程随机 token） |
| 官方 `@deepseek-ai/dsh` npm 发布版 | 同左（不使用本 fork 的定制代码） | 跟随 `latest`（0.1.2 主线）；是否安装由弹窗确认 |

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
- 之后每次**重启 / 屏幕解锁**，若官方发布了新版本，会弹出对话框询问"是否更新"；更新后自动重启 Web UI，跳过则保持当前版本。
- 无 GUI/SSH 会话时默认**不升级**（fail-safe），避免后台静默变更。
- 立即重启：`./restart-dsh-web.sh`（或双击 `restart-dsh-web.command`）。

## 手动命令

```sh
bash ~/.dsh/bin/dsh-web-confirm-update.sh  # 手动检查/确认更新（弹窗）
bash ~/.dsh/bin/dsh-web-unlock.sh          # 手动模拟一次"解锁后检查"
bash ~/.dsh/bin/dsh-web-autostart.sh       # 手动：确认更新 → 启动 web
./restart-dsh-web.sh                       # 一键重启（杀 3080 进程 → 重启 → 轮询）
bash deploy/macos/uninstall.sh             # 卸载两个 LaunchAgent、watcher 与脚本
```

日志：`~/.dsh/autostart-update.log`、`~/.dsh/web.log`。当前有效访问地址：`cat ~/.dsh/current-url.txt`（token 每次重启变化）。Web UI 默认 `http://127.0.0.1:3080`。

## 版本线：跟随官方 `latest`（0.1.2 主线）

官方 `latest` 与 `next` 目前均为 `0.1.2` 线；`latest` 已于 2026-09 从 0.1.1 提升至 0.1.2。曾与 0.1.1 深度绑定的 `@kenz1117/dsh-ui-usage-billing`、以及要求 0.1.2 的 `dsh-web-all` 全家桶均已移除，当前 profile 只有官方 bundle + 插件市场（dshmarket）。两个脚本顶部 `DSH_TAG="${DSH_TAG:-latest}"` 可在环境变量中覆盖；安装哪个版本始终由确认弹窗决定，不会自动变。

## 开发说明

解锁监听用 Swift 实现（`dsh-web-unlock-watcher.swift`），理由是 macOS 没有面向 shell 的解锁事件通知；`swiftc` 编译产物很小（~60KB），`install.sh` 在源码更新后会自动重编译。更新确认用 `osascript` 原生对话框；launchd 执行时若进程无 GUI 会话权限则安全跳过更新。
