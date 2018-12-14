::==================================================================
:: Modify a package version in C# projects. Used to unify versions.
::==================================================================
@echo off
SetLocal EnableExtensions EnableDelayedExpansion

where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%PATH%;%~dp0"

msr -z "X%~1" -it "^X(|-h|--help|/\?)$" >nul
if !ERRORLEVEL! EQU 1 (
    echo Usage:   %~nx0  Package-Name          Version
    echo Example: %~nx0  WindowsAzure.Storage  8.7.0
    exit /b 0
)

msr -rp . --nd "^(\.git|package|obj|release|debug|node_mod)" -f "^packages.config$" -it "(id=\"%~1\"\s+version)\s*=\s*\".+?\"" -o "$1=\"%~2\"" -j -Rc
msr -rp . --nd "^(\.git|package|obj|release|debug|node_mod)" -f "\.csproj$" -it "(HintPath.*\\%~1)\.\d+\.\S+?(\\\w+)" -o "${1}%~2$2" -j -R -c
