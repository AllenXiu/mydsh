---
name: pixso-mcp-guidelines
description: 在使用 Pixso MCP（mcp__pixso__* 工具）创建、修改或评审 UI 设计时使用，包括应用设计改动、设计转代码、输出验证。约束先读后写、结构、一致性、组件复用与强制验证，确保产出的 UI 可用、整洁、可维护，而不是杂乱或有缺陷。Use when creating, editing, or reviewing UI designs through the Pixso MCP tools.
---

# Pixso MCP 使用规则

通过 Pixso MCP（`mcp__pixso__*`）创建或修改 UI 设计时的行为守则，目标是产出**可用、整洁、可维护**的设计。这是守则而非脚本清单：按当前任务命中相关条款执行。

## 0. 总则

1. "可用"的定义：结构清晰、层级合理、间距一致、颜色来自设计令牌、无重叠错位、无内容缺失、同类元素尺寸一致。
2. **先读后写**：任何修改前必须了解现状（文档结构、已有变量/样式/组件、目标节点）。
3. **改动必须验证**：每次设计改动后检查截图与布局，不允许"改完不检查"。
4. 每次 `apply_design` 返回的 `Validation failures` 与 `Potential issues` 反馈必须立即处理，不得忽略。

## 1. 动手前（Preflight）

- 调用 `fetch_context` 了解当前文档：选中节点、页面/帧结构、已有变量/样式/组件、可用字体。
- 用 `get_top_level_frames`（type=page 找页面，type=frame 找帧）定位目标页面与帧，不要把新内容放错页面。
- 检查 `get_variables` / `get_local_styles` / `get_all_components`：存在设计令牌或组件时必须复用，禁止绕开它们硬编码。
- 明确本次任务的目标节点 id、画布尺寸、设备类型（移动/桌面）与主操作，先想清结构再动手。

## 2. 读取纪律

- 节点 id 必须来自读取结果（`query_nodes` / `fetch_context` / `get_top_level_frames`），**禁止臆造 id**。
- 组件引用：instance 的 `ref` 必须是用 `query_nodes` / `read_components` 返回的真实 guid；组件集（component set）变体先用 `query_nodes` + `variantName` 解析出真实 guid 再使用。**禁止**用 AssetId、`#n` 句柄或裸云 key 作为 ref。
- 读取时按需选 `fields`、控制 `searchDepth`/`readDepth`（默认 1-3），避免大深度读取撑爆上下文。
- 组件套件批量用 `read_components` 一次列出，不要逐个猜测组件名。

## 3. 结构规则

- **一屏一帧**：每个屏幕/页面一个顶级 frame，命名表达用途（如 `Settings`、`Dashboard`），不用无意义名字。
- 布局用 frame + autoLayout（自动布局）构建，**禁止**纯绝对坐标随意摆放导致重叠、错位、溢出。
- 层级要浅且语义化：frame > 区域 > 组件实例；避免深嵌套的随机 group。
- **一屏一主目标**：一个屏幕一个主导区域、一个主操作；多目标拆成独立表面，不堆砌。
- `apply_design` 单次调用 ≤ 100 个操作，复杂设计拆成多个小批次（如表格一次 2-3 行）。绑定名只在同一调用内有效，跨调用引用必须用字面量节点 id。
- 大型构建后使用 `check_layout`（`problemsOnly: true`）审计布局问题。

## 4. 一致性（设计系统）

- 颜色、圆角、字号、间距优先使用文件内变量/令牌（如 `$--background`、`$--primary`、`$--border`），**禁止**硬编码 hex/rgb。
- 间距走固定刻度（4/8/12/16/24/32），不混用任意值；同一屏幕内密度模式（紧凑/常规/宽松）保持一致。
- 语义色按用途使用：错误用 error、成功用 success、警告用 warning，不张冠李戴。
- 图标用 `icon_font`（lucide / feather / Material Symbols），从规范图标名选择，禁止手绘替代或乱用 emoji。
- 发现不一致用 `query_all_unique_props` 审计、`replace_props` 统一修正。

## 5. 组件使用

- 设计库存在匹配组件时，**以 instance 整体引用**（`I(..., {type: "instance", ref: "<guid>", descendants: {...}})`），禁止重画一遍相同 UI。
- 只允许覆盖 master 上**已存在的 instance 层**（通过 `descendants` / `U` / 路径 `I`）；不要在非 instance 的 frame/text 上做 `R` 替换，也不要发明 master 中不存在的子树。
- 不要用改 fill 的方式伪造组件变体（primary/danger 等）；用组件集暴露的真实变体轴。
- 组件文字/图标覆盖通过 `descendants` 精确 key 进行，不改结构。

## 6. 验证（必须）

- 每次较大改动后调用 `take_screenshot`（单次最多 3 节点）逐项检查：
  - **内容完整**：无缺失、无空白内容；
  - **布局准确**：无错位、偏移、重叠；
  - **字体完整**：无回退/缺字；
  - **留白合理**：无异常空白区，间距一致；
  - **尺寸一致**：同类元素（按钮/卡片/图标）大小一致；
  - **零容忍**：发现任何小问题必须先修复再交付。
- 设计转代码优先用 `design_to_code`（支持 react/vue/html/flutter/arkui）；用户给 Pixso URL 时提取 `item-id` 作为 guid，不传裸 URL。

## 7. 禁止事项（Do NOT）

- 未经验证就交付；改动后不检查视为未完成。
- 忽略 `apply_design` 的校验反馈与潜在问题提示。
- 存在令牌时硬编码颜色/圆角/间距/字号。
- 臆造节点 id 或组件 ref。
- 同一屏幕混用密度、堆砌多个主操作、添加无关装饰元素。
- 不做任何读取就直接写。
- 重画库中已有的组件。
- 用 URL 的原始字符串或 AssetId 当 guid/ref 使用。

## 8. 工作流（简版）

1. `fetch_context` + `get_top_level_frames` 定位页面/帧，确认目标与约束；
2. 读变量/样式/组件，确定复用项与令牌；
3. 小批量 `apply_design` 构建（每批 ≤ 100 操作，先搭结构再填内容）；
4. `take_screenshot` + `check_layout` 验证并修复所有问题；
5. 交付前复查一次 0-6 节命中条款。
