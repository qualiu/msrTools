# Set Mining

> **nin**: 原生集合运算（diff/intersection/unique/distribution），无需预排序（不同于 `comm`/`uniq`），支持 regex key 提取和结构保留过滤（`-wn` 编辑 hosts/config 保留注释）。内置 Pareto 分析（`--sum -K` 数据驱动 auto top-N），与 msr 管道协作完成 搜索→分析→drill-down 闭环。

> **何时优先于 sort|uniq / Excel / Python pandas：**
> - **无需预排序**：`nin file nul "(\w+)" -pd` 直接输出频率分布（`sort | uniq -c | sort -rn` 需要预排序，且不支持 regex key）
> - **内置 Pareto**：`--sum -K 5.0` 自动过滤 ≥5% 的项并输出累计百分比（Excel pivot / pandas 需多步操作）
> - **diff/intersection 无需预排序**：`nin file1 file2 "(key-regex)"` 直接比较（`comm` 要求预排序双文件）
> - **结构保留编辑**：`-wn` 删除条目时保留注释和空行（sed/awk 做不到或很复杂）

> **Quick Win** — 一条命令找出 log 中最多的异常类型 Top 5：
> ```
> msr -rp logs/ -f "\.log$" -t "(\w+Exception)" -PIC | nin nul "(\w+Exception)" -pd --sum -H 5
> ```
> 立即看到频率分布 + 累计百分比，无需导出到 Excel。

## AI Agent Default Card

若任务是“比较两组结果 / 找 top-N / 看热点分布 / 保结构过滤”，默认按这个顺序：

1. 先定义 comparison target
2. 再定义 comparison key
3. 再决定输出形式
4. 默认先看 top N 或 cumulative summary
5. 最后把结果翻译成下一步动作

默认不要：

- 一上来按整行比较
- 一上来输出完整长尾
- 还没分清 difference / intersection / distribution 就开始分析
- 统计结果出来后不转化成行动结论

## Why an agent should prefer this skill

这个 skill 的价值在于，它把“肉眼翻数据”改成“可重复的集合分析”：

- diff / intersection / Pareto / top-N 都能直接表达
- 不需要先把数据导入 Excel 或 pandas
- 不需要先排序再做集合操作
- 更容易从搜索结果直接过渡到热点分析和 drill-down

## Trigger

在以下场景触发本 skill：

- 需要做 unique、diff、intersection
- 需要比较两组文件、两批数据或两份输出
- 需要做分布统计、Pareto 分析或热点排序
- 需要在日志、错误类型、键集合中找 top contributors
- 需要保持结构化文本的主体格式，同时剔除部分条目
- 需要分析代码依赖频率、namespace 耦合、共享库热点
- 需要评估模块拆分的依赖重叠面
- **需要对任意命令输出（stdin 管道）做去重、频率分布、Pareto 分析或差集/交集**

常见问题场景：
- "log 里最多的异常类型是什么？top 5 占总量多少？"
- "两个版本的 API 导出列表有什么差异？"
- "hosts 文件需要删除一批条目，但要保留注释和格式"
- "哪些共享库被最多项目依赖？"
- "git log 中有多少个唯一 PR 号？频率分布是什么？"
- "build 输出中不同 error code 的分布是什么？"

## Goal

把文本差异和统计分析统一收敛为可解释流程：

1. 明确比较对象
2. 选择 key 提取策略
3. 选择 diff / intersection / distribution 模式
4. 控制输出规模
5. 输出可行动结论

## Core Principles

### 1. Compare by key, not always by whole line

许多分析的核心不是原始整行，而是：

- 第一列 key
- 某个 capture group
- 某种标识符
- 某种异常名或实体名

### 2. Distribution over reading line by line

在日志或大量记录中，不要只看几个样例，应优先找：

- top keys
- frequency distribution
- cumulative contribution
- long tail

### 3. Output must support action decisions

分析结果必须支持下一步决策，例如：

- 哪些 key 是新增的
- 哪些配置被删除了
- 哪类异常占比最高
- top N 是否已覆盖大部分问题

### 4. Preserve structure only when needed

如果目标是编辑 hosts、inventory、config 这类结构化文本，应优先使用保结构方式，而不是纯 key 列表输出。

## Default Workflow

### Step 1. Define the comparison target

先判断你要的是哪一种：

- difference
- intersection
- unique
- distribution
- cumulative / Pareto
- structure-preserving filter

### Step 2. Define the comparison key

先确认比较依据：

- whole line
- regex capture group
- plain text token
- 某一列字段
- 某种 exception / id / host / dependency name

### Step 3. Choose output form

根据任务决定输出形式：

- 只看 key
- 输出 whole line
- 保留 not-captured lines
- 输出 percentage
- 输出 cumulative totals
- 输出 top N only

### Step 4. Bound the analysis

默认不要一次输出完整长尾分布。

**`-K` 与 `-H N` 配合使用**（不是代替）：
```text
# BEST: -K 数据驱动裁剪 + -H 硬上限保底（防止输出过多）
nin nul "(.+)" -pd --sum -K 3.0 -H 30 -C

# OK: 固定 Top 20（没有数据驱动裁剪）
nin nul "(.+)" -pd --sum -H 20 -C

# ⚠️ 危险: -K 单独使用没有 -H → 如果很多项 ≥5%，会输出大量行
# nin nul "(.+)" -pd --sum -K 5.0 -C  ← 缺少 -H 保底
```

⚠️ **`-H N` 每条命令必须有**（token 安全保底）。`-K` 是可选的增强（数据驱动裁剪）。

### Step 5. Translate into action

分析结束后应得到明确行动方向，例如：

- 删除哪些项
- 保留哪些 allowlist 项
- 哪几个异常优先排查
- 哪些差异需要回到源码或配置层面处理

## Preferred Analysis Modes

### Case A. Unique and dedup

适用：

- 去重
- 唯一 key 列表
- 观察输入是否包含重复项

结论形式：

- unique count
- top duplicates
- 是否需要去重处理

### Case B. Difference and intersection

适用：

- 新旧导出文件比较
- allowlist / blocklist 校验
- expected vs actual 验证
- 依赖、主机、配置项差异检查

结论形式：

- in A not in B
- in both
- missing expected keys
- unexpected new keys

### Case C. Distribution and Pareto

适用：

- 错误类型统计
- 用户、主机、路径、依赖、异常分布
- top contributors 分析

结论形式：

- top N keys
- cumulative coverage
- significance threshold
- long tail 是否值得关心

### Case D. Structure-preserving filtering

适用：

- hosts
- inventory
- ini-like config
- 注释和格式必须保留的结构化文件

结论形式：

- 删除哪些 entry
- 保留哪些 entry
- 注释和结构保持不变

### Case E. Time-sorted log merge and triage

适用：

- 多个日志文件按时间合并排序
- 时间窗口内的事件筛选
- 含 continuation lines 的 stack trace 提取（auto-fill）

顺序：

1. 用 `-F` 指定时间 regex，合并排序多文件日志
2. 可选用 `-B`/`-E` 限定时间窗口
3. 将排序后的输出 pipe 到 nin 做分布分析
4. 根据 top keys 回到源日志做 drill-down

结论形式：

- 时间窗口内的异常分布
- top error types 和 cumulative coverage
- 需要溯源的时间点和模式

### Case F. Dependency and coupling analysis

适用：

- 项目依赖频率分布（哪些共享库被引用最多）
- Namespace 耦合面分析（模块依赖哪些外部 namespace，按比例排序）
- 跨模块依赖重叠（两个模块的依赖交集/差集）
- 仓库拆分范围评估

顺序：

1. 用 msr `-t` + `-o` 从 .csproj/源码中提取依赖名或 namespace
2. pipe 到 nin 做频率分布（`-pd --sum`）
3. 读取 cumPct% 判断 Top-N 覆盖度
4. 对两个模块的依赖列表做 `nin file1 file2 -m`（交集）和 `nin file1 file2`（差集）
5. 根据分布和重叠决定包化/模块化优先级或仓库拆分边界

结论形式：

- Top N 共享库及其引用频率
- 模块间依赖重叠度
- 耦合面百分比（如 "X% 的 import 来自某个顶层 namespace"）

### Case G. Numeric statistics

适用：

- 延迟、响应时间、资源用量等数值型数据
- 需要 percentile（P50/P90/P99）、median、average 等统计

顺序：

1. 用 msr `-t` 捕获数值，`-s ""` 继承捕获用于排序
2. 加 `-n`（msr 的 `--sort-as-number`，与 nin 的 `-n`/`--out-not-captured` 完全不同）启用数值统计模式
3. 在 summary 中读取 P05-P99.999 及 median、average 等

结论形式：

- percentile distribution
- outlier 识别
- 性能基线比较

## Guardrails

### Do not blindly compare by whole line

如果真正比较的是字段或 key，就不要只按整行比较。

### Do not output full long tail by default

长尾分布默认只在需要时展开。

### Do not confuse analysis with action

先做事实分析，再给行动建议，不要在结果不明确时直接执行修改。

### Do not unintentionally break file structure

如果输入是结构化文本并且后续还要写回文件，必须考虑 whole line 或 structure-preserving 模式。

### Do not use nin for structured data parsing

nin 是行级文本集合工具，不适合完整结构化数据解析（JSON 层级查询、CSV 跨列逻辑、SQL 风格 JOIN/GROUP BY）。数值聚合用 msr 的 `-s "" -n`。但对不完整片段、含注释的 JSON、或专用解析器无法处理的格式，msr/nin 的行级文本处理反而更可靠。

### Pipe processing: use nin, not shell native

**在生成管道集合操作命令（`cmd | ...`）前，对照以下检查表**：

| 即将用 | → 改用 |
|--------|--------|
| `Sort-Object -Unique` / `sort -u` | `\| nin nul "(regex)" -u` |
| `Group-Object` / `sort \| uniq -c` | `\| nin nul "(regex)" -pd` |
| `Compare-Object` / `comm` / `diff` | `nin file1 file2 "(regex)"` |

文本过滤（行过滤/行计数/head/tail）→ 见 [`smart-search` Pipe processing](../smart-search/SKILL.md#pipe-processing-use-msr-not-shell-native)

### Common mistakes checklist

本 skill 重点防止这些错误：

- 把 frequency / Pareto 问题退化为人工翻日志
- 把需要按 key 比较的问题误做成整行比较
- 一上来输出完整长尾，导致 Agent 难以提炼结论
- 在还没明确 comparison key 前，就开始做 diff 或 distribution
- 做完统计后不给出下一步行动方向
- **对管道输出做去重/频率分布/Pareto 分析时**，优先用 `nin` stdin 模式（一步完成去重+分布+百分比+Pareto，且跨平台一致），而非多段 shell 原生管道。仅需简单计数时 shell 原生语法亦可
- **nin 的 positional regex 忘记加 capture group `(...)`**——导致 nin 报错退出（`No Regex capture1 in pattern`），而非按 key 去重/分布（如 `nin nul "regex"` 应写为 `nin nul "(regex)"`）

### nin stdin mode = universal pipe analyzer

nin 的 stdin 模式与文件模式行为完全一致（`cmd | nin nul "(regex)" -pd`）。常见管道模式：

```text
msr -rp src/ -f "\.cs$" -t "using (\S+);.*?$" -o "\1" -PIC | nin nul "([^;]+)" -pd --sum -H 10   # 搜索→分布
git log --format="%ai %s" | msr -t "PR (\d{7}).*?$" -o "\1" -PIC | nin nul "(\d+)" -pd -C         # 提取→去重
dotnet build 2>&1 | msr -t "(CS\d{4}).*?$" -o "\1" -PIC | nin nul "(\w+)" -pd --sum -C            # error 分布
```

## Fallbacks

### Fallback 1. Unclear key extraction

处理方式：

- 先用样本验证 regex capture
- 若 capture 不稳定，退回 whole line
- 若需要多列判断，优先 whole line 模式再加过滤

### Fallback 2. Distribution too long

处理方式：

- top N
- percentage threshold
- cumulative threshold
- split by category

### Fallback 3. Difference set too noisy

处理方式：

- 先做 unique
- 再比较
- 加 ignore-case
- 重新定义 comparison key

### Fallback 4. Analysis needs source context

处理方式：

- 把 top keys 重新送回 [`smart-search`](../smart-search/SKILL.md) skill
- 从分布结果回到源码、配置或日志上下文
- 形成 search → analyze → drill-down 的闭环

## Output Rules

- msr/nin 的 summary（`Matched N lines ...` / `Got N lines ...`）是命令的最后一行输出——看到 summary 即表示命令已完成，无需等待更多输出
- 结果应优先回答"最重要的几个是什么"
- 若输出 distribution，应优先 top N 或 cumulative summary
- 若输出 diff，应明确是 A not in B 还是 intersection
- 若输出保结构过滤，应说明哪些内容被保留、哪些被剔除
- 输出不要只是数据堆砌，要带结论方向

## Good Outcomes

本 skill 的理想结果是：

- 快速找到最重要的差异或热点
- 可以直接支撑后续排查或变更
- 输出规模可控
- key 提取规则清晰且可复用

## Workflow Integration

集合分析的常见协作：
- 搜索结果作为输入 → 常见上游是 [`smart-search`](../smart-search/SKILL.md) 的 pipe 输出
- top keys 需要回到源码查看上下文 → 切换到 [`smart-search`](../smart-search/SKILL.md)
- 分析结果确认需要批量修改 → 切换到 [`safe-replace`](../safe-replace/SKILL.md)

## Local Notes

本 skill 为自包含版本。

如需补充 key 提取、输出形式和常用模式，请查看：

- [`references.md`](./references.md)