# dsh 部署与调试 — 会话交接文档

> 用途：记录 2026-09-05 ~ 09-11 这几段会话在 macOS/Windows 上部署与维护 dsh（DeepSeek Harness）
> 的全部工作、根因结论、当前状态与遗留事项，便于在新会话中直接接手。
> 仓库：`/Users/allern/Codes/GitHub/mydsh`（fork of deepseek-harness，远程 `origin` = AllenXiu/mydsh）
> 本文档本身在 09-11 凌晨由 `deploy/` 移入 `deploy/macos/`（迁移尚未提交，见 §五）。

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

dsh 自身的运行时状态（**不是 deploy 资产，但决定 web 能不能开会话**；排障必看）：

```
~/.dsh/settings.yaml                    # agent-presets.default = "新会话用哪个预设"
~/.dsh/.agent-presets/<id>/             # 运行时预设：插件同步进来的 + 用户自建的（每个 = 一份 agent.cordis.yml 组合）
~/.dsh/sessions/<workspace>/<session-id>/
~/.dsh/storages/workspace.json          # Web UI 的会话列表来源（每个 workspace 的 sessionIds）
~/.dsh/storages/session_projcache*      # 会话行投影（标题 / token 用量 / 最近提示）
```

> `agent-presets.default` 指向的预设**挂载失败 = 所有新建/恢复会话全废**，见 §四.7。

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

> 预检只覆盖**已安装插件的静态声明**：它看不到**插件卸载后残留在 `~/.dsh/.agent-presets/` 的 preset**，
> 也看不到 **`settings.yaml` 里默认预设指向谁**。§四.7 的事故正是这一类（预检全绿但会话全挂）。

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

### 7. 预设兼容性事故：所有会话打不开（2026-09-11 凌晨）

**症状**（用户报的三件事，其实是同一个根因）：

1. 点「新建会话」**毫无反应**（不报错、也进不去会话），但磁盘上多出一个空会话；
2. 切换模型报
   `模型操作失败：gateway/internal: resume failed for session "session-…": … preset "liangshen" failed to mount: failed to apply loader entry persona (@deepseek-ai/dsh-persona): invalid config: - $.prefix missing required value (at prefix)`；
3. 几个工作区里堆着**和目录名一样的空会话**。

**根因**：`~/.dsh/settings.yaml` 的 `agent-presets.default: liangshen`，而 `~/.dsh/.agent-presets/liangshen`
是按 **0.1.2** 写的预设——persona 行的配置键在 0.1.5 改名了：

| 宿主版本 | `@deepseek-ai/dsh-persona` 的 Config |
|---|---|
| 0.1.2-rc.1 | `{ text: required, complete, includeRuntimeContext }` |
| 0.1.5-rc.1 / rc.2 | `{ prefix: required, suffix, complete, includeRuntimeContext }` |

09-10 23:11 升到 0.1.5-rc.1 后，任何"新建/恢复会话"都在**挂载预设**这一步失败：新建只剩一行 header
（cwd 默认 `/private/tmp`），前端拿不到可用会话 → 表现为"没反应"；`resume` 失败则把错误挂在"切换模型"上。

**证据链（方法可复用）**：

1. **schema 对比**：拉 0.1.2-rc.1 的 `@deepseek-ai/dsh-persona` tarball，与本地安装版对比 `Config`（两版见上表）；
2. **逐行 schema 校验**：用 profile 里**实际安装**的插件包，对 `agent.cordis.yml` 每个 row 调用它自己导出的
   `Config()`（= 挂载时的配置校验）→ 修复前唯一 FAIL 就是 `persona … $.prefix missing required value`（与用户原文一致），修复后 **34/34 通过**；
3. **挂载探针**（端到端，不需要浏览器）：`--patch` 往 headless 组合里 insert `@deepseek-ai/dsh-agent-presets`
   + 一个注入 `agentPresets` 的小插件，调 `await ctx.agentPresets.standingKeyFor(id)`
   —— 这正是会话创建走的 `mountPreset`。故意保留旧键的副本 **FAIL**（报错原文一致）、修好的 **OK**；
4. **上游核对**：`@linxin666/dsh-liangshen` 的 0.3.16 / 0.3.19 / 0.3.20 打出来的
   `presets/liangshen/agent.cordis.yml` **全部**是 `text:`（0.3.20 还把 manifest 声明提到 `dsh >=0.1.5-rc.1` 却没迁移键名）→ 上游 bug。

**这个 preset 是怎么来的**：`@linxin666/dsh-web-all`（全家桶）把 `@linxin666/dsh-liangshen` 列为**硬依赖**；
插件启动时把自带 preset 同步进 `~/.dsh/.agent-presets/`。**卸载全家桶不会清理这个目录**，而 settings 里的默认值
仍指着它 → 雷留在原地（用户并未单独安装过 liangshen）。

**修复**：`~/.dsh/.agent-presets/liangshen/agent.cordis.yml` 的 `text:` → `prefix:`
（旧文件备份为同目录 `agent.cordis.yml.bak-0.1.2`）；`settings.yaml` 默认值保持 `liangshen`。

**清理**：删 5 个空会话 + 4 个排障用会话（备份 `~/.dsh/sessions-backup-20260911-000033.tgz`），
并同步 prune `storages/workspace.json` 的 `sessionIds` 与 `session_projcache`（**只删目录不清索引会留幽灵行**）；
把再次变成"launchd 外孤儿进程"的 web 纠回托管（`bootout` → kill → `bootstrap`）。

**⚠️ 会被覆盖**：重装/升级 `dsh-web-all`（或 liangshen）会把带 `text:` 的 preset **重新同步回来**→ 同样崩溃。
装完必须重打这个补丁，或把 `agent-presets.default` 改回 `standard`。

## 五、当前状态（2026-09-11 00:1x）

| 项 | 值 |
|---|---|
| 宿主 dsh | **0.1.5-rc.1**（官方 `latest`；`next` = 0.1.5-rc.2）。注意：`latest` 主包的子依赖已解析到 **0.1.5-rc.2**（如 `dsh-persona`），真实 schema 以 rc.2 为准 |
| web | launchd 托管 `state = running`（本轮 pid 77148），`127.0.0.1:3080` |
| 已装插件 | 仅 **dshmarket 1.45.1**（`dsh plugin --profile web list`） |
| 默认预设 | `agent-presets.default: liangshen`，**已打 0.1.5 兼容补丁**（34/34 行通过校验、挂载探针 OK；旧文件备份在预设目录内） |
| 会话 | 4 个真实会话（DeskMeter / Dao-Struggle / server / aliyunOssBrowser 各 1）；空会话已清理（备份见 §四.7） |
| 访问地址 | `cat ~/.dsh/current-url.txt`（token 每次重启变化） |
| `~/.dsh/update-progress.txt` | 仍是 09-10 23:04 那次失败的 `STATUS:ERROR` —— 历史残留，不代表当前状态 |
| git | `master` **ahead 1**（`03b4e10` 未推送）；工作树：`deploy/SESSION-HANDOFF.md` 已删除、`deploy/macos/SESSION-HANDOFF.md`（本文件）未跟踪、`dsh-market-log.txt` 未跟踪 |

## 六、遗留事项 / 下次待办

1. **【已定位，待 UI 复核】切换 "DeepSeek-V4.1-Flash" 报错 = §四.7 的预设挂载失败**
   - 模型 id `deepseek-flash` 本身没问题（服务端可用、headless 实跑成功）；**切换模型会 resume 会话**，
     resume 在挂载默认预设时炸掉，于是错误挂在"切换模型"上（原文见 §四.7 症状 2）。
   - 修复后请在 UI 里再切一次模型复核；通过即可结案（原怀疑方向"Web UI / 图片请求"排除）。
   - 附：该名字是内置模型的**显示名**，id 为 `deepseek-flash`（定义在 `dsh-llm-deepseek`）。
2. **上游 liangshen preset 不兼容 0.1.5**：0.3.16–0.3.20 的 preset 全是 `text:`，而 0.3.20 的 manifest 已声明
   `dsh >=0.1.5-rc.1` —— 值得给上游提 issue。本地对策见 §四.7 的"⚠️ 会被覆盖"。
3. **把"默认预设可挂载"纳入自检**（预防性设计，未实现）：
   - 位置：**升级 dsh 之后、启动 web 之前**各跑一次（升级前跑没意义：目标版本的插件还没装）；
     外加**每次启动**跑一次，覆盖"装插件/插件同步 preset 后重启"这条路。
   - 手段：挂载探针（`standingKeyFor(default)`，见 §七）；失败时
     **① 自动回退 `agent-presets.default` → `standard`（会话立刻可用）+ 弹窗/日志提示**；
     **② 对已知改名做幂等修复**（`persona.text` → `prefix`）。
   - 边界：它治的是**后果**（会话全废），不是插件不兼容本身；要防"再被覆盖"，必须在插件同步 preset 之后再跑一次。
   - 若无预设 / 默认预设是内置的 `standard`，则**根本不会有这个问题**（Windows 侧默认即如此）。
4. **Windows 侧未实测**：`deploy/windows/dsh-web-update.ps1` 的登录重试状态机（30/60/120s + 倒计时）
   是 09-10 新写的，macOS 无 `pwsh` 无法本地验证语法，需在 Windows 上跑一次确认。
5. **dshmarket 重启绕过 launchd**：market 自己的 restart 不经过 LaunchAgent，web 会变成"launchd 外的孤儿进程"
   （本轮 09-11 00:00 又复现一次，已用 `bootout` + kill + `bootstrap` 纠回）。可考虑检测后自动纠托管。
6. **"装插件后启动崩溃"无防护**（09-10 记的 github-connect / dsh-plugin-notify 是同一类；本轮又多了 preset 变体）：
   - 把已知规则扩充（如"凡 import `settingsNamespace` 者 = 0.1.2+ REJECT"）；
   - 或落地 #3 的启动前挂载探针，失败则回退默认预设 / 禁用最近安装的插件。
7. **ETARGET 重试分支从未真正触发**：09-10 23:04 那次 `npm install` 确实报了
   `notarget … dsh-client-ui-sidebar-right@^0.1.5-rc.2`（`~/.dsh/npm-install.live.log` 仍在），
   但日志里**没有任何** `registry not in sync yet; retrying`（21 秒即失败退出）。怀疑当时跑的是
   `~/.dsh/bin` 里的旧副本（该文件 mtime 23:16 = 事后才刷新）。需在真实 ETARGET 或用伪造 `npm` 的 shim 下验证该分支。
8. **排障工具收编**：本轮的"逐行 schema 校验器"与"挂载探针"是纯 Node、跨平台的，现在只存在于 `/tmp`（易失）。
   建议收进 `deploy/shared/` 并在其 README 登记（与 compat-check 同级）。
9. **可选**：dsh 自身更新失败（重试耗尽）时是否顺带提示/处理 web 版本不一致（原 #5）。

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

# 预设（agent preset）—— §四.7 事故的排查与修复
grep -A2 'agent-presets' ~/.dsh/settings.yaml    # 当前默认预设是哪个
ls ~/.dsh/.agent-presets/                        # 运行时预设（插件同步来的 + 自建的）
grep -n -A3 'dsh-persona' ~/.dsh/.agent-presets/*/agent.cordis.yml   # 0.1.5 要求 prefix（0.1.2 时代写的是 text）

# 修已知改名（改前先备份；注意插件重装会把它覆盖回去，见 §四.7）
cp ~/.dsh/.agent-presets/liangshen/agent.cordis.yml /tmp/preset.old
sed -i '' 's/^    text:/    prefix:/' ~/.dsh/.agent-presets/liangshen/agent.cordis.yml

# 会话/存储排障：只删会话目录会留幽灵行，索引要一起清
ls ~/.dsh/sessions/*/*/ | head
python3 /tmp/sweep-orphans.py    # 清掉 projcache 里磁盘已不存在的会话投影
```

### 预设挂载探针（不依赖浏览器；复现/验证 §四.7 这类故障）

`/tmp/preset-mount-probe.mjs`：

```js
export const name = 'preset-mount-probe'
export const inject = ['agentPresets']
export function apply(ctx, config) {
  void (async () => {
    for (const id of config.ids ?? []) {
      try { console.log(`PRESET-PROBE OK   ${id}`, JSON.stringify(await ctx.agentPresets.standingKeyFor(id))) }
      catch (error) { console.log(`PRESET-PROBE FAIL ${id}`, error?.message ?? String(error)) }
    }
    process.exit(0)
  })()
}
```

`/tmp/probe-preset.yml`：

```yaml
- insert:
    - id: agent-presets
      name: '@deepseek-ai/dsh-agent-presets'
      config:
        default: liangshen
    - id: preset-mount-probe
      name: ./preset-mount-probe.mjs      # 相对 patch 文件所在目录
      config:
        ids: [liangshen]
```

运行：`dsh --profile headless --patch /tmp/probe-preset.yml noop`，看 `PRESET-PROBE OK/FAIL` 行。

> `headless` 组合本身**没有** `agent-presets` 行，所以必须先 `insert`；探针调的就是会话创建走的
> `mountPreset`。反过来说：不加 `--patch` 时 headless 不挂载任何预设，它"跑成功"**不能**证明预设可用。

逐行 schema 校验器（本轮为 `/tmp/validate-preset.mjs`）：解析 `agent.cordis.yml` → 每个 row 的 `name`
从 `~/.dsh/profiles/node_modules`（+ dsh 自带 `node_modules`）解析到插件包 → `import` 它导出的 `Config`
→ 对 row 的 `config` 调一次（挂载时的配置校验就是这样跑的）。它能覆盖"包是否可解析 + 配置是否合法"，
覆盖不到 isolate realm 那类结构规则。

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
8. **默认预设是"全局单点"**：`settings.yaml` 的 `agent-presets.default` 指向的 preset 只要挂不上去，
   **所有新建/恢复会话全废**，而症状会伪装成"新建会话没反应"、"切换模型失败"（§四.7）。排障第一步先查它。
9. **插件自带的 preset 卸载后不清理**：插件启动时把 `presets/<id>` 同步进 `~/.dsh/.agent-presets/`，
   卸载**不会**删目标目录；`dsh-web-all` 把 liangshen 作为**硬依赖**带进来，所以"用户没装过"照样中招。
   同步是**单向覆盖**：重装/升级插件会覆盖你对 preset 的任何修补。
10. **0.1.5 的 persona 配置键改名**：`text:` → `prefix:`（并新增 `suffix`）。凡 0.1.2 时代写的
    preset/组合，升级到 0.1.5 都要迁移这一处。
11. **"某功能全挂"先看运行时资产，再看代码**：`~/.dsh/settings.yaml` → `~/.dsh/.agent-presets/`
    → `~/.dsh/storages/*`。本轮是"预检全绿 + 宿主最新 + 只装一个插件"，但默认预设指向的残留文件已失效。
12. **空会话 = header-only 残留**：会话目录只剩一行 header（几十~几百字节、0 事件）时，UI 用 cwd 目录名当
    标题显示 → 就是"和目录名一样的空会话"。删这类会话要**同时**清 `storages/workspace.json` 的 `sessionIds`
    与 `session_projcache`（否则列表留幽灵行），删前先备份。
13. **headless 不能用来验证预设**：headless 组合里没有 `agent-presets` 行，它的会话不会挂任何预设
    （要用 `--patch` 插进去才能验证）；`--dump-config` 只看组合、不校验 preset。
