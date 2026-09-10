# dsh 部署与调试 — 会话交接文档

> 用途：记录 2026-09-05 ~ 09-10 这段会话在 macOS/Windows 上部署与维护 dsh（DeepSeek Harness）
> 的全部工作、根因结论、当前状态与遗留事项，便于在新会话中直接接手。
> 仓库：`/Users/allern/Codes/GitHub/mydsh`（fork of deepseek-harness，远程 `origin` = AllenXiu/mydsh）

## 一、总体目标与最终形态

把官方 dsh 以**稳定、可自更新、不被插件拖垮**的方式部署在 macOS（本机）和 Windows（另一台）上：

- 运行的是**官方 npm 发布版**（`@deepseek-ai/dsh`），不使用本仓库 fork 的代码
- 每次启动/解锁时**检查更新**，但**是否更新由人确认**（弹窗），不静默升级
- 升级前做**插件兼容性预检**；确证不兼容的插件**自动卸载**，保证主项目能起来
- 更新过程有**进度窗口**；官方刚发布导致的 registry 传播延迟**自动重试**
- 每次重启后输出当前带 token 的访问 URL（dsh ≥0.1.2 有浏览器认证）

## 二、部署资产（仓库内）

```
deploy/
├── shared/                                  # 跨平台唯一来源
│   ├── dsh-web-plugin-compat-check.mjs     # 插件兼容预检（Node，跨平台）
│   └── README.md                            # 三级判定 / 消费模式 / ETARGET 重试约定
├── macos/                                   # macOS 平台实现
│   ├── install.sh / uninstall.sh            # 安装/卸载（拷脚本、编译 Swift、装 LaunchAgent）
│   ├── dsh-web-autostart.sh                 # 启动入口：确认更新 → 启动 web（前台 exec）
│   ├── dsh-web-confirm-update.sh            # 确认弹窗 + 冲突卸载 + 进度窗 + ETARGET 重试
│   ├── dsh-web-unlock.sh                    # 解锁后检测（有新版则询问）
│   ├── dsh-web-unlock-watcher.swift         # 常驻：监听解锁/唤醒事件（编译为二进制）
│   ├── dsh-update-progress.swift            # 更新进度窗口（编译为二进制）
│   ├── dsh-web-plugin-lock.sh               # 手动工具：禁用/恢复指定插件（已不用于升级流程）
│   ├── com.allern.dsh-web.plist             # LaunchAgent：持有 web 进程
│   └── com.allern.dsh-web-unlock.plist      # LaunchAgent：常驻解锁监听
└── windows/                                 # Windows 实现（仓库直读）
    ├── install.ps1 / uninstall.ps1
    ├── dsh-autostart.cmd                    # Startup 指向的启动脚本
    ├── dsh-web-autostart.vbs                # Startup 模板
    ├── dsh-web-update.ps1                   # 确认弹窗 + 冲突卸载 + 进度窗 + 重试
    └── README.md
```

macOS 运行时目录（由 install.sh 生成/拷贝）：

```
~/.dsh/bin/
├── dsh-web-autostart.sh / dsh-web-unlock.sh / dsh-web-confirm-update.sh
├── dsh-web-plugin-lock.sh
├── dsh-web-plugin-compat-check.mjs   # 从 deploy/shared 拷入
├── dsh-web-unlock-watcher            # swiftc 编译产物
└── dsh-update-progress               # swiftc 编译产物
~/Library/LaunchAgents/com.allern.dsh-web{,-unlock}.plist
```

## 三、已实现的关键能力

| 能力 | 说明 | 关键文件 |
|---|---|---|
| 登录自启 | LaunchAgent 持有 web 进程（前台 `exec`，launchd 管理生命周期） | `com.allern.dsh-web.plist` |
| 解锁后检查更新 | Swift 常驻 watcher 监听 `com.apple.screenIsUnlocked`/会话激活/唤醒 | `dsh-web-unlock-watcher.swift` |
| 更新前人工确认 | macOS `osascript` 原生弹窗；Windows `MessageBox` | `dsh-web-confirm-update.sh` / `dsh-web-update.ps1` |
| 插件兼容预检（三级） | REJECT(`!!`) 自动卸载 / WARN(`??`) 保留并提示 / ok / 未声明 | `deploy/shared/dsh-web-plugin-compat-check.mjs` |
| 冒烟探针 | 扫描插件入口真实 `@deepseek-ai/*` import，用 `require.resolve` 对照宿主导出 | 同上 |
| 冲突插件自动卸载 | 仅卸载 REJECT；用 `--verdict-names` TSV 取名单 | confirm-update.sh / ps1 |
| 更新进度窗口 | 转圈 + 简短阶段文案（**不显示 npm 原文以免撑宽**）+ 完成/失败态 | `dsh-update-progress.swift` |
| registry 传播延迟重试 | 仅 `ETARGET/notarget/No matching version` 重试，30/60/120s，最多 4 次 | confirm-update.sh / ps1 |
| token URL 落盘 | 每次重启把当前 `?token=...` URL 写入 `~/.dsh/current-url.txt` | dsh-web-autostart.sh |

## 四、本次会话解决的问题（按时间顺序）

### 1. 建立 macOS 部署
- nvm（`~/.nvm`）+ Node 22 LTS；官方包 `npm install -g @deepseek-ai/dsh`
- 最初是"登录时自启 + 每次解锁静默更新"，后按需求改为**更新前弹窗人工确认**

### 2. 版本线冲突（反复出现的核心问题）
插件生态里有大批**按 0.1.1 API 构建**的插件，在 0.1.2+ 宿主上启动即崩：

| 插件 | 崩溃原因 | 处理 |
|---|---|---|
| `@kenz1117/dsh-ui-usage-billing` 1.1.x | import `@deepseek-ai/dsh-client-runtime/client`（0.1.2 已删除该子路径导出） | 卸载；其 `compatibility.dshReleases` 只列到 0.1.1-rc.2 |
| `@linxin666/dsh-web-all` < 0.3.9 | 依赖 `dsh-better-sidebar` 0.15.x，用 0.1.2 已删的 `settingsNamespace` | 已写入 compat-check **内置已知规则**（明确判 REJECT） |
| `dsh-github-connect` | 直接依赖 `@deepseek-ai/dsh-tools@0.1.1-rc.2`（旧线），import 已删的 `CallId` | 卸载（`--config.minimumReleaseAge=0` 绕过策略） |
| `dsh-plugin-notify` 0.1.1 | 入口 `import { settingsNamespace } from '@deepseek-ai/dsh-settings'`（0.1.2 已删） | 卸载（作者未适配，npm 最新仍是 0.1.1） |

**结论**：这类"装完就崩"的插件**静态声明常常看不出问题**（peerDeps 写 `*`、无 engines），必须靠**冒烟探针**（真实 import 解析）或运行时发现。

### 3. 插件兼容预检升级为三级判定 + 冒烟探针
- **REJECT(`!!`)**：engines 范围违反 / `@deepseek-ai` peer 范围违反 / 内置已知规则 / **冒烟探针证实 import 缺失**（仅当"目标版本==当前安装版本"时作为硬证据）
- **WARN(`??`)**：仅"显式 compatibility 列表未覆盖目标版本"，无其他硬证据 → **保留**（修复了 usage-billing 式误杀）
- 冒烟探针关键点：
  - 解析插件 server（`.`/`./host`）与 client（`./client`）入口产物
  - 打包代码的 require 被压缩成短别名（`e("@deepseek-ai/x")`），正则需匹配**任意标识符调用**
  - **client 端裸包名**（如 `dsh-client-ui-primitives`）属浏览器模块表，不做硬判
  - `require.resolve` 从插件自身解析链出发，能命中 profile fallback / dsh 安装

### 4. 升级流程改造（弹窗 → 卸载冲突 → 进度 → 重试）
- 点"更新"时：先用 `--verdict-names` 取 REJECT 名单 → **逐个 `dsh plugin remove`** → 再 `npm install -g`
- WARN 插件**保留**并在弹窗单列"尚未声明支持，本次保留"
- 进度窗口只显示简短阶段文案（早期版本直接显示 npm 原文，把窗口撑得很宽，已移除）
- **ETARGET 自动重试**：官方发布时主包与子包分批写入 registry，命中未同步节点会报 `notarget`；
  该错误按 30s/60s/120s 重试（最多 4 次尝试），仅对传播类错误重试

### 5. 浏览器认证（dsh ≥0.1.2）
- 每次进程启动生成随机 launch token；用 `http://127.0.0.1:3080/?token=...` 打开一次 → 种下
  **绑定 authority 的 host-only cookie**（默认 30 天）
- **`localhost` 与 `127.0.0.1` 是两个独立 cookie 域**：用 127.0.0.1 种过 cookie 后，
  `localhost:3080` 仍会报 `authentication required`；需各自带 token 打开一次
- 建议固定使用 `127.0.0.1`（dsh 打印的地址），并用 `~/.dsh/current-url.txt`

### 6. 诊断过的运行期异常
| 现象 | 根因 | 处理 |
|---|---|---|
| 浏览器报 `boot manifest batches must be an array` | 手动 `nohup` 启动的旧进程缓存了已卸载插件的 client 配置 | 杀掉孤儿进程，用 launchd 干净重启 |
| web 由 dshmarket 拉起、`launchctl` 显示 `not running` | dshmarket 有自己的 restart 机制（日志在 `/var/folders/.../dsh-market-restart-*.log`），**绕过 LaunchAgent** | 需用 `bootout + bootstrap` 恢复托管 |
| `launchctl bootstrap` 报 `Input/output error` | bootout 后立即 bootstrap 的瞬时状态 | bootout → sleep 2 → bootstrap（失败再重试） |
| 更新后 web 仍跑旧版本 | kickstart 未生效、旧进程仍在监听 | `bootout` + `kill` 旧进程 + `bootstrap` |

## 五、当前状态（2026-09-10）

| 项 | 值 |
|---|---|
| 宿主 dsh | **0.1.5-rc.1**（官方 `latest`；`next` = 0.1.5-rc.2） |
| web | 运行中，`127.0.0.1:3080`，由 launchd 托管（`state = running`） |
| 已装插件 | 仅 **dshmarket**（其余第三方插件已卸载） |
| 访问地址 | `~/.dsh/current-url.txt`（token 每次重启变化） |
| git | `master` 与 `origin/master` 同步，工作树仅剩未跟踪的 `dsh-market-log.txt` |

## 六、遗留事项 / 下次待办

1. **【未解决】切换到 "DeepSeek-V4.1-Flash" 报错**
   - 该名字是 dsh 内置模型的**显示名**，对应 id **`deepseek-flash`**（定义在 `dsh-llm-deepseek`）：
     `{ id: "deepseek-flash", name: "DeepSeek-V41-Flash" }`
   - 已验证**服务端可用**：API `/models` 返回它、直接 curl 成功、**headless 实跑成功**
   - **仍缺用户侧错误原文**（触发时机：切换瞬间 vs 发消息；是否带图片；界面提示 vs 浏览器 console）
   - 待用户提供错误后再定位（怀疑方向：Web UI 侧 / 插件干扰 / 图片请求）
2. **Windows 侧未实测**：`deploy/windows/dsh-web-update.ps1` 的登录重试状态机（30/60/120s + 倒计时）
   是本次新写的，macOS 无 `pwsh` 无法本地验证语法，需在 Windows 上跑一次确认。
3. **dshmarket 重启绕过 launchd**：market 自己的 restart 不经过 LaunchAgent，导致 web 变成
   "由 market 拉起的进程"、`launchctl` 状态不一致。可考虑在检测到该情况时自动纠回托管。
4. **"装插件后启动崩溃"无防护**：当前冲突卸载只在**升级 dsh 时**触发；**装插件后重启**这条路
   没有预检（github-connect / dsh-plugin-notify 都是这么崩的）。候选方案：
   - 把已知规则扩充（如"凡 import `settingsNamespace` 者 = 0.1.2+ REJECT"）
   - 启动前做一次 `dump-config` / 模块解析冒烟，失败则禁用最近安装的插件
5. **可选**：dsh 自身更新失败时（重试耗尽）是否要顺带提示/处理 web 版本不一致。

## 七、常用命令

```bash
# 服务管理
launchctl print gui/$(id -u)/com.allern.dsh-web | grep -E 'state|pid'
launchctl bootout   gui/$(id -u)/com.allern.dsh-web          # 停止
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.allern.dsh-web.plist   # 启动（EIO 时 sleep 2 重试）
launchctl kickstart -k gui/$(id -u)/com.allern.dsh-web       # 重启（注意有时不生效）

# 一键重启（含探测）
cd /Users/allern/Codes/GitHub/mydsh && ./restart-dsh-web.sh

# 插件兼容预检
node ~/.dsh/bin/dsh-web-plugin-compat-check.mjs                  # 人类可读
node ~/.dsh/bin/dsh-web-plugin-compat-check.mjs --host 0.1.5-rc.2 # 预览目标版本
node ~/.dsh/bin/dsh-web-plugin-compat-check.mjs --verdict-names   # TSV: <!!|??>\t<name>
node ~/.dsh/bin/dsh-web-plugin-compat-check.mjs --conflict-names  # 仅 REJECT 名单

# 插件管理（minimumReleaseAge 拦截时加 --config.minimumReleaseAge=0）
cd ~/.dsh/profiles/web
dsh plugin --profile web remove <name> [--config.minimumReleaseAge=0]
dsh plugin --profile web add    <name> [--config.minimumReleaseAge=0]

# 日志
tail -f ~/.dsh/autostart-update.log     # 更新/启动流程
tail -f ~/.dsh/web.log                  # web 进程输出 + 启动错误
cat  ~/.dsh/npm-install.live.log        # 最近一次 npm 安装原始输出
cat  ~/.dsh/update-progress.txt         # 进度窗口最终状态
cat  ~/.dsh/current-url.txt             # 当前带 token 的访问地址
ls -lat /private/var/folders/*/*/T/dsh-market-restart-*.log   # dshmarket 自行重启的日志

# 手动启动 web（排障用；正常应由 launchd 托管）
dsh web --no-open          # 前台；错误会直接打印
```

## 八、重要经验（下次直接用）

1. **弹窗确认式更新**比静默更新安全得多：官方 latest 从 0.1.1→0.1.2→0.1.5 的每次大版本跨越
   都伴随着插件 API 破坏，静默升级会把 web 直接搞挂。
2. **`localhost` ≠ `127.0.0.1`**（cookie 域不同）：dsh 浏览器认证下必须用同一种 host 并各自带 token 打开一次。
3. **装完插件报"重启"时要警惕**：市场里存在用旧 API 构建、无兼容声明的插件，装了就会启动崩溃。
   自保流程：`dsh plugin remove <插件>` → 重启 web。
4. **别用 `nohup` 手动起 web 做长期运行**：会造成孤儿进程、日志错位、boot manifest 缓存旧配置。
   用 launchd；排障时前台跑 `dsh web` 看错误即可。
5. **`npm install` 的 ETARGET 多数是传播延迟**，等 1~2 分钟重试即可，不是配置问题。
6. **最小发布年龄策略**（dshmarket 的 `minimumReleaseAge`）会拦截卸载/安装：
   用 `--config.minimumReleaseAge=0` 一次性绕过（脚本内已按需使用）。
7. 会话日志是 **zstd 多帧**打包（`~/.dsh/sessions/*/session.v3.jsonl.zstd`）；
   Node 的 `zlib.createZstdDecompress()` 流式解压可读（`zstdDecompressSync` 只解首帧）。

