::===============================================
:: Find and disable specified exe files in PATH
::===============================================
@echo off

SetLocal EnableExtensions EnableDelayedExpansion

set msrExe=%~dp0msr.exe
::if not exist %msrExe% powershell -Command "Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0msr.exe"
::if not exist %msrExe% powershell -Command "(New-Object System.Net.WebClient).DownloadFile('https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true', '%~dp0msr.exe')"

if not exist %msrExe% powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0msr.exe"

if "%~1" == "" (
    echo Usage  : %~n0  ExeFilePattern     | %msrExe% -aPA -e "%~n0\s+(\S+).*"
    echo Example: %~n0  msr.exe            | %msrExe% -aPA -e "%~n0\s+(\S+).*"
    echo Example: %~n0  "^(msr|nin)\.exe$"       | %msrExe% -aPA -e "%~n0\s+(\S+).*"
    echo Example: %~n0  "^(msr|nin)\.exe$|psall.bat" | %msrExe% -aPA -e "%~n0\s+(\S+).*"
    exit /b -1
)

set ninExe=%~dp0nin.exe
if not exist %ninExe% powershell -Command "Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/nin.exe?raw=true -OutFile %~dp0nin.exe"

:: Dispaly files with exe pattern %1
%msrExe% -l -f "%~1" --wt --sz -p "%PATH%" 2>nul
if %ERRORLEVEL% EQU 0 exit /b 0

set "tmpPATH=%PATH%"
for /f "tokens=*" %%a in ('%msrExe% -l -f "%~1" -PAC 2^>nul -p "%PATH%" ^| %ninExe% nul "^([a-z]+.+?)[\\/][^\\/]*$" -iuPAC') do (
    :: echo Will remove in PATH: %%a
    for /f "tokens=*" %%b in ('%msrExe% -z "!tmpPATH!" -t "\\*\s*;\s*" -o "\n" -aPAC ^| %msrExe% --nx %%a -i -PAC ^| %msrExe% -S -t "[\r\n]+\s*(\S+)" -o ";$1" -aPAC ^| %msrExe% -S -t "\s+$" -o "" -aPAC') do (
        set "tmpPATH=%%b"
    )
)

EndLocal & set "PATH=%tmpPATH%"
