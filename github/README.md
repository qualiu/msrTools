# GitHub TOTP tool

这个 Windows 工具为一个或多个 GitHub 账户生成 TOTP 验证码。长期 seed 保存在 Windows Credential Manager；QR 图片只在本机解码。

## 安装

在仓库根目录执行：

```powershell
python -m pip install -r github/requirements.txt
python github/totp.py --help
```

每个子命令都提供说明和示例，例如 `python github/totp.py now --help`。建议使用帮助中列出的完整选项名或 alias，避免缩写歧义。

工具仅接受 GitHub 的标准参数：`SHA1`、6 位数字、30 秒周期。系统时间不准会导致验证码失效。

## setup key 是什么

setup key 是 QR code 内的 TOTP secret/seed，通常是一段不区分大小写的 Base32 文本，例如由 `A-Z` 和 `2-7` 组成，显示时可能带空格、连字符或末尾的 `=`。它不是 GitHub 密码、recovery code、PAT 或当前 6 位验证码。

QR 的解码结果通常是：

```text
otpauth://totp/GitHub:ACCOUNT?secret=BASE32_SECRET&issuer=GitHub&...
```

setup key 或完整 `otpauth://` URI 都能配置相同的 TOTP。任何获得 seed 的人都能持续生成验证码，因此不要把真实值写入仓库、日志、聊天或命令示例。

## 首次注册

推荐在 GitHub 显示新 QR 的同一页面完成所有设备注册：

1. 先确认 recovery codes、passkey 或其它恢复方式可用。
2. 保持 GitHub 的 QR/setup key 页面打开。
3. 手机 Authenticator 扫描该 QR。
4. 同时把同一个 QR 导入本工具，或把同一个 setup key 输入本工具。
5. 确认手机与工具在同一 30 秒窗口显示相同验证码，再向 GitHub 提交一个验证码完成注册。

手机先扫还是工具先导入都可以；关键是两者使用同一个 seed。只扫描手机后再执行工具，不会自动把手机里的 seed 传给电脑。

从 QR 图片导入，账户名会从 QR 中读取；`--account` 可额外校验：

```powershell
python github/totp.py import-qr --name personal --account YOUR_GITHUB_LOGIN "C:\secure-temp\github-qr.png"
```

从隐藏提示输入 setup key 或 QR 解码后的完整 `otpauth://` URI：

```powershell
python github/totp.py enroll --name personal --account YOUR_GITHUB_LOGIN
```

隐藏输入不可用时工具会拒绝继续，不会退化为回显 setup key；非交互输入须显式使用 `--stdin`。

如果输入完整 URI，可以省略 `--account`，工具会读取并验证 URI 中的 GitHub 账户。裸 setup key 没有账户信息，因此必须传 `--account`。

也可以直接传 setup key：

```powershell
python github/totp.py enroll --name personal --account YOUR_GITHUB_LOGIN --setup-key "BASE32_SETUP_KEY"
```

`--setup-key` 方便但会把 seed 留在 shell history，并可能短暂出现在进程参数中；隐藏提示更安全。完成后保护或安全删除 QR 图片和临时 seed 副本。

## Authenticator app 已显示 Configured

GitHub 不会从已配置状态重新显示原 seed，工具也不能从手机验证码或 recovery code 推导 seed。Recovery code 只能恢复登录，不能创建相同的 TOTP。

如果没有保存原 setup key/QR，需要在已认证的 GitHub 会话中重新配置 Authenticator app，让 GitHub 生成新 QR，然后在提交验证码前让手机和所有电脑读取同一个新 seed。重新配置会使旧 seed 生成的验证码失效；操作前先确认恢复方式。

## 获取验证码

未指定名称时使用 `default` profile：

```powershell
python github/totp.py now
python github/totp.py now --clipboard
```

指定一个 profile：

```powershell
python github/totp.py now --name personal
python github/totp.py now --profile work --copy
```

查看所有名称，或一次获取所有验证码：

```powershell
python github/totp.py profiles
python github/totp.py now --all
```

`now --all` 按顺序把每个 `profile/account` 映射写到 stderr，把对应验证码逐行写到 stdout。`--name all` 表示名称确实为 `all` 的单个 profile，不等于 `--all`。

临时根据 setup key 计算但不保存：

```powershell
python github/totp.py now --setup-key "BASE32_SETUP_KEY"
```

`now --setup-key` 不需要 `--account`，只接受 Base32 secret text，不接受完整 URI；URI 请用 `enroll` 的隐藏提示或 `--stdin` 导入。未指定 selector 时，`now` 只读取 `default`，不会自动提示输入或生成 setup key。缺少该 profile 时，可先 `enroll`/`import-qr`，选择已有名称 `now --name PROFILE`，或用 `now --setup-key` 临时计算。临时计算不需要 Windows Credential Manager，但 `--clipboard` 仍要求 Windows。

所有 `now` 模式的 stdout 只包含 6 位验证码。警告、账户映射、错误和三位小数的耗时（如 `ELAPSED: 0.123 s`）都写到 stderr，便于脚本只捕获 stdout。`--clipboard`/`--copy` 会额外复制验证码；Windows clipboard history 或跨设备同步可能保留它。

退出码：`0` 表示成功，`1` 表示运行失败或缺少有效凭据，`2` 表示命令行用法错误。`--help` 返回 `0`，帮助正文输出到 stdout。参数解析错误不会回显未知参数、未知命令或错误附加的参数值，但这不能消除命令历史和进程参数中的 secret 暴露风险。本工具不提供已保存 setup key 的导出功能。

## 多账户与安全更新

profile 是本机别名，GitHub account 是 QR 或 `--account` 指定的真实登录名。例如：

```powershell
python github/totp.py enroll --name personal --account PERSONAL_LOGIN
python github/totp.py enroll --name work --account WORK_LOGIN
```

`enroll`、`status` 和 `delete` 省略 `--name` 时也使用 `default`。

已存在的 profile 默认拒绝覆盖。GitHub 正在显示同一账户的新 seed 时使用：

```powershell
python github/totp.py enroll --name work --account WORK_LOGIN --replace
```

`--replace` 只允许更新同一 GitHub account；跨账户会被拒绝。要重新使用名称，先明确删除本地 seed，再注册新账户：

```powershell
python github/totp.py delete --name work --yes
```

删除本地 seed 不会关闭 GitHub 2FA。`status` 只验证本地配置，不打印 seed 或验证码：

```powershell
python github/totp.py status --name work
```

如果 seed 已保存但 profile registry 更新失败，可修复索引：

```powershell
python github/totp.py register --name work
```

`register` 只修复已有 seed 的发现索引，不能导入或恢复 seed，也不能修复格式损坏的 registry marker。缺少 seed 的旧索引应先用同名 `enroll`/`import-qr` 恢复，或用 `delete --name PROFILE --yes` 清除；删除本地 seed 后，`register` 不能撤销删除。

## 多台机器

最直接的方案是在 GitHub 生成新 QR 时，让每台授权机器和手机导入同一个 seed。每增加一台机器都扩大 seed 的暴露面，只应在个人控制且已加密、已更新的设备上使用。

本工具故意不提供 seed 导出或自动同步。若以后还要添加机器，可在注册时把 seed 保存在受保护的密码管理器中；KeePassXC 是免费、开源的本地密码管理器，其加密数据库可通过你选择的同步方式分发，而且它本身也支持 TOTP。不要把明文 seed 放在普通同步目录或 Git 仓库中。若没有保留 seed，只能在 GitHub 重新配置 TOTP，并让所有设备重新导入新 seed。

## 本地存储

Credential Manager 使用以下条目：

- service：`msrTools.GitHubTOTP`
- seed record：`github.com/profile/<name>`
- registry marker：`github.com/profile-registry/NN`

seed record 包含账户、GitHub TOTP 参数和 seed，由当前 Windows 用户的 Credential Manager/DPAPI 保护；它不是仓库中的普通明文文件。registry marker 只包含类似 `{"profile":"work","version":1}` 的索引，不包含 seed 或验证码。

同机同一用户的写入、注册和删除使用跨进程锁串行执行，等待超过 10 秒会报错，不会继续写入。锁文件位于 `%LOCALAPPDATA%\msrTools\GitHubTOTP\store.lock`，不含 seed；它只协调本机，不用于跨机器同步，也不提供崩溃回滚。

这不是抵御当前 Windows 用户上下文中恶意程序的硬件隔离：同一用户权限下运行的程序可能调用凭据 API，进程生成验证码时也必须在内存中使用解密后的 seed。保护 Windows 登录、磁盘、同步和剪贴板同样重要。

其它工具或旧版本若使用不同 service，本工具不会自动读取或迁移其 credential，避免意外复制或覆盖个人配置。

## 测试

在仓库根目录执行：

```powershell
python -B -m unittest discover -s github/tests -p 'test_*.py' -v
```

帮助说明按完整句子或语义分句换行，说明列最多 180 显示列（不含选项及对齐缩进）；不随 `COLUMNS` 机械重排，命令示例保持完整可复制。窄终端仍可能自行折行，不改变程序输出的换行位置。

测试使用模拟存储和临时锁文件，覆盖并发写入、跨进程锁、隐藏输入、全部帮助入口的 `-h`/`--help`、窄宽终端布局、错误指引和参数值不回显，不读取或修改真实的 Windows Credential Manager 凭据。
