# deploy/shared — 跨平台共享逻辑（单一来源）

两个平台各自的部署目录（`deploy/macos`、`deploy/windows`）只放本平台的
启动/交互/安装代码；**跨平台纯逻辑只放这里**，两平台共用同一份，避免拷贝后漂移。

当前内容：

- `dsh-web-plugin-compat-check.mjs` — 升级前兼容预检（Node、跨平台）
- `dsh-agent-preset-compat-check.mjs` — agent preset 逐行 schema 校验（Node、跨平台）
- `dsh-agent-preset-mount-probe.mjs` — agent preset 真实挂载探针（Node、跨平台）

## 兼容预检三级判定

检查每个第三方插件（profile bundles 中非 `@deepseek-ai` 的依赖）对**目标宿主版本**
（`--host`，缺省为已安装版本）的兼容性：

| 判定 | 行前缀 | 条件 | 升级流程动作 |
|---|---|---|---|
| REJECT | `!!` CONFLICT | `engines.dsh` 范围违反 / `@deepseek-ai` peer 范围违反 / 内置已知冲突规则（如 web-all <0.3.9 依赖已删的 `settingsNamespace`）/ 冒烟探针证实 import 缺失（仅当目标==当前安装版本时决定性） | **自动卸载**（弹窗单列） |
| WARN | `??` | 仅"显式 `compatibility.dshReleases` 列表未覆盖目标版本"，无其他硬证据（作者可能只是没更新列表） | **保留**，弹窗提示"尚未声明支持" |
| ok | `ok` | 声明兼容 | 不动 |
| 未声明 | `--` | 无任何 host 声明 | 不动（低风险未验证） |

> 冒烟探针：读取插件 server/client 入口产物里的 `@deepseek-ai/*` import，
> 用 `require.resolve` / exports map 对照**已安装宿主**的真实导出。它只在目标版本
> 与当前安装版本一致时才作为 REJECT 的硬证据；对 `--host` 未来版本只是预警
> （升级预览不会因探针判 REJECT）。

## 脚本消费模式

人类可读报告：直接运行（每行一个插件）。
机器可读（提取逻辑只在此文件内；macOS bash 与 Windows PowerShell 不再各自写正则）：

- `--conflict-names` 仅 REJECT 插件包名，一行一个
- `--warn-names`     仅 WARN 插件包名，一行一个
- `--verdict-names`  REJECT/WARN 都输出，格式 `<VERDICT>\t<name>`（TSV）

## agent preset 预检（逐行 schema，`dsh-agent-preset-compat-check.mjs`）

插件预检**看不到 preset**：preset 是 `~/.dsh/.agent-presets/<id>/agent.cordis.yml`
这份组合，可能来自已卸载插件（同步后不清理）或人工编写。而 `settings.yaml` 的
`agent-presets.default` 指向的 preset 一旦挂不上，**所有新建/恢复会话都会失败**
（2026-09-11 的事故：0.1.5 把 `@deepseek-ai/dsh-persona` 的配置键 `text` 改名 `prefix`）。

这个工具把 preset 的每个 row 解析出来，用**本机已安装插件包导出的 `Config`**（就是挂载时
用的那份 schema）校验 row 的 `config`：

```sh
node deploy/shared/dsh-agent-preset-compat-check.mjs                # 检查 <home>/.agent-presets 下全部 preset
node deploy/shared/dsh-agent-preset-compat-check.mjs liangshen      # 按 id
node deploy/shared/dsh-agent-preset-compat-check.mjs /path/to/preset
node deploy/shared/dsh-agent-preset-compat-check.mjs --json         # 机器可读
node deploy/shared/dsh-agent-preset-compat-check.mjs --quiet        # 只留 FAIL
```

行前缀：`ok`（通过）/ `ok?`（插件没导出 `Config`，未做 schema 校验）/ `skip`（row 被禁用）/
`FAIL`（解析不到、import 失败、或 config 不合法）。退出码：`0` 全部通过或没 preset，
`1` 有 FAIL，`2` 用法错误。

覆盖边界：它能判"包能否解析 + config 是否合法"；判不了 isolate realm 之类的结构规则
（那些交给下面的挂载探针）。

## agent preset 挂载探针（端到端，`dsh-agent-preset-mount-probe.mjs`）

静态校验通过不等于挂得上。这个工具启动一个真实 dsh app（默认 `headless`，便宜），插入
`agent-presets` 行并调用 `agentPresets.standingKeyFor(id)` —— **与会话创建/恢复走的
`mountPreset` 同一条路径**，无需浏览器、不发模型请求：

```sh
node deploy/shared/dsh-agent-preset-mount-probe.mjs                       # 探 settings.yaml 里的默认预设
node deploy/shared/dsh-agent-preset-mount-probe.mjs --preset liangshen
node deploy/shared/dsh-agent-preset-mount-probe.mjs --preset standard --profile web  # 忠实 host scope（随机端口起 web）
node deploy/shared/dsh-agent-preset-mount-probe.mjs --json
```

判定：`OK` / `FAIL(config)`（含 `invalid config`，= row schema 不兼容，**与 app 无关，
可直接据此回退或修复**）/ `FAIL(host)`（其他原因，可能是 `headless` host scope 的假阳性，
用 `--profile web` 复核）/ `INCONCLUSIVE`（超时、无 `dsh`、无输出）。
退出码：`0` 全 OK、`1` 有 FAIL、`2` 不确定。

它**不留痕迹**：overlay 与会话都建在临时目录里（子进程 cwd 也在那里），运行结束删掉本次
产生的空会话及其 projcache 投影，`workspace.json` 不动。`DSH_BIN=<path>` 可指定 dsh 可执行文件
（launchd 之类的精简 PATH 环境需要）。

> macOS 侧的消费方：`deploy/macos/dsh-web-preset-gate.sh` 在**每次启动 web 前**与**升级 dsh 成功后**
> 调用本工具；`FAIL(config)` 先幂等修复已知改名、仍失败则把 `agent-presets.default` 回退为 `standard`
> 并弹窗告知（见 `deploy/macos/README.md`）。

## 官方新版刚发布时的 ETARGET（传播延迟）

官方发布一个版本时，主包与它的各个子包是**分多次写入 npm registry** 的，且 registry
有多个镜像节点。因此刚发布后的几分钟内，本机命中的节点可能缺少某个必需子包版本，
`npm install -g @deepseek-ai/dsh@latest` 会以传播类错误失败：

```
npm error code ETARGET
npm error notarget No matching version found for @deepseek-ai/dsh-client-ui-sidebar-right@^0.1.5-rc.2
```

这是**暂时状态**（同一命令稍后重跑即成功），不是配置或插件问题。两个平台因此都在
升级步骤内置**自动重试**：

- 仅当输出匹配 `ETARGET|notarget|No matching version` 时重试；其他错误立即停止
- 最多 4 次尝试，失败间隔 30s → 60s → 120s
- 每次尝试前清空 live 日志，避免上一次的错误残留影响判定
- 进度窗口在等待期间显示倒计时（macOS 与 Windows 一致）
- 尝试用尽仍失败：保持当前宿主版本不变，退出码 0（不重启 web）

> 失败时宿主版本不会被改动（npm 解析失败不会产生半安装状态），web 继续跑原版本。

## 维护约定

- 改共享逻辑只改本目录；两平台 pull 后各自生效：
  - Windows：开机直读仓库 `deploy/shared/`
  - macOS：重跑 `bash deploy/macos/install.sh` 拷到 `~/.dsh/bin`（三个共享脚本一起拷）
- **不要**在 `deploy/macos` 或 `deploy/windows` 里放 compat-check / preset 工具的副本。
- 三个工具都是纯 Node（`node:<builtin>` + 从 dsh 依赖树里加载 `yaml`/`semver`），没有自带依赖，
  可在两平台用同一个 `node` 跑。
