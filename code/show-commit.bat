::=============================================================================
:: This script leverage your configured git tool to show changed files. You can configure git tool like below:
:: git config --global diff.tool bc4
:: git config --global difftool.bc4.cmd "\"C:\\Program Files\\Beyond Compare 4\\BCompare.exe\" -s \"\$LOCAL\" -d \"\$REMOTE\""
::=============================================================================

@if "%PATH:~-1%" == "\" set "PATH=%PATH:~0,-1%"

@echo off
SetLocal EnableExtensions EnableDelayedExpansion

where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%~dp0;%PATH%"

msr -z "NotFirstArg%~1" -t "^NotFirstArg(|-h|--help|/\?)$" > nul
if !ERRORLEVEL! NEQ 0 (
    echo Usage:   %~nx0  commit_id
    echo Example: %~nx0  5a50e48673e0dacc14a41eed119b012326e9f68b
    msr -p %0 -q "^\s*@?echo" -t "^::\s*(\w+.+?)" -o "$1" -PAC | msr -PM -e "(git config .+)|\w+"
    exit /b -1
)

git show %1 --name-only | msr -aPA
git difftool "%~1^" "%~1" --name-only | msr -t "^(\S+.+)" -o "git difftool \"%~1^^\" %~1 \"\1\"" -X
:: git difftool "%~1^" "%~1" --name-only | msr -t "^(\S+.+)" -o "git show %~1 \"\1\"" -X
