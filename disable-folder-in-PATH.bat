::===============================================
:: Find and disable specified exe files in PATH
::===============================================
@if %PATH:~-1%==\ set PATH=%PATH:~0,-1%

@echo off

SetLocal EnableExtensions EnableDelayedExpansion

set msrExe=%~dp0msr.exe
if not exist %msrExe% powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0msr.exe"

%msrExe% -z "NotFirstArg%~1" -t "^NotFirstArg(|-h|--help|/\?)$" > nul
if !ERRORLEVEL! NEQ 0 (
    echo Usage  : %~n0  Folder
    echo Example: %~n0  d:\app\anaconda3
    echo Example: %~n0  d:\cygwin7\bin
    echo You can check PATH after done by command: msr -z "%%PATH%%" -t "\\*\s*;\s*" -o "\n" -aPAC ^| nin nul "(\S+.+)" -ui
    exit /b -1
)

set ninExe=%~dp0nin.exe
if not exist %ninExe% powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/nin.exe?raw=true -OutFile %~dp0nin.exe"

set "tmpPATH=%PATH%"
for /f "tokens=*" %%a in ('%msrExe% -z "%PATH%" -t "\\*\s*;\s*" -o "\n" -aPAC ^| %ninExe% nul "(\S+.+)" -ui --nx "%~1" -PAC ^| msr -S -t "[\r\n]+(\S+)" -o ";$1" -PAC') do (
    set "tmpPATH=%%a"
)

EndLocal & set "PATH=%tmpPATH%"
