::=======================================================
:: Check and fix style for last committed files.
:: Latest version in: https://github.com/qualiu/msrTools/
::=======================================================
@echo off
SetLocal EnableExtensions EnableDelayedExpansion

where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%PATH%;%~dp0"

if /I "%~1" == ""          goto :ShowUage
if /I "%~1" == "-h"        goto :ShowUage
if /I "%~1" == "--help"    goto :ShowUage
if /I "%~1" == "/?"        goto :ShowUage

if [%1] == [] ( set "Is_Just_Show_Commands=1" ) else ( set "Is_Just_Show_Commands=%~1" )

set ScriptDir=%~dp0
if %ScriptDir:~-1%==\ set ScriptDir=%ScriptDir:~0,-1%

set FixStyleScript=%ScriptDir%\fix-file-style.bat

:: git log --name-only -1 --oneline --pretty="format:" --stat=500 --relative=.
:: git show head --relative=. --name-only --stat=500 --oneline --pretty="format:"
for /f "tokens=*" %%a in ('git rev-parse --show-toplevel ^| msr -x / -o \ -aPAC') do set "GitRepoRootDir=%%a"
for /f "tokens=*" %%a in ('git show head --name-only --stat^=500 --oneline --pretty^="format:" ^| msr -x / -o \ -aPAC') do @(
    if "%Is_Just_Show_Commands%" == "1" (
        echo %FixStyleScript% "%GitRepoRootDir%\%%a" | msr -PA -ix "%GitRepoRootDir%\%%a" --nt "\bmakefile\W{0,2}\s*$"
    ) else (
        echo %FixStyleScript% "%GitRepoRootDir%\%%a" | msr -ix "%GitRepoRootDir%\%%a" --nt "\bmakefile\W{0,2}\s*$" -XM
    )
)

git status
exit /b 0

:ShowUage
    echo Usage:   %0  [Is_Just_Show_Commands](default: 1)
    echo Example: %0  1
    echo Example: %0  0
    exit /b 0
