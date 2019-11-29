::====================================================
:: Check DLL or EXE file platform bits.
::====================================================
@if "%PATH:~-1%" == "\" set "PATH=%PATH:~0,-1%"

@echo off
SetLocal EnableExtensions EnableDelayedExpansion

where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%PATH%;%~dp0"

if "%~1" == "" (
    echo Usage   : %0  directory-or-file    [msr-options except : -f -l -PAC -r -p ]
    echo Example : %0  d:\lztool\msr.exe
    echo Example : %0  d:\lztool\           --nd "^(obj|target)$" --nf "log4net|Json|Razorvine"
    exit /b -1
)

set CheckPath=%1

where dumpbin.exe 2>nul >nul
if %ERRORLEVEL% GTR 0 (
    for /f "tokens=*" %%a in ('set VS ^| msr -it "^VS\d+COMNTOOLS=(.+?Visual Studio.+?)\\?$" -o "$1" -PAC -T 1') do (
        if exist "%%a\VsDevCmd.bat" call "%%a\VsDevCmd.bat" >nul
    )
)
where dumpbin.exe 2>nul >nul || (echo Not found dumpbin.exe | msr -PA -t "(dumpbin.exe)|\w+" & exit /b -1)

shift
for /F "tokens=*" %%f in ('msr -rp %CheckPath% -f "\.(dll|exe|lib)$" -PAC -l %* '); do (
    echo dumpbin.exe /headers %%f ^| msr -it "\s+machine\s*\(\s*\w*\d+\w*\s*\)" -PA
    dumpbin.exe /headers %%f | msr -PA -it "machine.*\d+"
)
