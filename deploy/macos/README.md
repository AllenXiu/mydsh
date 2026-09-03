# macOS 部署（与 Windows 部署流程一致，粒度改为"每次屏幕解锁"）

Windows 上"每次开机都跑最新官方 dsh"靠 Startup 自启；macOS 很少重启，所以这套部署把**每次启动要更新官方 dsh** 的行为挂在**每次屏幕解锁**上：解锁后 watcher 对比官方 npm 最新版与当前运行版，**有新版才重启** Web UI，未运行则拉起，已是最新则不动（避免每解锁都打断会话）。

| Windows | macOS | 作用 |
|---|---|---|
| `Startup\dsh-web-autostart.vbs`（update check → `start web --no-open`） | `~/.dsh/bin/dsh-web-autostart.sh`（登录/重启时执行） | 更新官方 dsh 后启动 Web UI |
| 每次开机都自启 | 每次登录 + **每次屏幕解锁后**（watcher 检查到新版才重启） | 保证运行的是最新官方 dsh |
| — | `dsh-web-unlock-watcher`（Swift 编译，常驻） | 监听 `com.apple.screenIsUnlocked`/会话激活/唤醒 |
| — | `~/.dsh/bin/dsh-web-unlock.sh` | 解锁后：对比版本 → 有新版或未运行才 kickstart 重启 |
| `restart-dsh-web.cmd` | `restart-dsh-web.sh` / `restart-dsh-web.command`（双击） | 一键重启：停 3080 端口 → 重启 → 轮询等待 |
| `%USERPROFILE%\.dsh\autostart-update.log` | `~/.dsh/autostart-update.log` | 更新/启动日志 |
| 官方 `@deepseek-ai/dsh` npm 发布版 | 同左（不使用本 fork 的定制代码） | `npm install -g @deepseek-ai/dsh@latest`，避免脱离版本（与已装 0.1.1 兼容插件匹配） |

LaunchAgent：
- `com.allern.dsh-web` — **持有** dsh web 进程（前台 `exec`，launchd 管理生命周期）。
- `com.allern.dsh-web-unlock` — 常驻 watcher（`KeepAlive`），负责"每次解锁后检查更新并适时重启"。

## 依赖（一次性）

- nvm（`~/.nvm`）+ Node 22 LTS（`nvm alias default`）
- 官方包：`npm install -g @deepseek-ai/dsh@next`（每次启动/解锁会自动确认 `next` 线最新）
- Swift 编译器：macOS 自带 `/usr/bin/swiftc`（Command Line Tools）

## 安装

```sh
bash deploy/macos/install.sh
```

安装后：
- Web UI 在登录时自动启动（等价 Windows Startup）。
- 之后**每次屏幕解锁**，watcher 都会对比官方最新版；有新发布就自动更新并重启 Web UI。
- 立即重启：`./restart-dsh-web.sh`（或双击 `restart-dsh-web.command`）。

## 手动命令

```sh
bash ~/.dsh/bin/dsh-web-unlock.sh      # 手动模拟一次"解锁后检查"（对比版本、按需重启）
bash ~/.dsh/bin/dsh-web-autostart.sh   # 手动：更新官方 dsh + 启动 web
./restart-dsh-web.sh                   # 一键重启（杀 3080 进程 → 重启 → 轮询）
bash deploy/macos/uninstall.sh         # 卸载两个 LaunchAgent、watcher 与脚本
```

日志：`~/.dsh/autostart-update.log`、`~/.dsh/web.log`。Web UI 默认 `http://127.0.0.1:3080`。

## 版本线选择：跟随 `latest`（不用 `next`）

官方 npm 的 `latest` 线（当前 `0.1.1-rc.2`）与 `next` 线（`0.1.2` 开发线）的浏览器端 API 不兼容：`@kenz1117/dsh-ui-usage-billing` 需要 `0.1.1` 的 `dsh-client-runtime/client` 导出，而 `@linxin666/dsh-web-all` 全家桶需要 `0.1.2` 且与前者冲突。本部署安装的是 usage-billing 等 0.1.1 兼容插件，因此固定跟随 `latest`。两个脚本顶部都有 `DSH_TAG="${DSH_TAG:-latest}"`，可在环境变量中覆盖。

若要临时用某 tag 启动：`DSH_TAG=next bash ~/.dsh/bin/dsh-web-autostart.sh`（注意插件兼容性需另行核对）。

## 开发说明

解锁监听用 Swift 实现（`dsh-web-unlock-watcher.swift`），理由是 macOS 没有面向 shell 的解锁事件通知；`swiftc` 编译产物很小（~60KB），`install.sh` 在源码更新后会自动重编译。
