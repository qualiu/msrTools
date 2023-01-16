@echo off
SetLocal EnableExtensions EnableDelayedExpansion

where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%~dp0;%PATH%"

msr -z "LostArg%~1 " -t "^LostArg(|-h|--help|/\?) $" >nul || (
    echo Usage:   %0  LocalPath
    exit /b -1
)

@REM echo on
pushd %~dp1
for /f "tokens=*" %%a in ('git rev-parse --abbrev-ref HEAD') do set "BranchName=%%a"
for /f "tokens=*" %%a in ('git rev-parse --show-toplevel ^| msr -x / -o \ -aPAC') do set "GitRepoRootDir=%%a"
for /f "tokens=*" %%a in ('git remote get-url origin ^|
    msr -t "git@(github.com):(\S+).git" -o "https://\1/\2" -aPAC ^|
    msr -t "://(\S+?):(.+?)@" -o "://" -aPAC') do set "GitUrlHome=%%a"
popd

msr -z "!GitUrlHome!" -it "github.com" >nul
set /a IsGithubUrl=!ERRORLEVEL!

if "!GitRepoRootDir!" == "" (
    echo Not found git root. | msr -aPA -t "(.+)" & exit /b -1
)

set "SourcePath=%~dp1%~nx1"
if "%SourcePath:~-1%" == "\" set "SourcePath=%SourcePath:~0,-1%"

echo SourcePath=!SourcePath!
echo GitRepoRootDir=!GitRepoRootDir!
echo GitUrlHome=!GitUrlHome!
for /f "tokens=*" %%a in ('msr -z "!SourcePath!" -ix "!GitRepoRootDir!\\" -o "" -PAC ^| msr -x \ -o / -aPAC') do (
    if !IsGithubUrl! GTR 0 (
        set "FileUrl=%GitUrlHome%/blob/!BranchName!/%%a"
    ) else (
        set "FileUrl=%GitUrlHome%?version=GB%BranchName%&path=/%%a"
        REM for /f "tokens=*" %%b in ('powershell "Add-Type -AssemblyName System.Web; [System.Web.HttpUtility]::UrlEncode('/%%a')"') do set "EncodedUrl=%GitUrlHome%?version=GB%BranchName%&path=%%b"
    )
)

:: Remove branch name for git submodule paths
for /f "tokens=*" %%a in ('msr -z "!FileUrl!" -t "&bversion=GBHEAD\b|version=GBHEAD&" -o "" -PAC') do set "FileUrl=%%a"

@REM echo explorer "!FileUrl!"
echo explorer "!FileUrl!" | msr -XIM
