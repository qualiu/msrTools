@echo off
SetLocal EnableExtensions EnableDelayedExpansion

where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%~dp0;%PATH%"

msr -z "X%~1" -it "^X(|-h|--help|/\?)$" >nul
if !ERRORLEVEL! EQU 1 (
    echo Usage:   %0  LocalPath
    exit /b -1
)

pushd %~dp1
for /f "tokens=*" %%a in ('git rev-parse --abbrev-ref HEAD') do set "BranchName=%%a"
for /f "tokens=*" %%a in ('git rev-parse --show-toplevel ^| msr -x / -o \ -aPAC') do set "GitRepoRootDir=%%a"
for /f "tokens=*" %%a in ('git remote get-url origin') do set "GitUrlHome=%%a"
popd

if "!GitRepoRootDir!" == "" (
    echo Not found git root. | msr -aPA -t "(.+)" & exit /b -1
)

for /f "tokens=*" %%a in ('msr -z "%~dp1%~nx1" -ix "!GitRepoRootDir!\\" -o "" -PAC ^| msr -x \ -o / -aPAC') do (
    set "FileUrl=%GitUrlHome%?version=GB%BranchName%&path=/%%a"
    REM for /f "tokens=*" %%b in ('powershell "Add-Type -AssemblyName System.Web; [System.Web.HttpUtility]::UrlEncode('/%%a')"') do set "EncodedUrl=%GitUrlHome%?version=GB%BranchName%&path=%%b"
)

echo explorer "!FileUrl!" | msr -XIM
