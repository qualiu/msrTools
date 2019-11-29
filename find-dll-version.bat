::======================================================================
::Find DLLs and print version info.
::======================================================================

@if "%PATH:~-1%" == "\" set "PATH=%PATH:~0,-1%"

@echo off
SetLocal EnableExtensions EnableDelayedExpansion

where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%PATH%;%~dp0"

msr -z "NotFirstArg%~1" -t "^NotFirstArg(|-h|--help|/\?)$" > nul
if %ERRORLEVEL% NEQ 0 (
    echo Usage:   %0  MSR-OPTIONS excpect: -lPAC or -l -P -A -C combinations. | msr -aPA -t "excpect:|((?<=\s)-{1,2}\w+)" -e MSR-OPTIONS
    echo Example: %0  -rp . -f ActiveDirectory.dll$ | msr -aPA -e "\s+-{1,2}\w+"
    echo Example: %0  -rp . -f ActiveDirectory.dll$  -W  | msr -aPA -e "\s+-{1,2}\w+"
    echo Example: %0  -rp . -f ActiveDirectory\.dll$ -W --nd packages  | msr -aPA -e "\s+-{1,2}\w+"
    echo More MSR-OPTIONS of msr.exe see https://github.com/qualiu/msr/ | msr -aPA -ie "msr\S*|http\S+"
    exit /b -1
)

powershell "msr %* -l -PAC | ForEach-Object { $v = (Get-Item $_).VersionInfo.FileVersion; Write-Output $v`t$_ }"
