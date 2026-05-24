# Set Mining References

本文件保存 [`SKILL.md`](./SKILL.md) 的关键模式与补充细节。

**工具 troubleshooting**：只有在默认 `gfind-*` 路径缺失或明显异常时，才去看 [`smart-search/references.md`](../smart-search/references.md)。

## Core Capabilities

| 能力 | 典型场景 |
|------|---------|
| Difference | expected vs actual, allowlist/blocklist, new vs old exports |
| Intersection | dependency overlap, host commonality |
| Unique/Dedup | dedup before comparison or distribution |
| Distribution/Pareto | top exception types, host hotspots, long-tail analysis |
| Structure-preserving filter | remove entries while keeping comments and formatting |

## Key Semantics

> 以下 `-w`、`-n` 等标志均为 **nin** 语义。msr 的 `-w` 含义完全不同（`--read-paths`）。

### Regex capture group is the comparison key

- 有 regex 时 group 1 是 comparison key；无 regex 时 whole line 为 key
- 提供 positional regex 时必须有 group 1：`(...)`；否则 nin 会报错
- nin 直接提取 group 1 作为 key，**不需要** `.*?$` 消费行尾（与 msr `-o "\1"` 不同）
- 避免在 capture group **前面**使用 greedy `.*`：`".*(\w+)"` 只捕获最后一个词字符（greedy 吞过头）；改用 `^` 锚定、字面前缀或 lazy `.*?`

### Filter target vs output mode

- **正常模式（无 `-n`）**：`-t`/`-x`/`--nt`/`--nx` 过滤 whole line（原始行）
- `-w` 仅影响输出形式：无 `-w` 输出 captured key，有 `-w` 输出 whole line
- `-n`（`--out-not-captured`）：保留 not-captured lines 并原样输出
- `-w -n`：structure-preserving pass-through（matched + unmatched 均整行输出）
- 需要结构保留删除时，优先用双文件 `-wn`（配合 exclude file）

### Sorting affects early-exit

- 启用排序需 full read，top N 与 early exit 语义要区分

## Command Templates

> **跨平台提示**: `nul` 和 `/dev/null` 在 nin 中等价，均可在任意平台使用（nin 内部自动归一化）。

除非明确标注 shell 类型，否则下面的示例默认按 shell-neutral 理解。

### Difference / Intersection / Unique

```text
nin file1 file2 "^(\S+)"              # difference: keys in file1 NOT in file2
nin file1 file2 "^(\S+)" -m           # intersection: keys in BOTH files
nin file nul "^(\S+)" -u              # unique keys (dedup)
```

### Distribution / Pareto

```text
nin file nul "^(\S+)" -pd             # frequency distribution (descending)
nin file nul "^(\S+)" -pd --sum -K 5.0   # Pareto with 5% threshold
nin file nul "^(\S+)" -pa --sum        # ascending (long-tail analysis)
```

`--sum` 输出格式：`count-cumCount(pct%-cumPct%): key` — 读取 cumPct% 判断覆盖度。

```text
15-15(42.9%-42.9%): NullReferenceException
5-20(14.3%-57.1%): TimeoutException
```

读法：count 15 次，占 42.9%，累计 42.9%；前 2 类累计覆盖 57.1%。

### Structure-preserving filter

```text
nin hosts-full.txt remove-list.txt "^(\S+)" "^(\S+)" -wn -PC > hosts-updated.txt
```

- `-wn`：matched lines 整行输出 + not-captured lines 保留
- 单文件模式下 `-wn` 更像 pass-through；真正的结构保留删除通常需要双文件
- 不要把 `-wn` 误当成“删除所有被 `--nt`/`--nx` 排除的行”；`-n` 会保留 not-captured lines
- `-PC`：无百分比、无颜色（summary 走 stderr 不影响文件内容，Agent 仍可在终端看到）

### Count threshold (-k) / Percent threshold (-K)

```text
nin error.log nul "^(\w+Exception)" -pd --sum -k 3     # count >= 3 only
nin error.log nul "^(\w+Exception)" -pd --sum -K 5.0   # share >= 5% only
```

- `-k` 按绝对数量过滤（count < N 时停止），`-K` 按当前项自身百分比过滤（当前项 own% < P% 时停止，非累计百分比）

### Swap file roles (-S)

```text
nin hosts.txt remove-list.txt "^(\S+)" -S    # keys in remove-list NOT in hosts (find invalid removals)
nin hosts.txt remove-list.txt "^(\S+)" -mw   # dry-run: what WOULD be removed (intersection)
```

- `-S` 交换 file1 和 file2 的角色（及各自 regex）

## Pipeline Patterns

### Search → distribution

```text
msr -rp logs/ -f "\.log$" -t "(\w+Exception)" -PIC | nin nul "(\w+Exception)" -pd --sum -H 20
```

### Dependency frequency Pareto (architecture hotspot analysis)

从 .csproj 提取所有 ProjectReference → 去重 → 频率分布 → Top-N with cumulative%：

```text
# 两步提取：第一步 -o "\1" 未消费整行，输出含 XML 残留（如 "    <SharedLib />"）；第二步清理为纯项目名
msr -rp src/ -f "\.csproj$" -t "ProjectReference Include=""[^""]*\\([^""\\]+)\.csproj""" -o "\1" -PIC | msr -t "^\s*<(.+?)\s*/>" -o "\1" -PIC | nin nul "(.+)" -pd --sum -H 15 -C

# 简化写法：第一步 regex 加 .*?$ 消费整行，单步即可提取纯项目名
msr -rp src/ -f "\.csproj$" -t "ProjectReference Include=""[^""]*\\([^""\\]+)\.csproj"".*?$" -o "\1" -PIC | nin nul "(.+)" -pd --sum -H 15 -C
```

### Namespace coupling Pareto (module split analysis)

从源码 using/import 声明提取 namespace → 按顶层 namespace 分组 → 分布：

```text
# C# 示例
gfind-file -I -f "\.cs$" -t "^using (TargetNamespace\.\S+).*?$" -o "\1" --sp "src/TargetModule/" -PC -H 100 | nin nul "^(TargetNamespace\.[^;.]+)" -pd --sum -H 20 -C

# Python 示例
gfind-file -I -f "\.py$" -t "^from (\w+)\..*?$" -o "\1" --sp "src/target_module/" -PC -H 100 | nin nul "(\w+)" -pd --sum -H 20 -C
```

### Cross-service dependency surface assessment

找出多少项目依赖某个共享库：

```text
gfind-file -I -f "\.csproj$" -x "TargetSharedLibrary" -l -PIC | msr -t ".*?\\([^\\]+)\\[^\\]+\.csproj$" -o "\1" -PIC | nin nul "(.+)" -pd -C
```

### Search → difference (multi-step)

1. 用搜索工具先抽取 key（如 function names、host names）
2. 保存到临时文件后做 unique / diff / intersection；必要时再回到搜索看上下文

```text
# PowerShell example
gfind-file -I -f "\.py$" -t "def (\w+).*?$" -o "\1" -PC -H 200 > $env:TEMP\funcs-new.txt
nin $env:TEMP\funcs-new.txt $env:TEMP\funcs-old.txt "^(\S+)"    # new functions not in old
```

### Time-sorted → distribution

```text
msr -rp logs/ -f "\.log$" -F "\d{4}-\d{2}-\d{2}\D\d+:\d+:\d+[\.,]?\d*" | nin nul "(\w+Exception)\b" -pd --sum -K 5.0
```

### Time window drill-down

```text
msr -rp logs/ -f "\.log$" -F "(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})" -B "2024-01-15 10:00:00" -E "2024-01-15 10:30:00"
```

- `-F` 指定时间 regex 用于排序和 auto-fill（continuation lines 继承前一行时间）
- `-B`/`-E` 使用**文本（字典序）比较**，非日期解析——因此也可用于非时间 key（如版本号）
- 无 `-B`/`-E` 时仅排序不过滤

非时间示例：

```text
msr -p versions.txt -F "(v\d+\.\d+\.\d+)" -B "v1.5.0" -E "v2.0.0"
```

### Numeric statistics (msr, not nin)

```text
msr -p latency.log -t "cost:\s*(\d+)" -s "" -n -H 0 -C
# Summary: Count, Sum, Median, Average, P50, P90, P95, P99, P99.9, P99.99, P99.999

msr -p latency.log -t "cost:\s*(\d+)" -s "" -n --dsc -H 5 -C
# Top 5 highest values + full statistics
```

- `-s ""` 继承 `-t` 的 capture group 作为排序 key
- `-n`（msr 的 `--sort-as-number`，非 nin 的 `-n`）启用数值统计；`-H 0` 仅看 summary

## Advanced Patterns

### Summary output to stdout (nin's -I)

```text
# Default: summary → stderr (not captured by >)
nin error.log nul "(\w+Exception)" -pd -H 30 > report.txt

# With -I: summary → stdout (captured by >)
nin error.log nul "(\w+Exception)" -pd -H 30 -I > report.txt
```

### Silent counting (for scripts)

```text
nin error.log nul "^(\w+Exception)" -pd -H 0 2>nul
# exit code = unique key count; use in conditionals

# PowerShell example:
# nin error.log nul "^(\w+Exception)" -pd -H 0 2>$null
# if ($LASTEXITCODE -gt 10) { "Too many error types!" }
```

- On Windows, the exit code remains full 32-bit.
- On Linux/macOS/Cygwin/MinGW, large counts may truncate; parse summary when exact large values matter.

### Filter distribution output

```text
# Exclude debug/trace from distribution
nin error.log nul "^(\w+)" -pd --nt "debug|trace" -H 20

# Filter by plain text
nin access.log nul "HTTP/\d\.\d\"\s+(\d+)" -pd -x "4" -H 10
# Shows status codes containing "4" (400, 401, 403, 404, etc.)
```

## Short Flag Differences: msr vs nin

详细对照表见 [`smart-search/references.md`](../smart-search/references.md) 的"Short flags differ between msr and nin"章节。

关键提醒：本 skill 中 `-w`（`--out-whole-line`）、`-n`（`--out-not-captured`）、`-m`（`--intersection`）、`-a`（`--ascending`）均为 **nin** 语义，与 msr 含义完全不同。

⚠️ nin 的 `-A`（大写，`--no-any-info`）会抑制**所有** summary/warning 输出，与 `-a`（小写，`--ascending`）含义完全不同。Agent 不要用 `-A`——summary 走 stderr 不影响 stdout 重定向，Agent 始终需要 summary 做决策。不确定 flag 含义时用 `nin -h -C` 查验。