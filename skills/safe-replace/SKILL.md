# Safe Replace

> **msr**: 搜索和替换在同一工具中完成，不加 `-R` 即预览、加 `-R` 即写入、加 `-RK` 即备份。支持 block-scoped 局部替换（INI/XML/config）、多轮替换（`-g -1`）、batch 执行（`-X`），未变化文件自动跳过写入。对 AI Agent 意味着：无需切换工具，修改前必经预览，可验证可回滚。

> **何时优先于 IDE search-and-replace / sed / Agent apply_diff：**
> - **预览→写入→验证 一条工具链**：搜索命令去掉 `-R` 即预览、加 `-R` 即写入，无需切换工具
> - **block-scoped 替换**：`-b "^\[section\]" -Q "^$"` 只在特定 INI/XML block 内替换（IDE 和 sed 做不到或很复杂）
> - **批量执行**：搜索结果直接 `-X` 执行命令（如批量 rename、compile、test）
> - **自动备份**：`-RK` 写入同时创建 mtime 基准的 backup，碰撞自动追加后缀

> **Quick Win** — 三步完成全仓库 rename（预览→写入→验证）：
> ```
> gfind-file -I -f "\.cs$" -t "\bOldName\b" -o "NewName" -j -H 5   # -j = 仅显示替换后有变化的行
> gfind-file -I -f "\.cs$" -t "\bOldName\b" -o "NewName" -RK       # 写入 + 备份
> gfind-file -I -f "\.cs$" -t "\bOldName\b" -H 1 -J                # 验证残留为零
> ```

## AI Agent Default Decision Card

当任务已经从“定位问题”进入“准备改文件”阶段时，默认按这个顺序：

1. 先确认 scope
2. 再预览精确的文本变换
3. 在风险可接受时带备份写入
4. 最后验证 residual hits

默认不要：

- 第一次命中就直接写文件
- 跳过 preview
- 把 block-scoped 修改降级成 line-scoped replace
- 在 PowerShell 调用 `.cmd` 脚本时忘记处理 `|`；详细写法留在 [`references.md`](./references.md)

## Trigger

在以下场景触发本 skill：

- 已经定位到候选文件，准备执行修改
- 需要批量 rename、replace 或局部结构化替换
- 需要先做 preview，再决定是否 apply
- 需要控制编码、BOM、line ending、backup 风险
- 需要在修改后验证 residual hits

## Core Principles

- 不要第一次命中就直接写入
- 先 preview，再 apply
- 写入后一定验证 residual hits

## Default Workflow

### Step 1. Scope verification

先确认影响面。scope 确认流程参见 [`smart-search`](../smart-search/SKILL.md)。

检查要点：

- 哪些文件会被改
- 哪些目录会被改
- 是否命中非目标模块
- 是否存在大小写变体、旧别名、相近名称
- 是否需要局部 block replacement

推荐先做：

- file list
- small sample
- changed-lines preview

### Step 2. Preview the exact transformation

在 apply 前，先确认“会改成什么”。

关注：

- 替换结果是否符合预期
- capture group 是否正确
- 是否出现误替换
- 是否有"行级改动但语义不匹配"的情况

### Step 3. Apply with safety

只有在以下条件满足时 apply：

- scope 已确认
- preview 已确认
- 编码和文件格式风险可接受
- backup 策略明确
- residual check 方案明确

### Step 4. Residual verification

apply 后检查：

- 旧模式是否仍残留
- 是否只剩下有意保留的命中
- 是否引入了新的误命中
- 是否影响到预期外文件

## Guardrails

### Do not skip preview before writing

禁止跳过 preview 直接写入，除非用户明确要求且风险很低。

### Do not treat block content as plain line replacement

遇到以下情况优先考虑 block-scoped 操作：

- INI section
- XML / YAML / JSON 片段
- server block
- config fragment
- multi-line template region

### Do not ignore encoding risks

特别注意：

- BOM 文件
- UTF-16 / UTF-32 文件
- 强制转换编码的 replace
- Windows 与 Unix 行尾差异
- **非 ASCII pattern / replacement + `msr -R` 不可用**：argv 经 ANSI 编码 → 字节损坏 → 写入乱码。非 ASCII 替换必须用其它 Edit 工具

### Do not assume all matches should be replaced uniformly

同一个字符串在不同上下文里，可能不该统一替换。

### Common mistakes checklist

本 skill 重点防止这些错误：

- 因为"只是改个名字"就跳过 preview
- 因为命中很多就一次全仓库直接写入
- 以为 replace 结果"看起来对"就不再验证残留
- 忽略 BOM、编码、line ending 风险
- 把适合 block-scoped 的修改错误地下放成普通 regex replace
- **用 `-o "\1"` 提取/替换时，`-t` pattern 忘记以 `.*?$` 结尾匹配整行**——导致行尾内容残留（正确：`-t "(target).*?$" -o "\1"`，错误：`-t "(target)" -o "\1"`）
- **大规模批量修改（多文件或不确定 scope）时跳过 preview 直接写入**——应优先用 msr 的预览→写入→验证一条龙（有内置 backup 和 residual check）。少量已知位置的精确修改可用 IDE `apply_diff` 等工具

## Preferred Modification Strategy

### Case A. Simple rename in code

顺序：

1. 确认命中文件范围
2. 预览 changed lines
3. 执行 replace
4. 检查 residual references

### Case B. Config surgery

顺序：

1. 先锁定 block
2. 再在 block 内匹配与替换
3. 预览 scoped result
4. apply with backup
5. 重新检查 block 结果

### Case C. Large repo multi-file replace

顺序：

1. 先验证 scope 是否足够窄
2. 只看少量预览
3. 必要时分批次 apply
4. 每批次后残留检查
5. 避免一次无边界替换整个仓库

### Case D. Encoding-sensitive replace

顺序：

1. 先确认文件编码类型
2. 确认工具行为是否会转换编码
3. 明确 backup 方案
4. 用户接受后再 apply

### Case E. Multi-round replacement

适用：

- 锚定模式（`^` 开头）导致单次 pass 无法替换所有匹配
- 压缩连续字符（多空格→单空格、多逗号→单逗号）
- 逐层剥离嵌套结构（括号、标签）

顺序：

1. 先用默认模式测试（不加 `-g -1`）
2. 若仍有残留匹配，加 `-g -1` 启用无限轮替换
3. preview 确认结果稳定
4. apply

### Case F. Batch execution from search results

适用：

- 将搜索到的文件列表转化为可执行命令
- 批量 rename、delete、compile、test
- 需要 fail-fast 或 error-only 输出

⚠️ **安全前提**（满足全部条件才使用 `-X`）：
- 输入来自**可控来源**（`gfind-*` / `msr -l` 输出，不是用户提供的任意文本）
- 命令模板已通过**不加 `-X` 的预览**确认正确
- 不对**不可信文本内容**直接拼接为可执行命令

顺序：

1. 先搜索并确认文件列表
2. 使用 `-t "(.+)" -o "<cmd> \"\1\""` 构造命令
3. 先不加 `-X`，预览将要执行的命令
4. 加 `-XMO`（显示命令 + 仅显示错误）执行
5. 若需要 fail-fast，用 `-XM -V ne0`

## Safety Checklist

在真正 apply 前，至少满足以下清单：

- 目标范围已确认
- 预览结果已确认
- 不会误改非目标目录
- 若有 BOM / 编码风险，已知其后果
- 若有 line ending 风险，已接受其后果
- 已设计 residual verification

## Fallbacks

### Fallback 1. Preview too noisy

处理方式：

- 继续收窄 scope
- 使用 block-scoped strategy
- 分批处理
- 先改单目录，再扩展

### Fallback 2. Ambiguous replacement

处理方式：

- 改用 explicit regex
- 增加上下文约束
- 把单次大替换拆成多个小替换

### Fallback 3. High encoding risk

处理方式：

- 优先只读确认
- 明确 backup
- 避免自动批量 apply
- 在可接受时才使用强制 replace

### Fallback 4. Residual matches after replacement

处理方式：

1. 区分剩余命中是否合理
2. 检查是否漏了 scope
3. 检查是否存在不同拼写或不同上下文
4. 再决定第二轮 replace，而不是盲目重复执行

## Good Outcomes

本 skill 的理想结果是：

- 改动前已明确影响面，无 "改了才知道改了什么" 的情况
- Preview → Apply → Verify 每步都有可追溯记录
- 若有编码/line ending 转换，已在 apply 前明确告知
- Residual check 证实旧模式已彻底清除（或已明确标注保留项）
- Backup 文件可用于快速回滚

## Workflow Integration

替换前后的常见协作：
- 替换前定位目标文件 → 先用 [`smart-search`](../smart-search/SKILL.md) 确认 scope
- 替换前分析影响面分布 → 用 [`set-mining`](../set-mining/SKILL.md) 做频率统计
- 替换后验证残留 → 回到 [`smart-search`](../smart-search/SKILL.md) 做 residual check

## Output Rules

- preview 阶段优先输出 changed lines，而不是全文件内容
- apply 阶段应明确说明 scope 和 safety assumption
- verify 阶段应明确区分 residual hit 与 expected remaining hit
- 风险项必须显式指出，不应隐藏在长输出里

## References

- [`references.md`](./references.md)