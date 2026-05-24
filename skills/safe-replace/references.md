# Safe Replace References

本文件保存 [`SKILL.md`](./SKILL.md) 的命令模式与高风险细节。

**工具 troubleshooting**：只有在默认 `gfind-*` 路径缺失或明显异常时，才去看 [`smart-search/references.md`](../smart-search/references.md#troubleshooting-tool-availability)。

## Why this reference is worth reading first

若任务已经进入“准备改文件”，这个 reference 值得 Agent 优先掌握，因为它会直接减少以下误用：

- 误把 preview 当成可省略步骤
- 误把 block-scoped 修改降级成普通 regex replace
- 误忽略 BOM、编码、line ending 风险
- 误以为 replace 后无需做 residual check
- 误在 PowerShell 中直接传带 `|` 的参数给 `.cmd` 脚本

Agent 读完本文件后，应更清楚：

- 什么时候该先预览、再写入、再验证
- 哪些场景必须考虑 block、编码、backup
- 哪些命令模式适合低风险批量修改

## Standard Workflow

除非明确标注 shell 类型，否则下面的示例默认按 shell-neutral 理解。

### 1. Scope verification

```text
gfind-file -I -f "\.cs$" -t "\bOldName\b" -l -H 20           # which files
gfind-file -I -f "\.cs$" -t "\bOldName\b" -H 30              # sample matches
```

### 2. Preview changes

```text
gfind-file -I -f "\.cs$" -t "\bOldName\b" -o "NewName" -j -H 20    # only changed lines
```

### 3. Apply with backup

```text
gfind-file -I -f "\.cs$" -t "\bOldName\b" -o "NewName" -RK   # write + backup
```

### 4. Residual verification

```text
gfind-file -I -f "\.cs$" -t "\bOldName\b" -H 1 -J            # any remaining?
```

## High-Risk Areas

### BOM and encoding

- 非 UTF-8 BOM 文件替换需 `--force`，替换后转为 UTF-8 no BOM
- 批量 apply 前须用户确认编码转换

### Line ending behavior

> ⚠️ msr 写文件时采用**系统原生换行**（Windows CRLF，Linux/macOS LF），**不保留原始行尾风格**。在 Windows 上替换 Unix LF 文件会变成 CRLF。跨平台仓库建议确认 `.gitattributes` 配置（如 `* text=auto`）。

### Skip writing when content unchanged

- 替换后内容未变化则不写文件，避免虚假 dirty state

### Calling gfind-xxx / find-xxx with `|` in regex on PowerShell

PowerShell 调用 `.cmd` 脚本时，参数中的 `|` 被 CMD 误解为管道符。两种解决方式：

```text
# 方式 1: 使用 --% stop-parsing token（推荐）
gfind-file -I --% -f "\.cs$" -t "OldName|NewPattern" -o "Replaced" -j -H 20

# 方式 2: cmd /c 外层引号包裹
cmd /c "gfind-file -I -f ""\.cs$"" -t ""OldName|NewPattern"" -o ""Replaced"" -j -H 20"
```

⚠️ 仅影响 **PowerShell** 调用 `.cmd` 文件。CMD 终端和 **Git bash (MinGW)** 都不受影响——Git bash 加 `--%` 会被 msr.exe 视为非法参数报 `unrecognised option`。Git bash 复杂命令含 `|`/`(` 用 `cmd <<< '{full cmdline}'`（heredoc），简单命令用 `cmd //c "{cmd}"`。

## Block-scoped replacement

```text
# INI section style
msr -p config.ini -b "^\[section-name\]" -Q "^$" -t "old_value" -o "new_value"

# XML block style
msr -p config.xml -b "^\s*<Server>" -Q "^\s*</Server>" -t "old_host" -o "new_host"
```

- `-b` 块起始，`-Q` 块结束，替换只在块内生效
- `-Q "" -y` 处理连续 section（end pattern = begin pattern）
- `-a` 输出整个块（含未匹配行）用于预览
- `-S` 单行模式：对 block 启用时，整个 block 被视为一行，`^`/`$` 匹配 block 首尾，适合跨行 regex

```text
# Single-line regex across block lines
msr -p file.xml -b "^\s*<Config>" -Q "^\s*</Config>" -S -t "key1.*?key2" -o "replaced"
```

- `-q` 立即停止读取整个文件（非 block 级别，与 `-Q` block 结束不同）

```text
# Only read from -b match to -q match (inclusive)
msr -p large.log -b "^START" -q "^END"
```

## Command Templates

> 占位约定:`<paths>` 默认指**非 git 目录或非追踪子树**(如 `logs/`、外部目录);git repo 内追踪文件改用 `gfind-file -I -f "<file_pattern>" ...`(无需 `-rp <paths>`,gfind-* 自动锁定 git tree)。`-rp` 默认遍历**全部文件类型**,**必须**配 `-f`。

### Preview changed lines only (-j)

```text
# 非 git 目录
msr -rp <non-git-paths> -f "<file_pattern>" -t "<search>" -o "<replace>" -j
# git repo
gfind-file -I -f "<file_pattern>" -t "<search>" -o "<replace>" -j -H 5
```

### Replace with backup

```text
# 非 git 目录(`-RK` 写入 + 备份)
msr -rp <non-git-paths> -f "<file_pattern>" -t "<search>" -o "<replace>" -RK
# git repo(git 本身即版本管理,通常 `-R` 而非 `-RK`)
gfind-file -I -f "<file_pattern>" -t "<search>" -o "<replace>" -R
```

### Residual verification

```text
msr -p <file_or_scope> -t "<old_pattern>" -H 1 -J
```

### Multi-round replacement (-g -1)

```text
# Leading TAB to spaces (anchored pattern); 非 git 目录
msr -rp <non-git-paths> -f "<file_pattern>" -t "^(\s*)\t" -o "\1    " -g -1 -R

# Compress multiple spaces(单文件)
msr -p <file> -t "  " -o " " -g -1 -R
```

何时需要 `-g -1`：
- 锚定模式（`^`、`$`）
- 替换结果产生新匹配（压缩、嵌套剥离）

### Batch execution (-X)

⚠️ `-X` 将搜索结果转为 shell 命令执行——必须确保输入来自可控来源（`gfind-*` / `msr -l`），且已通过不加 `-X` 的预览确认命令正确。不要对不可信文本直接拼接为可执行命令。

`-o` 中的命令必须匹配当前 shell；默认先预览生成命令，再对同一批命令加 `-X` 执行。

```text
# Preview PowerShell cleanup commands only(. 假定非 git 目录;git repo 改用 gfind-file)
msr -rp . -f "\.bak$" -l -PIC | msr -t "(.+)" -o "Remove-Item \"\1\"" -PIC

# Execute the same cleanup commands, showing commands and only errors
msr -rp . -f "\.bak$" -l -PIC | msr -t "(.+)" -o "Remove-Item \"\1\"" -XMO

# Bash example: run shell scripts fail-fast
msr -rp . -f "\.sh$" -l -PIC | msr -t "(.+)" -o "bash \"\1\"" -XM -V ne0
```

- 默认批处理推荐 `-XMO`；需要 fail-fast 时推荐 `-XM -V ne0`


## Advanced Replace Patterns

### Replace source selection: -t + -x + -o proximity rule

```text
# -x closer to -o → -x is replace source
msr -p file.txt -t "(foo)" -x "world" -o "[replaced]" -PIC

# -t closer to -o → -t is replace source
msr -p file.txt -x "foo" -t "(world)" -o "[\1-replaced]" -PIC
```

距离 `-o` 更近的成为替换源，另一个保持过滤功能。距离相等时左侧优先。

### Clean capture group extraction

```text
# WRONG: trailing content preserved
msr -p file.txt -t "name:\s*(\w+)" -o "\1" -PIC
# "name: Alice age: 30" → "Alice age: 30" ← wrong!

# CORRECT: match entire line
msr -p file.txt -t "name:\s*(\w+).*?$" -o "\1" -PIC
# "name: Alice age: 30" → "Alice" ← clean!
```

⚠️ `-o "\1"` 提取时，`-t` 必须消费整行（以 `.*?$` 结尾）。

### Output all lines with -a

```text
msr -p config.ini -t "debug=true" -o "debug=false" -a > config-updated.ini
```

- 加 `-a`：输出全部行（匹配行经替换，非匹配行原样）

### Backup collision avoidance (-K)

- backup 使用原文件 mtime，同秒多次替换自动追加 `--2`、`--3` 后缀
- 永不丢失数据

### Prefer \1 over $1 in -o

- `\1` 在所有 shell 中安全（CMD、PowerShell、bash）
- `$1` 在 PowerShell/bash 中可能被变量展开

## Short Flag Differences: msr vs nin

详细对照表见 [`smart-search/references.md`](../smart-search/references.md) 的"Short flags differ between msr and nin"章节。

关键提醒：本 skill 中 `-a`（msr: `--out-all`，输出全部行含未匹配行）常用于替换预览，不要与 nin 的 `-a`（`--ascending`）混淆。

⚠️ msr/nin 的大写和小写 flag 含义完全不同（如 `-a` vs `-A`、`-p` vs `-P`），不可互推。不确定时用 `msr -h -C` 或 `nin -h -C` 查验。