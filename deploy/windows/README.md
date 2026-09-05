# Windows 部署（仓库即部署源：开机直读 deploy/，git pull 即生效）

> Windows 的 dsh web 通过 **Startup 自启**实现"每次开机检查官方新版、有人工确认、冲突插件自动卸载、升级时显示进度窗"。
> 采用**仓库直读**：开机时 Startup 里的 VBS 只做一件事——运行本仓库 `deploy/windows/dsh-autostart.cmd`。
> 之后的所有逻辑（更新确认、预检、进度窗、启动 web）都从**本仓库目录**执行。
> 因此在 Mac 上改好逻辑 → commit/push → Windows 上 `git pull` → 下次开机即用新代码，
> 无需任何拷贝/安装步骤（只需 clone/移动仓库后跑一次 install.ps1 刷新 Startup 指向）。

## 0. 目录布局：deploy/ 下的平台目录 + 公共共享目录

```
deploy/
├── windows/    Windows 启动/更新逻辑（ps1/cmd/vbs/install/uninstall，仓库直读）
├── macos/      macOS 启动/更新逻辑（sh/swift/plist，install.sh 拷到 ~/.dsh/bin）
└── shared/     ★ 跨平台共享逻辑的唯一来源（当前：dsh-web-plugin-compat-check.mjs）
```

两个平台各自需要一份"跨平台纯 Node"的兼容预检逻辑，旧结构在 deploy/windows 和
deploy/macos 各放一份副本，容易漂移。**现在只有 deploy/shared/ 一份**：
- Windows：boot 时 ps1 直接引用 `..\shared\`；
- macOS：install.sh 从 shared 拷贝到 `~/.dsh/bin`（安装后脚本继续引用已安装路径，行为不变）。

## 1. 开机链路（操作系统实际执行）

```
登录
 → Startup\dsh-web-autostart.vbs        ← 机器本地，install.ps1 生成，只含一行仓库路径
 → <repo>\deploy\windows\dsh-autostart.cmd    ← 仓库内，git 管理
     ├─ powershell -STA dsh-web-update.ps1      ← 仓库内：比对版本 → 预检 → 弹窗 → 卸载冲突 → 进度窗升级
     │      └─ 调用 deploy\shared\dsh-web-plugin-compat-check.mjs（单份跨平台源）
     └─ call dsh web（全局 npm 官方包）
```

| 文件 | 位置 | 角色 |
|---|---|---|
| `dsh-autostart.cmd` | deploy/windows/ | 启动器：自定位（`%~dp0`）找仓库里的 ps1 → 跑更新确认 → 解析 dsh → 启动 web |
| `dsh-web-update.ps1` | deploy/windows/ | 核心：`dsh --version` vs `npm view @deepseek-ai/dsh@latest` → 有新版跑 compat 预检 → MessageBox 询问（冲突插件单列）→ Yes 逐个 `dsh plugin --profile web remove` 卸载冲突 → WinForms 进度窗轮转阶段文案的同时 `npm install -g` 升级 |
| `dsh-web-plugin-compat-check.mjs` | **deploy/shared/**（唯一来源） | 升级前预检（纯 Node、跨平台，**三级判定** REJECT/WARN/兼容，细节见 deploy/shared/README.md）：REJECT（engines/peer/已知规则/冒烟证实）→升级时卸载；WARN（仅声明列表未覆盖）→保留并提示。输出 `--conflict-names` / `--warn-names` / `--verdict-names`(TSV) 供两平台脚本消费，提取正则只此一份 |
| `dsh-web-autostart.vbs` | deploy/windows/ | **模板**（占位符 `<REPO_ROOT>`）：install.ps1 把真实仓库路径替换后写入 Startup |
| `install.ps1` | deploy/windows/ | 把 Startup VBS 注册/刷新为指向本仓库；顺带删除旧的 detached 副本（§6） |
| `uninstall.ps1` | deploy/windows/ | 移除 Startup VBS，停止开机自启；仓库文件不动 |

仓库根的 `restart-dsh-web.cmd`（已跟踪）＝一键重启（停 3080 → 经 Startup VBS → 走同一条仓库链路 → 轮询等待）。

## 2. 能力对照（Windows / macOS）

| 能力 | Windows（deploy/windows/） | macOS（deploy/macos/） |
|---|---|---|
| 登录/开机自启 | Startup VBS（机器本地）→ 仓库 cmd | launchd LaunchAgent + 解锁 watcher |
| 每次启动检查官方新版 | 每次开机经仓库链路运行 `dsh-web-update.ps1` | 每次登录/重启/解锁 |
| 弹窗询问 | PowerShell `System.Windows.Forms.MessageBox`（Yes/No） | osascript 原生对话框 |
| 冲突插件预检 | 共同引用 **deploy/shared/dsh-web-plugin-compat-check.mjs** | 同左（install.sh 拷到 ~/.dsh/bin） |
| 冲突插件自动卸载 | ps1 内逐个 remove | confirm 脚本内同一条命令 |
| 升级进度提示 | ps1 内 WinForms 置顶小窗 | `dsh-update-progress`（Swift） |
| 一键重启 | `restart-dsh-web.cmd`（仓库根） | `restart-dsh-web.sh` / `.command` |
| 日志 | `%USERPROFILE%\.dsh\autostart-update.log` | `~/.dsh/autostart-update.log` |
| 版本线 | `latest`（0.1.2 主线），ps1 顶部 `param([string]$Tag='latest')` | `DSH_TAG`（默认 `latest`） |

## 3. 安装 / 卸载

仅在 **clone/移动仓库后**需要注册 Startup 指向（此后改逻辑只需 git pull，不用再跑）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File deploy/windows/install.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File deploy/windows/uninstall.ps1
```

立即走一遍完整链路：`restart-dsh-web.cmd`（仓库根）。

## 4. 手动命令 / 验证

```powershell
# 预检某个目标版本下当前插件兼容性（读 deploy/shared 这份）
node deploy/shared/dsh-web-plugin-compat-check.mjs --host <目标版本>
node deploy/shared/dsh-web-plugin-compat-check.mjs --host <目标版本> --conflict-names  # 只要 REJECT 冲突包名
node deploy/shared/dsh-web-plugin-compat-check.mjs --host <目标版本> --verdict-names     # TSV：<REJECT|WARN>\t<包名>

# 手动触发一次"检查→询问→升级"
powershell -NoProfile -ExecutionPolicy Bypass -File deploy/windows/dsh-web-update.ps1
```

`dsh-web-update.ps1` 退出码：`0` = 已最新 / 用户点 No / registry 不可达；`1` = 已执行升级（调用方据此重启 web）。

## 5. 已知冲突与版本线说明

- 兼容预检为**三级判定**（REJECT/WARN/兼容，规则细节见 deploy/shared/README.md）。`@kenz1117/dsh-ui-usage-billing` 这类"声明列表只覆盖 0.1.1、无其他硬证据"的插件现判为 **WARN**：升级时**保留**，只在弹窗提示"尚未声明支持"；不再仅因列表过期就卸载。只有 `engines.dsh`/peer 范围违反、内置已知规则或冒烟探针证实不兼容（如 web-all 一例）才判 **REJECT** 并自动卸载。
- `@linxin666/dsh-web-all` < 0.3.9 的 engines 虽写 `>=0.1.1-rc.1`，但其固定依赖 `dsh-better-sidebar` 0.15.x 引用 0.1.2 已删除的 `settingsNamespace` 导出——**实测在 0.1.2 崩溃**。compat-check 内置该**已知运行时冲突规则**（`web-all <0.3.9` 对 `0.1.2+` 判 CONFLICT）。需要升回 0.1.2 兼容版时手动 `dsh plugin --profile web add @linxin666/dsh-web-all@0.3.14 -E`。
- 升级到更高主线时先跑一次预检，把新出现的 `CONFLICT` 纳入弹窗预期。

## 6. 维护注意点

- **共享逻辑只有一份（deploy/shared/）**：Windows boot 与 macOS install 都消费它，不存在"两份要一起改"。
  - Windows 侧不要往 deploy/windows 里放 compat-check 副本；改共享文件只改 `deploy/shared/dsh-web-plugin-compat-check.mjs`。
  - macOS 改完仓库代码后需在 mac 上重跑 `bash deploy/macos/install.sh` 刷新 `~/.dsh/bin`（macOS 是"安装式"部署，与 Windows 的仓库直读不同）。
- **token 认证（dsh ≥ 0.1.2）**：每次进程重启 token 变化，`dsh web` 启动时打印 `?token=...` URL，自启日志可查。
- **路径**：脚本一律用 `%USERPROFILE%`，不硬编码 `C:\Users\xxx`。
- **PATH**：登录自启环境可能不含 node/npm/dsh；`dsh-autostart.cmd` 用 `where dsh` 探测并回退常见全局前缀，`dsh-web-update.ps1` 开头也会把 node bin 前缀 prepend 进 PATH。
- **编码**：`dsh-web-update.ps1` 含中文文案，必须保持 **UTF-8 with BOM**（Windows PowerShell 5.1 否则按 ANSI 误读成乱码）。cmd/install/uninstall 为纯 ASCII。
- **仓库直读的前提**：仓库 checkout 路径稳定（本机约定不变更/删除）。若换路径，改完跑一次 `install.ps1` 即可刷新 Startup 指向。
- **"detached 副本"已废弃**：早期方案把脚本复制进 `%USERPROFILE%\.dsh\bin` 与 `.dsh\`。新 install.ps1 会删除它们；若手动清理，删除 `.dsh\bin\dsh-web-update.ps1`、`.dsh\bin\dsh-web-plugin-compat-check.mjs`、`.dsh\dsh-autostart.cmd` 即可。

## 7. 升级到 0.1.2+ 后恢复全家桶插件（可选）

0.1.2 线要求 `dsh-web-all` ≥ 0.3.9（better-sidebar 0.18.x）、`billing` 兼容版。升级完成后如需恢复：
```powershell
dsh plugin --profile web add @linxin666/dsh-web-all@0.3.14 -E
dsh plugin --profile web add @kenz1117/dsh-ui-usage-billing@<0.1.2兼容版> -E
```
