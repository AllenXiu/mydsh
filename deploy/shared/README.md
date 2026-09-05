# deploy/shared — 跨平台共享逻辑（单一来源）

两个平台各自的部署目录（`deploy/macos`、`deploy/windows`）只放本平台的
启动/交互/安装代码；**跨平台纯逻辑只放这里**，两平台共用同一份，避免拷贝后漂移。

当前内容：

- `dsh-web-plugin-compat-check.mjs` — 升级前兼容预检（Node、跨平台）

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

## 维护约定

- 改共享逻辑只改本目录；两平台 pull 后各自生效：
  - Windows：开机直读仓库 `deploy/shared/`
  - macOS：重跑 `bash deploy/macos/install.sh` 拷到 `~/.dsh/bin`
- **不要**在 `deploy/macos` 或 `deploy/windows` 里放 compat-check 副本。
