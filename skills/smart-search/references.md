# Smart Search References

**默认路径**：常规仓库搜索先直接尝试 `gfind-*`，不预先探测工具是否就绪。只有命令缺失或工具明显异常时，再使用本文后面的 troubleshooting 部分。

## Why msr / gfind-* over rg, grep, and IDE search_files

- 单二进制、无依赖，支持 Windows/Linux/macOS/FreeBSD/Cygwin/MinGW/WSL
- `gfind-xxx`/`find-xxx` 路径限定搜索（`-d`/`--sp`/`--xp`/`-k`）比 rg 快 `8~22×`——在文件遍历阶段即跳过无关路径
- `-t` + `-x` + `--nt` + `--nx` 一条命令完成 regex+文本+排除的 AND 组合过滤（rg 排除需管道 `rg | grep -v`）
- `-U`/`-D` 直接获取匹配上下文，`-H N` 限量输出 + summary 报告完整统计，Agent 一步到位无需追加命令
- 快速退出（`-H 1 -J`）比 rg 快 `13×`（Windows），比 grep 快 `3~10×`（macOS）
- rg 不支持就地替换文件（`--replace` 仅输出到 stdout，永远不修改文件）；msr/gfind-xxx/find-xxx 同一工具族可以完成搜索、就地替换（`-R`）、提取、context、时间排序，并与后续 safe replacement / set mining 保持同一套 scope 语义
- 返回值 = 匹配计数（rg 只有 0/1）；Windows 上可直接保留完整计数，非 Windows 平台的大数需要额外处理
- 内置 BOM 自动检测（8 种编码）；`-I`（`--no-extra`）同时抑制 BOM WARN 行（BOM 统计信息仍在 summary 中保留），效果类似 `--not-warn-bom` 但更轻量
- nin 补充集合操作（diff/intersection/distribution/Pareto），与 msr 管道协作

## Supplementary Details

### Return value — cross-platform truncation

- Windows: 完整 32-bit 退出码，可直接用于计数
- Linux/macOS/Cygwin: 8-bit（max 255），256 wraps to 0
- MinGW: 7-bit（max 127）
- 对阈值检查用 `--exit gt255-to-255`；对精确大数计数，解析 summary（stderr）

### `-i` case-sensitivity pitfall

`-x "webhost"` 不加 `-i` → **0 匹配**；加 `-i` → **91 lines / 40 files**。非代码来源搜索时遗漏 `-i` 会导致完全漏搜。

### Supplementary scope rules

- 路径 include 往往比 exclude 更有效
- `gfind-*` 自动缓存 git-tracked 文件列表，仅 commit 变化时刷新
- sibling repos 用 `rgfind-*`
- `--nf` / `--pp` 可作为**安全无冲突**的额外过滤；但默认优先级仍低于 `-d` / `--sp` / `--xp`

- `-def` 慢或不稳定时回退到 `-ref` + `-x` 文本过滤，或直接使用 explicit regex

## Command Templates — Scope Control

### File-list scope (git diff / cached list)

```text
git diff --name-only HEAD~1 > $env:TEMP\scope.txt
msr -w $env:TEMP\scope.txt -t "pattern" --no-check
```

### Time filtering with gfind-* (incremental review)

```text
gfind-file -I -f "\.cs$" -t "\basync void\b" --xp "test,/deprecated" --w1 7d -H 10   # 最近 7 天修改的文件
gfind-file -I -f "\.cs$" -t "TODO" --w1 2h -H 20                                  # 最近 2 小时改动中的 TODO
```

`--w1`/`--w2` 在 gfind-* 工具中同样有效。适合 PR 增量审查或"刚才的修改引入了什么问题？"。

### -ref with disambiguation

```text
gfind-file -I -f "\.py$" -t "MyClass" -x "class" -H 10
gfind-file -I -f "\.cs$" -t "MyService" -x "interface" -d "Services" -H 10
```

## Command Templates — Size and Time Filtering

`--s1`/`--s2` 控制文件大小范围，`--w1`/`--w2` 控制修改时间范围：

```text
# 非 git 目录(logs/、cache/ 等);git repo 内改用 gfind-file -I -f "\.log$" 并配 --s1/--w1
msr -rp logs/ -f "\.log$" -l --s1 1MB --s2 100MB    # 1~100MB files
msr -rp logs/ -f "\.log$" -l --w1 2h                # modified in last 2 hours
msr -rp logs/ -f "\.log$" -l --w1 2024-01-15 --w2 2024-01-16
```

大小格式：`300`=bytes、`1KB`、`2.5MB`（单位不区分大小写、支持小数）

时间格式：`2024-01-15`、`"2024-01-15 10:30:00"`、`3h`、`30m`、`7d`（相对时间）、文件路径（使用该文件的 mtime）

⚠️ 纯数字无单位（如 `30`）不合法，必须加单位：`30m`、`1h`、`1d`。

## Command Templates — Path Filtering

### --sp (AND, plain text include) / --xp (OR, plain text exclude)

```text
gfind-file -I -f "\.md$" -t "\bTrigger\b" --sp skills/ -H 10
gfind-file -I -f "\.java$" -t "\bService\b" --sp "src/" -H 10
gfind-small -t "deprecated" --xp "test,mock,deprecate" -H 20
```

- `--sp`：路径必须包含**所有**文本（AND）
- `--xp`：路径包含**任一**文本即排除（OR）
- ⚠️ `--xp` 不是 `-xp`（单横线会被解析为 `-x p`）

### --pp / --np (regex include/exclude)

```text
gfind-file -I -f "\.cs$" --pp "src/.*Controllers/" -t "\bGetUser\b" -H 10
msr -rp logs/ -f "\.log$" --np "backup|archive" -t "error" -H 20    # logs/ 非 git 追踪 → msr -rp
```

⚠️ `find-*` 工具通常已占用 `--np` 或 `--nd`，不要重复指定。推荐用 `-d`/`--sp`/`--xp`。

### --sp + --pp combined (AND include + regex OR include)

`--sp` 和 `--pp` 可同时使用——路径必须同时满足两者：

```text
# 路径必须含 "Services"（AND）且匹配 Orchestration/ 或 Monitoring/（OR）
gfind-small --% -f "\.csproj$" -x "WebHost" --sp "Services" --pp "Orchestration/|Monitoring/" -H 10
```

### --xp + --pp combined (OR exclude + regex OR include)

```text
# regex OR include + 纯文本 OR exclude
gfind-small --% -f "\.csproj$" -x "WebHost" --pp "Services/Orchestration|Services/Monitoring" --xp "test,/deprecated" -H 10
```

### --nd directory name exclude (safe with most gfind-*)

`--nd` 按目录名 regex 排除。与 `--nf`（文件名排除）的区别：

- `--nd "test"` 排除目录名含 test 的**整个子树**（包括其下所有文件）
- `--nf "Test"` 仅排除文件名含 Test 的文件（不影响目录遍历）

```text
gfind-small -x "WebHost" --nd "test" --sp "Services" -f "\.csproj$" -H 10
```

⚠️ 部分 `find-*` 工具已占用 `--nd`（如 `find-ndp`），使用前用 `find-alias` 检查。`gfind-small`/`gfind-file` 可安全添加。

### -d (directory include) / -k (max depth)

`-d` 与 `-k` 字面相近,语义完全不同——`-d` 是**子目录名 regex**,`-k` 是**最大递归深度(整数)**:

```text
# ✅ -d 是 dir-name regex
gfind-file -I -f "\.java$" -d "^src$" -t "\bService\b" -H 10
gfind-file -I -f "\.cs$" -d "Controllers" -t "GetUser" -H 10

# ✅ -k 是 max depth(整数)
gfind-file -I -f "\.cs$" -t "\bLogger\b" -k 3 -H 20

# ❌ -d 3 会被当成 regex "3"(匹配目录名含字符 "3" 的子树),不是深度
#   想限制深度用 -k 3
```

### `-k` efficient workflow: read MaxMatchedDepth from summary

首次搜索不加 `-k`，从 summary 中读取 `MaxMatchedDepth`；后续同 scope 搜索直接加 `-k = MaxMatchedDepth`，可减少无效文件遍历：

```text
# 首次搜索：读 summary 中 "MaxMatchedDepth = 7"
gfind-small --% -f "\.csproj$" -t "TargetFrameworks" --pp "Services/Common|Services/Core" -H 1 -T 1
# → summary: MaxMatchedDepth = 7（首行验证 pattern，尾行确认 scope 边界）

# 后续同 scope 搜索加 -k 7（结果相同但更快）
gfind-small --% -f "\.csproj$" -t "TargetFrameworks" --pp "Services/Common|Services/Core" -k 7 -H 1 -T 1
# → 相同结果，遍历更少文件，实测可快 2~3×
```

⚠️ `-k < MaxMatchedDepth` 会漏文件——只能用 `>=` MaxMatchedDepth 的值。`-k` 的主要收益在 `MaxMatchedDepth` 显著小于 `MaxOpenedDepth` 的广域搜索场景。

## Command Templates — Content Filtering

### Multi-dimension AND filtering (single command)

一条命令可叠加 7 维 AND 过滤：路径 include (`-d`/`--sp`/`--pp`) + 路径 exclude (`--xp`/`--np`/`--nf`) + 文件属性 (`-f`/`-k`/`--s1`/`--s2`/`--w1`/`--w2`) + 内容 include (`-t`/`-x`) + 内容 exclude (`--nt`/`--nx`) + Block scope (`-b`/`-Q`)。

```text
gfind-file -I -f "\.cs$" -t "public.*?async.*?Task" -x "CancellationToken" --nt "\boverride\b" --nx "Obsolete" --sp "Services" --xp "test,/deprecated" -k 5
```

### `-e` has no value for AI agents

`-e` 仅添加颜色高亮。Agent 不用 `-e`——用 `-t`/`-x`/`--nt`/`--nx` 代替。

## Command Templates — Output Control

### File distribution (built-in aliases)

```text
gfind-top-type -H 9                # Top file types
gfind-top-type -K 2.0              # Auto threshold: >= 2% share
gfind-top-type --sum               # Cumulative coverage (cumPct%)
gfind-top-folder -H 10             # Top folders
```

### File listing

```text
gfind-file -I -f "\.py$" -t "import pandas" -l              # files with match count
msr -rp logs/ -f "\.log$" -l --sz --s1 10MB     # by size (非 git 目录)
msr -rp logs/ -f "\.log$" -l --wt --w1 2h       # by time (非 git 目录)
```

### Git diff common aliases

```text
gdm-l       # List all changed files vs main/master
gdm-ml      # Modified files only
gdm-nt      # Diff excluding test files
```

## Guardrails & Gotchas

### Each parameter can only be used once (no duplicates)

- msr/nin 的**所有参数**（短标志和长选项）在同一命令行中**只能出现一次**，重复会报错 `cannot be specified more than once`
- 此限制同样适用于 `gfind-*` / `find-*` 等 msr 包装工具——它们已内置部分参数
- `-t`（regex match）、`-x`（plain text match）、`--nt`（regex exclude）、`--nx`（text exclude）这 4 个可**同时使用**（AND 组合过滤），但各自只能出现一次
- 典型错误：对大多数 `gfind-*` 用 `-PIC`（含 `-I`）→ 改用 `-PC`；对 `find-py` 加 `-f` → 已内置，不可再加
- `-PIC` 决策规则见 [SKILL.md `-PIC` and `-A` rules](./SKILL.md#-pic-and--a-rules)

### `-P` hides path and line number

- 只有明确不需要导航信息时才使用

### Short flags differ between msr and nin

| Flag | msr | nin |
|------|-----|-----|
| `-P` | `--no-path-line` | `--no-percent` |
| `-I` | `--no-extra` | `--info-normal-out` |
| `-w` | `--read-paths` | `--out-whole-line` |
| `-a` | `--out-all` | `--ascending` |
| `-n` | `--sort-as-number` | `--out-not-captured` |
| `-m` | `--show-count` | `--intersection` |

### Short flags are case-sensitive

msr/nin 的**所有短标志均大小写敏感**——大写和小写含义完全不同，不可互推。

典型易混淆：nin 的 `-a`（`--ascending`）vs `-A`（`--no-any-info`，抑制所有 summary）。

不确定某个 flag 含义时：
- 查看完整帮助：`msr -h -C` 或 `nin -h -C`（nin ~89 行、msr ~230 行）
- 查特定 flag 加管道过滤更精确且节省 token：`nin -h -C | msr -t "\s+-A\b"`

### msr short flags ≠ grep/rg semantics

来自 grep/rg 直觉常错。下表给出 msr 真实含义和误用后果——按 msr 含义使用,不要套 grep 经验:

| flag | msr 含义 | grep/rg 同字母含义 | 误用后果 |
|------|---------|------------------|---------|
| `-A` | `--no-any-info`(抑制所有 summary) | after-context N | summary 被静默吞掉,agent 失去决策依据 |
| `-B` | `--time-begin`(需配 `-F`) | before-context N | exit -1 / 报错 |
| `-C` | `--no-color`(给 agent/管道**必加**) | context N | 不加 → ANSI 色码泄漏到 stdout,污染下游 regex |
| `-E` | `--time-end`(需配 `-F`) | extended-regex | exit -1 |
| `-F` | `--time-format` regex | fixed-string | regex 被当时间格式 |
| `-H` | `--head N`(输出条数上限) | with-filename | 限错条数 |
| `-L` | `--list-aliases` | files-without-match | 列 alias 而非文件 |
| `-N` | `--start-line` | line-number | 起始行偏移而非显示行号 |
| `-o` | `--output`(**替换字符串**) | only-matching | **整行被覆盖**;替换回填用 `\1` 不是 `$1` |
| `-v` | `--verbose` | invert-match | 反义 |
| `-w` | msr=`--read-paths` / nin=`--out-whole-line` | word-regexp | 完全不同 |
| `-x` | **纯文本**(opposite of regex) | line-regexp | regex 被当 literal,0 命中 |
| `-z` | `--string`(无文件输入) | null-data terminator | 输入语义错 |

最致命 3 个:`-C`(色码 ≠ context)、`-o`(替换文件 ≠ only-matching)、`-x`(纯文本 ≠ 行匹配)。上下文用 `-U N -D N`,词边界用 `\b`,大小写不敏感用 `-i`。

### Non-ASCII arguments: msr limitation when ACP lacks target characters

msr/nin 使用 ANSI 入口（C `main()`），命令行参数经 Windows ACP（系统 ANSI codepage）转换。若 ACP 无法表示参数中的字符（如英文系统搜中文、日文系统搜韩文等），参数被截断为 `?`，导致 0 匹配或 regex 语法错误。用 `-c` 可确认 msr 实际收到的参数。

**不受影响的环境**：系统 ACP 已覆盖目标字符的 Windows（如中文系统搜中文）、Linux/macOS/Cygwin（全程 UTF-8）、已启用 "Beta: Use Unicode UTF-8" 的 Windows（ACP=65001）。

**rg / grep 不受此限制**——它们使用 Unicode API（`GetCommandLineW`）直接获取完整命令行。

**Agent 搜索时的处理方案**：用 rg/grep 做非 ASCII 匹配，管道给 msr 做后续处理（msr 管道内容不受影响）：
```text
rg -n '中文关键词' file.txt | msr -t '(\d+:.*)' -H 5 -IC
```

**永久修复**（需用户/管理员操作，Agent 无法自行执行）：
1. **`mt.exe` 嵌入 UTF-8 manifest**（仅影响 msr/nin.exe）：`mt.exe -manifest utf8-manifest.xml -outputresource:"msr.exe;#1"`，manifest 声明 `<activeCodePage>UTF-8</activeCodePage>`
2. **系统级启用 UTF-8 Beta**：Settings → Time & Language → Administrative language settings → Change system locale → ✅ Beta: Use Unicode UTF-8

Agent 注意：管道**内容**不受影响（stdin 按字节流传递）；仅**命令行参数**（`-t`/`-x` 等）中的非 ASCII 字符在特定 Windows 环境下受限。若非 ASCII 搜索意外返回 0 匹配，加 `-c` 检查实际收到的参数。

### Pipe character in `.cmd` script arguments on Windows shell

`gfind-*` / `find-*` 在 Windows 上是 `.cmd` 脚本文件。
当 AI agent 在 Windows shell 中调用这类工具时，命令行里任意参数中的 `|` 都可能被 shell 解释为管道，而不是普通参数内容。

**但这不意味着 AI agent 应默认放弃单命令搜索。**

先按需求判断：

#### When single-command alternation is better

```text
gfind-file -I -f "\.cs$" -t "A|B|C" --sp "src" --xp "test,/deprecated" -l -H 20
```

适合：

- 想一次拿到“任一匹配”的文件列表
- 想只扫描一次 scope
- 想看统一 summary，而不是每个模式各一份 summary
- 想先快速知道候选范围，再决定是否拆开深入

#### When multiple single-pattern commands are better

```text
gfind-file -I -f "\.cs$" -t "A" --sp "src" --xp "test,/deprecated" -l -H 20
gfind-file -I -f "\.cs$" -t "B" --sp "src" --xp "test,/deprecated" -l -H 20
# ... 每个模式各一条
```

适合：

- 需要分别比较 A / B / C 的文件分布
- 需要分别计算耦合比例
- 需要给不同模式附加不同内容过滤（`-x`/`--nt`/`--nx`）或路径过滤（`--sp`/`--xp`/`-d`/`--nf`/`-k` 等）

#### shell-specific solutions

若需求明确更适合单命令 alternation，优先按已知 shell 环境选择方案：

```text
# Windows PowerShell + .cmd 脚本: 使用 --% stop-parsing token（必须紧跟工具名）
gfind-small --% -t "v10|v9|v8|legacy|deprecated" -i -f "\.(yml|yaml|Dockerfile|xml|json)$" --pp "build/pipelines|/ci/|\.pipelines|src/Services" --xp "test,/cache/,/vendor/" -H 20
gfind-file --% -I -f "\.(cs|cshtml|razor)$" -t "ILogger|ILoggerFactory" --nt "^\s*//" --sp "src/Services" --xp "test,/generated" -H 20
gfind-file --% -I -f "\.(ts|tsx)$" -t "ClassA" --nt "getX|getY" -H 10

# ❌ 错误：--% 不在 alias 名之后，| 在 --% 之前会被 shell 误解为管道且导致命令行 'B' is not recognized 错误
# gfind-file -I -f "\.(ts|tsx)$" -t "A|B" --% -H 10

# 需要外层包裹时
cmd /c "gfind-file -I -f ""\.(ts|tsx)$"" -t ""pattern|other"" -H 10"
```

⚠️ **仅 PowerShell + `.cmd` 脚本** 时需要 `--%`。cmd.exe / bash 不需要。

## Return Value Semantics

| 场景 | 返回值 |
|------|--------|
| 正常搜索/替换 | 匹配/替换的行数（>0 = 有匹配，不是错误） |
| 无匹配 | 0 |
| 错误（如无效 regex） | -1（shell 截断为 255 或 127） |
| `-X` 模式（无 `-V`） | 返回非零的命令数 |
| `-X -V ne0` | 匹配停止条件的命令数 |

## Error Recovery

Agent 遇到异常输出时，按错误现象查找原因和修复方法：

| 错误现象 | 可能原因 | 修复方法 |
|---------|---------|---------|
| `cannot be specified more than once` | 工具已内置某参数（如 `-I`），命令行又加了 | 用 `find-alias gfind-xxx -Output name+body` 检查工具参数；大多数 `gfind-*` 改用 `-PC` 而非 `-PIC` |
| summary 显示 `read 0 files` | scope 太窄 / `-f` pattern 不匹配 / 工具配置异常 | 放宽 `--sp`/`--xp`，检查 `-f` pattern 是否正确 |
| `-o "\1"` 输出含行尾残余文本 | `-t` pattern 未消费整行 | `-t` pattern 末尾加 `.*?$`（如 `-t "(target).*?$" -o "\1"`） |
| nin 报 `No Regex capture1 in pattern` | positional regex 缺少 capture group `(...)` | 改 `"regex"` 为 `"(regex)"` |
| `gfind-*` 命令不存在 | vscode-msr 未安装或工具文件未生成 | 见下方 Troubleshooting |
| 返回值 255 或 127（非 Windows） | 匹配数超出平台 exit code 位宽 | 用 `--exit gt255-to-255` 或解析 summary stderr |
| 搜索目标存在但 0 匹配 | 非代码来源的搜索词大小写不匹配 | 加 `-i`（仅影响内容参数，不影响路径参数） |
| `-x`/`-t` 含非 ASCII 字符返回 0 匹配 | 非 CJK Windows 上 ACP 无法表示该字符 | 加 `-c` 确认参数是否截断为 `?`；见上方 Non-ASCII arguments 章节 |
| 参数中 `\|` 被 shell 误解为管道 | PowerShell 调用 `.cmd` 脚本时 `\|` 未处理 | 加 `--%`（`.cmd` 脚本专用）或用 `cmd /c "..."` |
| `msr --version` 返回 exit code 255，误判为不存在 | msr 与 nin 只支持 `-h` | 用 `msr -h` 检测存在性 |

## Troubleshooting tool availability

Use this section only when `gfind-file` / `gfind-small` are also missing, or tool behavior is clearly abnormal:

- no error or only a file path is printed = tool is ready
- `'gfind-file' is not recognized`（Windows）/ `command not found`（Linux/macOS）= vscode-msr is not installed → `code --install-extension qualiu.vscode-msr`
- `Not found alias file: ...{repo}.msr-cmd-alias.cmd`（Windows）或 `...bashrc`（Linux/macOS）= the extension is installed but the repository has not generated tool files yet → `code <repo-folder>` and wait about 10 seconds
- Knowledge base: https://marketplace.visualstudio.com/items?itemName=qualiu.vscode-msr

## Environment Variables

msr/nin 共享 7 个 `MSR_*` 环境变量（仅建议在脚本中临时设置，不建议全局配置）：

| 变量 | 等效参数 | 用途 |
|------|---------|------|
| `MSR_NO_COLOR` | `-C` | CI 环境去除 ANSI 颜色码 |
| `MSR_EXIT` | `--exit` | 跨平台退出码控制（如 `gt255-to-255`） |
| `MSR_NOT_WARN_BOM` | `--not-warn-bom` | 批量处理时抑制 BOM 警告 |
| `MSR_SKIP_LAST_EMPTY` | `-Z` | 跳过文件末尾空行 |
| `MSR_KEEP_COLOR` | `--keep-color` | 管道中保留颜色（Windows） |
| `MSR_UNIX_SLASH` | `--unix-slash` | Windows 上输出 `/` 路径 |
| `MSR_COLORS` | `--colors` | 自定义颜色方案 |
