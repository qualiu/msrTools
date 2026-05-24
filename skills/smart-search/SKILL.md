# Smart Search

> **msr + gfind-* 工具** 优势:
> - 大型 repo (24K文件) Agent 搜索实测：msr/gfind-* 比 rg 快 2.8 倍、省 token 3.2 倍、少搜索 5.4 倍，有效搜索率为 rg 的 4.5 倍.
> - msr/gfind-xxx 搜索大型代码库用路径过滤比 rg 快 8-22倍（虽然 rg 是最快搜索工具，比 grep 快 5-40倍、比 ag 快 2-5倍、比 ack 快 10-100倍）.
> - 单命令同时完成路径+内容+排除过滤并附带完整统计（--nt/--nx/-x+-t+--sp+--xp），rg 需管道接力但丢失统计.
> - 单用msr代码库搜索性能接近 rg（80%~90%），单个大文件(GB)搜索 msr 为 rg 性能的 30%~90%.
> - Agent 用更少命令获取更精确的结果。详见 [`references.md`](./references.md)

## AI Agent Fast Path (read this first, then search)

### Default action sequence

做仓库级搜索时，默认按这个顺序：

1. **if** 数据源是管道输出（`cmd | ...`）而非文件 → 用 `| msr`（不用 shell 原生），详见 [Pipe processing](#pipe-processing-use-msr-not-shell-native)；集合操作见 [`set-mining`](../set-mining/SKILL.md#pipe-processing-use-nin-not-shell-native)
2. 按 Step 0 选择 `gfind-*` 工具（如 `gfind-file -I -f` 或 `gfind-small`）
3. 只有必须包含 untracked files 时才改用 `find-file -f` 或 `find-small`
4. 生成命令前先做 1 次 shell preflight：若当前是 **Windows 上的 PowerShell / pwsh**，且调用的是 `.cmd` 脚本（`gfind-*` / `find-*`），并且任一参数包含 `|`，先改成 `工具名 --% ...`（**cmd.exe / Git bash (MinGW) / Linux-macOS 的 pwsh 不需要 `--%`**；Git bash 加 `--%` 会被传给 msr.exe 并报错）
5. **第一次搜索先看是否已提供 File type depth mapping**：
   - **已有 depth mapping** → `-k` 值已知，跳过 `gfind-top-type`。仍须发现 **source root**：用 `gfind-top-folder -H 10 -C`。发现后**立即锁定 `--sp "<that_root>"`**
   - **无 depth mapping** → 先 `gfind-top-type -H 30 --sum -C`（干净的类型+计数，**不加 `-w`**），再 `gfind-top-folder -H 10 -C`（source root）。**各只运行一次，不重复**
   - **两种情况都适用**：`--sp` 锁定后，后续所有搜索必须包含。不加 `--sp` 的后续搜索是退步
6. 用 `--xp`、`-d`、`-k` 进一步缩小路径范围
7. 先用 `-l -H N` 看命中文件分布，再用 `-H N`（不加 `-l`）看内容样本
8. 噪音大时先补 `-x`、`--nt`、`--nx`，不要先扩 scope
9. 只有出现明确 fallback 触发条件时，才回退到 IDE `search_files`

补充规则：
- 默认直接试 `gfind-*`；不要预先探测工具是否就绪
- 需要发现更多工具或查看工具细节时，用 `find-alias`
- 路径参数的安全性和推荐顺序见 [path filtering table](#path-filtering-parameters-in-recommended-order)
- 切记：**仅 Windows PowerShell / pwsh** + **`.cmd` 脚本** + **参数含 `|`** → 紧跟工具名写 `--%`（在所有其他参数之前；cmd.exe / Git bash (MinGW) / Linux-macOS pwsh 不需要 `--%`）

### Pre-command checklist (MANDATORY for every search)

生成**每条**搜索命令前,先核对以下 **6 项最小要求**:

1. **工具**: `gfind-file -I -f` / `gfind-small` / `find-ndp` / `msr -p`
2. **Depth** (`-k`): 来自 prompt 的 depth mapping 信息(如 `.cs → -k 13`、`.csproj → -k 9`)或上一轮 summary 的 `MaxMatchedDepth`。**已知 depth 时必须加 `-k`**
3. **Timeout** (`--timeout`): 必填。定向搜索用 `30`,广域搜索用 `60`
4. **Path filter**(必填——至少 2 项):
  - **`--xp "test,deprecate"` 在搜代码内容时必填**(`.cs`/`.py`/`.ts` 等)——排除测试目录,避免污染模式/风格分析。**仅**升级分析中扫项目文件(`.csproj`/`.sln`)时可省略,因为测试项目也是升级对象
  - **探测后 `--sp` 必填**:首次搜索发现 source root(如 `src/`、`sources/`、`services/`)后,**所有**后续搜索都必须带 `--sp` 锁定该 root。已知后省略 `--sp` 是退步
5. **Content filter**(至少 1 个 include + 1 个 exclude):
   - `-x` 用于纯文本,`-t` 用于 regex
   - 搜 `.cs`/`.java`/`.ts`/`.js` 时**必加** `--nt "^\s*//"` 排除注释;搜 `.py`/`.sh` 用 `--nt "^\s*#"`。**主动加**,不要等噪音出现
6. **Output bound** (`-H`): 必填。`-H 1 -T 1` 用于验证(首尾各 1 行 + summary),`-H 20 -T 1` 用于探索
7. **不要用 `&&`/`||` 串联**: msr/nin/gfind 返回匹配数(不是 0/1 布尔)——`&&` 和 `||` 语义错误。用 `|` 管道或分开执行

**Minimum valid command templates**:
```text
# Code content search (with --nt to exclude comments)
gfind-file -I -f "\.cs$" -t "pattern" --xp "test,deprecate" --nt "^\s*//" -k 13 -H 20 -T 1 --timeout 30

# After recon reveals source root: add --sp
gfind-file -I -f "\.cs$" -t "pattern" --sp "src" --xp "test,deprecate" --nt "^\s*//" -k 13 -H 20 -T 1 --timeout 30

# Project/config file search (no --nt needed)
gfind-file -I -f "\.csproj$" -x "keyword" -k 9 -H 20 -T 1 --timeout 30
```

⚠️ **每条命令至少 5 个过滤参数**：`-f` + 内容过滤 + `--xp` + `-k` + `-H`。缺少任何一个都是不充分的搜索。

⚠️ **每个参数只能出现一次**：msr/nin/gfind-*/find-* 的所有参数在同一命令行中不能重复，否则报错 `cannot be specified more than once`。这适用于所有参数类别——内容过滤（`-t`/`-x`/`--nt`/`--nx`）、路径过滤（`--sp`/`--xp`/`--pp`/`-d`/`--nf`）、输出控制（`-H`/`-T`）等。需要多条件组合时，用不同参数名实现 AND 过滤（如 `-x "keyword" -t "\bpattern\b" --sp "path" --xp "exclude"`），不要重复同一参数。多个排除模式用 alternation 合并：`--nt "^\s*($|#|//)"` 而非 `--nt "^\s*#" --nt "^\s*$"`。

### Content filter type selection

| 场景 | 用什么 | 不用什么 |
|------|--------|---------|
| **单个**固定文字 | `-x "ExactText"` | 不用 `-t`（无需转义） |
| **多个候选值**需要 OR 匹配 | `-t "A|B|C"` | **不用** `-x`（`-x` 不支持 alternation `|`）。⚠️ `|` **不要转义**为 `\|`——`\|` 是字面管道符，不是 alternation |
| 需要边界/锚点 | `-t "\bWord\b"` | — |
| 排除**单个**固定文字 | `--nx "noise"` | 不用 `--nt`（无需转义） |
| 排除**多个**候选模式 | `--nt "pattern1\|pattern2"` | **不用** `--nx`（不支持 `|`） |
| 排除注释/生成代码 | `--nt "^\s*//"` | — |
| 大小写不确定 | 加 `-i` | 不要强行猜大小写 |

⚠️ **最常见的违规**：对固定文字使用 `-t "FixedWord"` 而本应使用 `-x "FixedWord"`。生成命令前自检："这个 pattern 需要 `\b`、`^`、`$`、`|` 或字符类吗？" 如果不需要 → 用 `-x`。

⚠️ **主动排噪**：搜索代码内容时，注释和声明行属于可预见的噪音，不必等到结果有噪音再加排除：
- 搜索 `.cs`/`.java`/`.ts`/`.js` 内容时，加 `--nt "^\s*//"` 排除注释
- 搜索 `.py`/`.sh` 内容时，加 `--nt "^\s*#"` 排除注释
- 如果搜索目标不是 import/using 声明，加 `--nt "^\s*(using|import)\s"` 排除声明行
- 同时用 `-x` + `-t` 可更精确：`-x "ClassName" -t "\bnew\b"` 比单用 `-t "new ClassName"` 噪音更少且无需转义

```text
# CORRECT: 纯文本用 -x（无需转义，. 等特殊字符按字面匹配）
-x "appsettings.json"      # 不用 -t "appsettings\.json"

# CORRECT: 需要 regex 特性时用 -t
-t "error|warn|fatal"      # alternation
-t "\bHttpClient\b"        # 词边界
-t "^using\s+"             # 锚点
```

⚠️ **`-x`/`--nx` 不支持 `|`（alternation）**。多个候选值用 `-t` 合并为 1 条命令：
```text
# BAD: 每个候选值各一条命令 → N 轮 tool call
gfind-file ... -x "net6.0" -H 5

# GOOD: 1 条合并搜索
gfind-file ... -t "net6\.0|net7\.0" -H 5
```

### Max 2 retries then switch strategy

如果搜索返回 `exit_code=0`（无匹配）或 `exit_code=-1`（错误；非 Windows 上被 OS 截取为 255（8-bit）或 127（MinGW 7-bit）），按以下**强制规则**切换：

⚠️ **compound regex（含 `|`）返回 0 后，下一条搜索必须只用单个 `-x` 关键词（不含 `|`）**。不要用另一个 compound regex 重试——这是最常见的浪费模式。

1. **简化搜索词**（第一优先）：从问题中提取**单个**关键词，逐一 `-x` 搜索加 `-i`。例如问题含"fetch session logs"→ 依次试 `-x "session" -i`, `-x "log" -i`, `-x "redis" -i`
2. **放宽范围**：去掉 `--sp`/`--xp`/`-f` 限制，或改用 `gfind-small`
3. **加 `-c` 诊断**：若怀疑命令语法问题，加 `-c` 显示实际收到的命令行
4. **read_file 兜底**：仅当简化搜索仍无结果时，才用 `list_directory` + `read_file`

⚠️ 连续 2+ 次 compound regex（含 `|`）返回 0 是**严格禁止**的——必须立即切换为单关键词 `-x` 搜索。

### Verified path extraction template (use this, don't reinvent)

从 `-l` 文件列表中提取目录层级名称的**验证过的标准模板**：

```text
# 从文件列表提取 Services 下的子模块名：
gfind-file -I -f "\.csproj$" --sp "path/to/dir" --xp "test,deprecate" -k 9 -t "keyword" -l -PC --timeout 30 | msr -t "^.*Services[/\\]([A-Za-z]+)[/\\].*?$" -o "\1" -PIC | nin nul "(.+)" -pd --sum -H 25 -C
```

关键点：
- 必须用 **`-l -PC`**（文件列表模式 + 去路径前缀和颜色）
- msr 提取 regex 用 **`[/\\]`** 匹配路径分隔符（兼容 Windows `\` 和 Unix `/`）
- 不要用 `-PC`（无 `-l`）的内容搜索模式做路径提取——内容行格式是 `file:line:col: content`，与文件路径格式不同

### Common parameter errors in pipes (must avoid)

⚠️ **msr 和 nin 的 `-k` 含义完全不同**：msr `-k` = max directory depth，nin `-k` = min count threshold。
**路径提取时 `-o "\1"` 需要 `^.*` 前缀 + `.*?$` 后缀消费整行**。
详细的 4 类错误/修复示例见 [`references.md`](./references.md#common-parameter-errors-in-pipes)。

### Parameter selection quick card

生成搜索命令前，先按这个决策选择参数：

**Step 0: 工具选择**（在选参数之前先选工具，只用 3 个核心入口）：

| 场景 | 用什么 | 示例 |
|------|--------|------|
| 知道文件扩展名 | `gfind-file -I -f "\.(ext)$"` | `gfind-file -I -f "\.(cs|cshtml)$" -t "pattern"` |
| 配置文件 | `gfind-file -I -f "\.(json|yaml|xml|ini|props)$"` | 不用 `gfind-config`（它内置 `-f` 会冲突） |
| 项目文件 | `gfind-file -I -f "\.(csproj|sln)$"` | 不用 `gfind-proj`（同理） |
| 不确定文件类型 | `gfind-small` | `gfind-small -t "pattern" -H 20` |
| 限定目录 | `find-ndp <dir>` | `find-ndp src/Services -t "pattern" -H 10` |
| 已知少量文件 | `msr -p "file1,file2" -t "PATTERN" -IC -H 20` | `msr -p "a.csproj,b.csproj" -t "pattern" -IC -H 20` |
| 单文件 + 行号去路径 | `msr -p <file> -t "PATTERN" -IC -H 20 \| msr -t "^..[^:]+:(\d+:.*)" -o "\1" -PIC` | 第一段 `-IC` 保留路径供第二段提取；`-o "\1"` 中 `\1` 不能写 `$1`（PS/bash 会展开为空） |
| 非 git 目录多文件 | `msr -rp <non-git-path> -f "\.ext$" -t "PATTERN" -H 20 -T 1 -C` | `-rp` 默认遍历全部文件类型，**MUST 加 `-f`**；git repo 内改用 `gfind-*` |

⚠️ **不要使用 `gfind-config` / `gfind-proj` / `gfind-code`** 等 bundle 工具——它们内置了 `-f` 参数，如果 Agent 再加 `-f` 会报 `cannot be specified more than once` 错误。`gfind-file -I -f "\.ext$"` 是统一入口，无参数冲突。

**管道输出必须加 `-C`**（去掉 ANSI 颜色码）：
```text
# 管道到 msr/nin 时，上游必须加 -C（或 -PC / -PIC）
gfind-file -I -f "\.csproj$" -x "PackageReference" -PC --timeout 30 | msr -t "regex" -o "\1" -PIC | nin nul "(.+)" -pd -C
# 注意: -PIC 已包含 -C（P+I+C），-PC 已包含 -C（P+C），不要再加额外的 -C
```

⚠️ **初始搜索必须加 `-H N`** 控制输出（summary 仍报告完整统计）。推荐值：

| 目的 | `-H` 值 | 说明 |
|------|---------|------|
| 存在性检查 | `-H 1 -J` | 找到即停，**不读全部文件**。比 `-H 1` 快 10-30×（大仓库 ~1s vs ~13s） |
| 仅看统计/计数 | `-H 1 -T 1` | 首尾各 1 行 + summary 完整计数。尾行帮助判断分布范围（如是否含 test 目录） |
| **常规首次搜索** | **`-H 20 -T 1`** | 首 20 行 + 尾 1 行。覆盖 5-10 个文件样本 + 尾部分布边界 |
| 广泛影响评估 | `-H 30 -T 1` | 大仓库多文件场景，尾行显示最后匹配位置 |

⚠️ **区分"存在性检查"和"计数统计"**：
- **只需要知道"有没有"** → 用 **`-H 1 -J`**（首次匹配即停退出，不读全部文件，大仓库快 10-30×）
- **需要知道"有多少"** → 用 **`-H 1 -T 1`**（读全部文件，summary 报告总匹配数和文件数，尾行显示匹配边界）
- **禁止 `-H 0`**：`-H 1` 与 `-H 0` 速度相同但多 1 行验证

⚠️ **推荐 `-H N -T 1`**：`-T 1` 额外显示最后一条匹配（仅多 1 行 token），让 Agent 看到匹配的路径范围。例如 `-H 1 -T 1` 显示首尾 2 条，Agent 可判断是否需要加 `--xp "test"` 或 `--sp`。

⚠️ **特别是管道提取（`-o "\1"`）场景**：必须先 `-H 1` 验证提取结果是否干净（无行尾残留），验证通过后去掉 `-H` 做全量提取。跳过验证直接全量提取是 token 浪费的第一大来源。

需要查看匹配行上下文时加 `-U N`（上方 N 行）`-D N`（下方 N 行），如 `-U 2 -D 5`。多文件场景远优于 `read_file`（仅输出匹配附近行，无需读取整个文件）。

有任何已知信息就立即用路径和内容过滤参数——参数越多，噪音越少，速度越快。

> 📝 后续示例统一使用批准入口（如 `gfind-file -I -f` / `gfind-small` / `find-ndp`），避免专用 `gfind-{ext}` 工具对 Agent 形成错误示范。


#### Path filtering parameters in recommended order

Combinable, order-independent on command line, all case-insensitive（可叠加,命令行参数顺序无关,全部大小写不敏感;`--xp "test"` 同时排除 `test/`、`Test/`、`TEST/`——不需要写 `"test,Test"`）:

| Scenario | Parameter | Scope | Safe | Notes |
|----------|-----------|-------|------|-------|
| Narrow to subtree | `--sp "src/Module"` | Full path (AND) | ✅ | 纯文本、快;最常用的首选 |
| Include multiple paths | `--pp "src/Controllers/\|src/Services/"` | Full path (regex OR) | ✅ | 不要用 `--sp "A,B"`——AND 要求两者都含,几乎不命中 |
| Narrow to dir name | `-d "^Controllers$"` | Dir name only | ✅ | **Dir-name regex(不是深度)**;`-d 3` 会被当 regex "3";深度限制用 `-k N` |
| Exclude paths | `--xp "test,/deprecated"` | Full path (OR) | ✅ | `/` 前缀更精确:`"/deprecated"` 不会误命中 `Undeprecated/` |
| Exclude filename | `--nf "Test"` | Filename | ✅ | 可安全加到任何 `gfind-*` |
| Limit depth | `-k N` | Depth | ✅ | 从上一轮搜索读到 `MaxMatchedDepth` 后使用 |
| File type include | `-f "\.cs$"` | Filename | ⚠️ | **仅匹配 filename(单段)**;`-f` 值含 `/` 或 `\` 不会工作,全路径正则用 `--pp`;通常已内置,优先 `gfind-file -I -f` |
| Exclude dir name | `--nd "^(test)$"` | Dir name | ⚠️ | regex;若参数冲突,报错清晰——直接移除 |
| Exclude path (regex) | `--np "pattern"` | Full path | ⚠️ | 若参数冲突,报错清晰——直接移除 |

- ✅ **Safe** = 可加到任何 `gfind-*`/`find-*` 而不冲突
- ⚠️ **May conflict** = 工具可能已设此参数——重复时 msr 报错清晰(`cannot be specified more than once`),直接移除

⚠️ **`--xp` 短词危险**：`--xp "obj"` 匹配路径中**任意位置**的 "obj" 子串（如 `ObjectFactory/`、`ObjectModel/`），不仅仅是 `/obj/` 目录。`gfind-*` 已自动排除 gitignored `/obj/`、`/bin/`，**不要**在 `--xp` 中重复。正确默认值：`--xp "test,deprecate"`。

**关键原则**：先叠加更多参数缩小范围（AND 组合），而不是写一个宽泛的命令再人工翻结果。

### Required preflight

PowerShell + `.cmd` 脚本 + 参数含 `|` → 紧跟工具名加 `--%`。**cmd.exe 和 Git bash (MinGW) 都不需要 `--%`**（Git bash 加 `--%` 会被 msr.exe 视为非法参数而报错 `unrecognised option`）。
⚠️ **`--%` 仅用于 PowerShell 调用 `.cmd` 脚本（`gfind-*`/`find-*`）**，不要在 `msr`/`nin`（.exe 文件）上加 `--%`——即使是在管道中。cmd.exe / Git bash 任何命令都不需要 `--%`。Git bash 中含 `|` / `(` / `)` 的复杂命令用 `cmd <<< '{full command line}'`，简单命令用 `cmd //c "{cmd}"`。
详见 [`references.md`](./references.md#pipe-character-in-cmd-alias-arguments-on-windows-shell)。

### Default starter command template

当仓库、语言和大致模块路径都已知时，先做一个有边界的 file-list probe：

```text
gfind-file -I -f "\.cs$" -x "SymbolName" --sp "src/TargetModule/" --xp "test,/deprecated" -l -H 20
```

- `gfind-file -I` 限制在 git-tracked scope，`-f` 指定文件类型
- `-x` 纯文本匹配（固定词不需要 regex）
- `--sp` 和 `--xp` 在内容匹配前移除无关文件
- `-l -H 20` 先给出可导航的小样本
- 噪音大时继续叠加 `--nt`/`--nx`/`-d`/`-k` 等——见下方 refinement patterns

### Single-file search: always append strip-path suffix

单文件搜索**强烈推荐**在 `msr -p file ... -IC` 后追加固定后缀去掉冗余路径、保留行号：

```text
msr -p "src/Handler.cs" -t "async Task" -U 2 -D 20 -H 3 -IC | msr -t "^..[^:]+:(\d+:.*?)$" -o "\1" -PIC
```

- 输出 `149: async def execute_tool(` 而非 `src\Handler.cs:149: async def execute_tool(`——省 token、留行号
- 后缀 `| msr -t "^..[^:]+:(\d+:.*)" -o "\1" -PIC` 是**固定命令，不要修改**——兼容所有 `-U/-D/-H/-T` 组合，不改变行数
- 读整个文件：`msr -p file -PIC`（无 `-t` 则输出全部行）。不用 `read_file`——`msr` 一步完成且附带 summary

### XML / structured value extraction

提取 XML/csproj 属性值时，直接用管道一步完成提取+分布：

```text
gfind-file -I -f "\.csproj$" -t "^.*<TargetFrameworks?>([^<]+)<.*?$" -o "\1" -PC --timeout 30 | nin nul "([^\s;]+)" -pd --sum -H 20 -C
```

若 0 匹配或输出异常 → 用 `-x "keyword" -H 3` 看原始行格式后调整 regex。
`-o "\1"` 必须用 `^.*` + `.*?$` 消费整行，否则行首/尾残留。

⚠️ **管道提取 vs 逐值查询 vs alternation 的优先级**：

- **需要分布统计** → **优先 ONE pipeline**（1 条命令替代 N 条逐值查询，节省 N× 时间和 token）：
```text
gfind-file -I -f "\.csproj$" -x "TargetFramework" -PC -k 9 --timeout 30 | msr -t "^.*<TargetFrameworks?>([^<]+)<.*?$" -o "\1" -PIC | nin nul "([^\s;]+)" -pd --sum -H 20 -C
```
⚠️ **管道分布不要加 `-K` 阈值**——`-K 2.0` 会过滤掉大部分低频值导致误判为 regex 错误。先用 `-H N` 看完整分布，确认后再加 `-K` 精简。
- **仅需存在性检查** → 用 ONE alternation（1 条命令检查所有候选值）：
```text
gfind-file -I -f "\.csproj$" -t "net10\.0|net9\.0|net8\.0|net48|netstandard|netcoreapp" --sp "src" -k 9 -H 20 -T 1 --timeout 30
```
- **逐值查询** → 仅在管道提取失败 2 次后作为 fallback
- **候选值未知** → 先 `-H 3` 看原始行 → 尝试管道提取 → 失败 2 次切 alternation 或逐值

**完整示例——PackageReference 包名提取**（经验证的命令）：
```text
# 方法 1（推荐）：用 -t 过滤 + msr 用 "" 转义引号
gfind-file -I -f "\.csproj$" -t "PackageReference Include" --xp "test,deprecate" -k 9 -PC --timeout 30 | msr -t "PackageReference Include=""([^""]+)"".*?$" -o "\1" -PIC | nin nul "(.+)" -pd --sum -H 30 -C

# 方法 2：用 -x 过滤 + msr 用 \x22 代替引号（仅在方法 1 失败时尝试）
gfind-file -I -f "\.csproj$" -x "PackageReference" --xp "test,deprecate" -k 9 -PC --timeout 30 | msr -t "Include=.([^\s\x22]+)..*?$" -o "\1" -PIC | nin nul "(.+)" -pd -H 60 -C
```

⚠️ **已验证会失败的写法（不要用）**：
- `msr -t "Include=.([^\s\"]+)."` — `\"` 在 cmd.exe 管道中不可靠 → exit_code=-1
- `msr -t "PackageReference\s+Include\s*=\s*..."` — `\s` 在管道中有时被误解
- 多个 `2>nul` 在管道各段 → 干扰 stderr 传递
- **`&&` / `||` 链接 msr/nin/gfind 命令** → 语义错误！msr/nin 返回值 = 匹配行数（非 0/1 布尔值），534 匹配返回 534，`&&` 认为"成功"但 `||` 认为"失败"。不要用 `&&`/`||` 链接，改用 `|` 管道或分开执行
- **`2>nul` / `2>/dev/null` 重定向 stderr** → 丢失 summary 信息！msr/nin/gfind 的 summary（`Matched N lines in M files`）走 stderr，是 Agent 的核心决策信号。在管道中 summary **不会**污染管道数据（stderr 和 stdout 分离），无需 `2>nul`。如需抑制 summary，用 `-M` 参数
- **NEVER 在管道中用 `2>&1`** → 它把 summary（stderr）混入管道数据流，污染下游 msr/nin 的正则匹配

### High-frequency refinement patterns

结果有噪音时，先补内容过滤，再考虑扩大范围：

```text
gfind-file -I -f "\.cs$" -t "\bTargetExceptionName\b" --sp "src/TargetArea/" --xp "test,/deprecated" -x "throw new" --nt "^\s*//" --nx "///" -H 20
```

### Fallback triggers

只有在触发条件明确时，才切换离开默认路径：

- 工具缺失或明显异常 → 使用 [`references.md`](./references.md) 中的 troubleshooting 路径
- 必须包含 untracked files → 改用 `find-file -f` 或 `find-small`
- 路径范围仍然过大 → 继续收紧 `--sp`、`--xp`、`-d`、`-k`
- 输出噪音仍大 → 继续补 `-x`、`--nt`、`--nx`，而不是先扩范围
- 结果太少 → **先简化搜索词**（拆 compound regex、用问题中不同单独关键词、加 `-i`）→ 再放宽 path scope → file type → 最后 broad scan。不要在搜索可行时跳到 `list_directory` + `read_file`

### Return value notes

正数返回值应视为匹配计数，而不是失败。跨平台细节留在 [`references.md`](./references.md)。

## Guardrails

### Large repo searches MUST narrow path scope

在大仓库中，路径过滤是性能的关键（在文件遍历阶段即跳过无关目录）。选择最合适的参数组合：

| 参数 | 何时用 | 示例 |
|------|--------|------|
| `--sp "path"` | 已知目标在哪个子目录 | `--sp "src/project"` |
| `--xp "a,b"` | 已知要排除哪些路径 | `--xp "test,deprecate,Tools"` |
| `--pp "A\|B"` | 多个候选目录（OR） | `--pp "Services/Common\|Services/Core"` |
| `-d "name"` | 按目录名限制 | `-d "^Services$"` |
| `-k N` | 已知最大深度 | `-k 9`（从前一轮 summary 获取） |
| `--nf "pat"` | 排除特定文件名 | `--nf "Test"` |

**推荐组合**（大仓库 .cs 搜索，逐步叠加 `--xp` → `--sp` → `-k`）：
```text
gfind-file -I -f "\.cs$" -t "HttpClient" --xp "test,deprecate" --sp "src/main/services" -k 13 -H 5 -T 1 --timeout 30
```

⚠️ `gfind-*` 只搜索 git-tracked 文件，因此 `/obj/`、`/bin/` 通常已被 `.gitignore` 排除——`--xp "/obj/,/bin/"` 在大多数仓库中是冗余的。但 `--xp "test"` 排除测试目录仍然有价值。大仓库 **必须加 `--sp`**（限定源码根目录），仅用 `--xp` 仍会扫描整棵目录树。

### Reuse summary info immediately

首轮搜索的 summary 包含关键信息。后续搜索应**立即复用**：

- `MaxMatchedDepth = 9` → 后续同类型搜索加 `-k 9`
- `read 448 files` → scope 基线已知，后续不同 pattern 直接 `-H 1` 验证
- `read 0 files` → scope 太窄，放宽 `--sp`/`--xp`

⚠️ **不要重复搜索**。`-t "TargetFramework"` 已包含 `TargetFrameworks`（子串匹配），无需两条独立搜索。

### Batch similar searches with alternation

不要对每个候选值单独搜索。用 alternation 合并为一条命令：

```text
# BAD: N 条单独搜索 → N 轮 tool call
gfind-file -I -f "\.csproj$" -x "Polly" -l -H 5
gfind-file -I -f "\.csproj$" -x "Grpc" -l -H 5
# ... 每个候选值各一条

# GOOD: 1 条合并搜索 → 1 轮 tool call
gfind-file -I -f "\.csproj$" -t "Polly|Grpc|Serilog|Newtonsoft\.Json|Dapper" -l -H 30 --timeout 30 --xp "test,deprecate"
```

### Do not start with unbounded scan

避免一开始就：

- 全 repo
- 全文件类型
- 无结果上限
- 无上下文约束

### Additional guardrails

- **不要先诊断工具**——先直接试 `gfind-*`，只在命令不存在时才排障（见 [`references.md`](./references.md)）
- **`-def` 不一定最好**——优先 `-ref` + 文字约束或显式 regex
- **搜索的核心不是"最快"**——而是更小范围、更少噪音、更低 token、更可验证

### `-PIC` and `-A` rules

- 大多数 `gfind-*` 已含 `-I` → 用 `-PC`（不含 `-I`）。用 `find-alias gfind-xxx -Output name+body` 检查工具是否含 `-I`
- `gfind-file` 无内置 `-I` → 用 `-I -PC` 或 `-PIC`
- **`msr -p` / `msr -rp` 在管道中必须加 `-I`**——`-I` 抑制 BOM 等额外信息行（走 stdout，会污染管道数据）；不加 `-I` 时这些行混入下游命令的输入
  - **多文件管道提取**（如 `msr -rp src/ ... -PIC | nin ...`）：用 `-PIC`（`-P` 去路径省 token）
  - **单文件搜索 + strip-path 后缀**（如 `msr -p file ... -IC | msr ... -PIC`）：第一段用 **`-IC`**（不加 `-P`，保留路径和行号供第二段 regex 提取）；第二段（strip-path 后缀）用 `-PIC`
- 不要用 `-A`（`--no-any-info`，抑制所有 summary）——Agent 需要 summary 做决策（summary 走 stderr，不污染管道）。管道各段均用 `-PIC` 而非 `-PAC`

### Do not treat non-zero return value as failure

正数返回值 = 匹配行数，不是错误。跨平台截断细节见 [`references.md`](./references.md#return-value-is-not-boolean-successfailure)。

### Common mistakes checklist

本 skill 重点防止这些错误：

- **NEVER** 用 `-t "."` 或 `-t ".+"` 等价"匹配所有"——正则 `.` 匹配除换行外任意字符，等于 dump 全文。需要原始内容用 `type` (Windows) / `cat` (bash)；按行过滤用真实模式；`msr -p file -PIC` 不加 `-t` 已能输出全部行
- **NEVER** `msr -p` / `msr -rp` / `gfind-*` 多文件搜索缺少**全部** `-t`/`-x`/`--nt`/`--nx` **且**未加 `-l`——这等价 dump 所有匹配文件全文到 stdout，污染 agent context。多文件场景必须 ≥1 个内容过滤；只要文件清单加 `-l`
- **NEVER** 用 `read_file` 读大文件后只引用其中几行——用 `msr -p file -t "pattern" -U 2 -D 20 -H 5 -IC | msr -t "^..[^:]+:(\d+:.*?)$" -o "\1" -PIC` 去路径保行号
- 在 `gfind-*` 可用时，对需要路径过滤或 summary 统计的仓库级搜索仍用 IDE `search_files`（工具不可用或小仓库简单搜索时，`search_files` 是合理 fallback）
- 第一轮搜索不加 `-H N` 限量，导致全量输出淹没上下文
- 用 `-PIC` 配 `gfind-*`（工具已含 `-I`，导致重复参数错误）
- 把 exit code = 1 当做命令失败（实际是命中 1 行）
- 噪音多时只加更多路径条件，不用 `-x`/`--nt`/`--nx` 做内容过滤
- 把 PowerShell `|` 问题泛化成所有 shell 的问题
- **用 `-o "\1"` 提取时，`-t` pattern 须以 `^.*` 开头 + `.*?$` 结尾匹配整行**——否则行首/行尾内容残留；提取部分用非贪婪 `.+?` / `.*?`，贪婪 `.+` 会吞掉后续字段（详见 [`safe-replace/references.md`](../safe-replace/references.md)）
- **nin 的 positional regex 忘记加 capture group `(...)`**——导致 nin 报错退出（`No Regex capture1 in pattern`）而非按 key 比较
- 搜索目标来自口述/文档/非代码来源时忘记加 `-i`——导致因大小写不匹配而漏掉结果
- 只用 `-t` 和 `--sp` 两三个参数写所有搜索命令——见 [path filtering table](#path-filtering-parameters-in-recommended-order) 的完整参数和推荐顺序
- 文件类型不确定时选了 `gfind-file` 而非 `gfind-small`——应默认用 `gfind-small`（size cap ≤1.6MB 覆盖几乎所有源码），仅在明确需要大文件时才用 `gfind-file`
- 需要看匹配行上下文时用 `read_file` 打开整个文件——应先用 `-U N -D N` 看局部上下文（如 `-U 2 -D 30`），单文件搜索追加固定后缀 `| msr -t "^..[^:]+:(\d+:.*)" -o "\1" -PIC` 去路径留行号。**只有** repo 根目录的小型文件（<5KB）需要完整内容时，才用 `read_file`。**连续 3+ 个 `read_file` 是过度浏览的信号**——应退回搜索策略
- 生成管道命令时用 `Select-String`/`Group-Object`/`sort | uniq -c` 而非 `| msr`/`| nin`——详见下方 [Pipe processing](#pipe-processing-use-msr-not-shell-native)
- 不要用 `msr --version` 检测工具可用性——msr 与 nin 只支持 `-h` 来检查是否存在（如 `msr -h`）
- **大写和小写 flag 含义完全不同**——如 nin 的 `-a`（`--ascending`）vs `-A`（`--no-any-info`），msr 的 `-p`（`--path`）vs `-P`（`--no-path-line`）。不可按小写含义推断大写，不确定时用 `msr -h -C` 或 `nin -h -C` 查验
- **`-x` 中使用 `|` 做 alternation**——`-x` 是纯文本匹配，`|` 被当成字面字符而非 OR。必须用 `-t "A|B|C"` 代替 `-x "A|B|C"`
- **重复 `read_file` 同一文件**——已读过的文件内容在上下文中，不要再读第二次。如需查找特定内容用 `msr -p file -t "pattern" -IC | msr -t "^..[^:]+:(\d+:.*)" -o "\1" -PIC`
- **msr flag 依赖关系缺失**——`-B`/`-E`（时间范围）必须配 `-F`（时间 regex）；`-K` backup 必须配 `-R` replace；`-Q` stop-block 必须配 `-b` start-block；`-y` reuse-block-end 必须配 `-Q`；`-n` sort-as-number 必须配 `-s` sort-by。缺依赖 → exit -1
- **nin `-I` 与 msr 反向**——nin `-I` = `--info-normal-out`（summary 写 **stdout**，污染管道下游），msr `-I` = `--no-extra`（summary 写 stderr）。**禁止给 nin 加 `-I`**；要静音用 `-M`

### Pipe processing: use msr, not shell native

**在生成管道文本处理命令（`cmd | ...`）前，对照以下检查表**：

| 即将用 | → 改用 |
|--------|--------|
| `Select-String` / `Where-Object` / `ForEach-Object` | `\| msr -t ...`（行过滤/变换） |
| `Measure-Object -Line` / `wc -l` | `\| msr -H 1`（不加 `-t`，summary 报告行数） |
| `Select-Object -First N` / `head -N` | `\| msr -H N` |
| `Select-Object -Last N` / `tail -N` | `\| msr -T N` |

集合操作（去重/分布/差集）→ 见 [`set-mining` Pipe processing](../set-mining/SKILL.md#pipe-processing-use-nin-not-shell-native)

### Do not fall back to IDE search_files due to pipe character in arguments

决策顺序见 fast path；shell-specific 转义写法见 [`references.md`](./references.md) 中的 `Guardrails & Gotchas`。

## Preferred Search Strategy

管道处理：msr stdin 模式与文件模式行为一致。**管道首段也必须加 `-H N -T N` 先观察首尾样本**，确认输出格式符合预期后再去掉 `-H` 做全量处理。常见模式：
```text
cmd | msr -t "pattern" -H 1                                          # 行过滤 + 计数
cmd | msr -t "(\w+Exception).*?$" -o "\1" -PIC -H 1 -T 1             # 先验证提取是否干净（首尾各1行）
cmd | msr -t "(\w+Exception).*?$" -o "\1" -PIC | nin nul "(\w+)" -pd -C  # 验证通过后全量提取
```

### Case F. Compliance checking ("has A but not B")

适用：

- ConfigureAwait 合规检查
- 安全审计（找 `new HttpClient` 但排除 Factory 类）
- 代码规范检查（找 `TODO` 但排除特定模块）

⚠️ **`-t A --nt B` 是行级过滤，不是文件级过滤**：同一文件如果有些行含 A 但不含 B，这些行会被匹配，即使同一文件的其他行同时含 A 和 B。如果需要文件级的"有 A 无 B"，应分别生成文件列表后用 `nin` 做差集。

顺序：

1. 用 `-t A --nt B` 做"有 A 无 B"单命令搜索（行级）
2. 用 `-H 1` 看 summary + 1 行验证样本，得到分子
3. 用 `-t A -x B` 做反向搜索，得到分母
4. 从 2 行 summary 直接计算合规率

示例：
```text
gfind-file -I -f "\.cs$" -t "\bawait\b" --nt "ConfigureAwait" --sp "src" --xp "test,/deprecated" -H 1 -T 1
# → summary: Matched N lines = 缺失 ConfigureAwait 的行数（首行验证 regex，尾行验证 scope 边界）

gfind-file -I -f "\.cs$" -t "\bawait\b" -x "ConfigureAwait" --sp "src" --xp "test,/deprecated" -H 1 -T 1
# → summary: Matched M lines = 包含 ConfigureAwait 的行数

# 合规率 = M / (M + N)，从 2 行 summary 直接计算
```

### Case G. Multi-dimension coupling analysis

适用：

- 模块拆分前评估不同维度的耦合深度
- 比较不同技术栈/框架/依赖的渗透范围
- 优先级排序（哪个维度最深、应先解耦）

顺序：

1. 第一次 `-H 1 -T 1` 建立 scope 基线（如 "N files"，首尾行验证 scope 正确）
2. 后续多次不同 pattern 的 `-H 1 -T 1` 搜索（同 `--sp`/`--xp`，验证 + 计数）
3. 每次 summary 的 `matched files / N` = 该维度的耦合百分比
4. 组合多个百分比构建热力图，**零额外 tool call**

关键：summary 中 `read N files` 在同一 scope 下跨 pattern 恒定（不变量），Agent 无需重新验证分母。

> 更多场景策略（file-list scope、definition lookup 等）见 [`references.md`](./references.md)

## Trigger

在以下场景触发本 skill：

- 需要先缩小范围，再做搜索
- 不确定目标在哪个目录、模块或语言中
- 需要低 token、低噪音搜索
- 需要多条件精确过滤（路径约束 + 内容约束组合）
- 需要跨多次搜索复用 scope 基线
- **需要对任意命令输出做行过滤、计数、提取或统计**（msr stdin 模式）

## Core Principles

- **用上所有已知信息来过滤**：已知路径用 `--sp`/`--xp`/`-d`；已知文件类型用 `gfind-file -I -f`；已知关键词用 `-x`/`-t`；已知排除内容用 `--nt`/`--nx`；已知深度用 `-k`。过滤参数越多，噪音越少，速度越快（路径过滤在遍历阶段即生效，大仓库可快数倍）
- **初始搜索必须加 `-H N`**（常规用 `-H 20`；存在性检查 `-H 1 -J`；仅看统计 `-H 1`），控制输出规模；summary 仍报告完整统计
- 先补更多相关过滤条件，再考虑扩大范围
- 先控制输出规模，再决定是否展开
- **利用 summary 中的 `MaxMatchedDepth` 加速后续搜索**：首次搜索读取 summary 中的 `MaxMatchedDepth`，后续同 scope 搜索加 `-k = MaxMatchedDepth` 可减少文件遍历（实测可快 2~3×）
- **msr 不仅是文件搜索工具，也是通用管道文本处理器**：stdin 模式（`cmd | msr -t ...`）与文件模式（`msr -p file -t ...`）行为完全一致，所有参数通用

## Output Rules

- msr/nin 的 summary（`Matched N lines ...` / `Got N lines ...`）是命令的最后一行输出——看到 summary 即表示命令已完成，无需等待更多输出
- 未知范围时，先输出小样本
- 默认优先可解析输出
- 保留 location 信息，除非明确只需要纯文本
- 不为了简洁而丢失后续导航能力
- 不在第一轮搜索中输出整页大结果

## Workflow Integration

搜索完成后的常见下一步：
- 搜索结果需要统计分布 → pipe 到 [`set-mining`](../set-mining/SKILL.md)（如 `gfind-file -I -f "\.cs$" -t "pattern" -PC | nin nul "(\w+)" -pd`）
- 搜索确认后批量修改 → 切换到 [`safe-replace`](../safe-replace/SKILL.md)（搜索命令加 `-o "replacement"` 预览，再加 `-R` 写入）

## References

- [`references.md`](./references.md)