::==============================================================
:: Revert files that has no content changed.
:: Latest version in: https://github.com/qualiu/msrTools/
::==============================================================
@echo off
SetLocal EnableExtensions EnableDelayedExpansion
if /I "%~1" == ""          goto :ShowUage
if /I "%~1" == "-h"        goto :ShowUage
if /I "%~1" == "--help"    goto :ShowUage
if /I "%~1" == "/?"        goto :ShowUage

where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%PATH%;%~dp0"

set Is_Just_Show_Commands=%1
if not defined Is_Just_Show_Commands set Is_Just_Show_Commands=1

for /f "tokens=*" %%a in ('git status ^| msr -t "^\s+(?:\S+\s*:\s+)?((?:\.+|\w+).+?)\s*$" --nt "\buse.*git|^nothing|/\s*$" -o "$1" -PIC ') do (
    git diff %%a | msr >nul
    if !ERRORLEVEL! EQU 0 (
        echo git checkout -- %%a | msr -aPA -x "%%a" -e "git \w+"
        if %Is_Just_Show_Commands% NEQ 1 (
            git checkout -- %%a
        )
    )
)

git status
exit /b 0
:ShowUage
    echo Usage:   %0  [Is_Just_Show_Commands](default: 1)
    echo Example: %0  1
    echo Example: %0  0
    exit /b 0
