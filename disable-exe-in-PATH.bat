::=============================================================
:: Find and disable specified EXE or BAT/CMD files in in PATH.
::
:: More scripts: https://github.com/qualiu/msrTools
::=============================================================
@echo off

SetLocal EnableExtensions EnableDelayedExpansion

set msrExe=%~dp0msr.exe

if not exist %msrExe% powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0msr.exe"

%msrExe% -z "NotFirstArg%~1" -t "^NotFirstArg(|-h|--help|/\?)$" >nul || (
    echo Usage  : %~n0  ExeFilePattern     | %msrExe% -aPA -e "%~n0\s+(\S+).*"
    echo Example: %~n0  msr.exe            | %msrExe% -aPA -e "%~n0\s+(\S+).*"
    echo Example: %~n0  "^(msr|nin)\.exe$"       | %msrExe% -aPA -e "%~n0\s+(\S+).*"
    echo Example: %~n0  "^(msr|nin)\.exe$|psall.bat" | %msrExe% -aPA -e "%~n0\s+(\S+).*"
    exit /b -1
)

set ninExe=%~dp0nin.exe
if not exist %ninExe% powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/nin.exe?raw=true -OutFile %~dp0nin.exe"

:: Display files with exe pattern %1
%msrExe% -l -f "%~1" --wt --sz 2>nul -M -p "%PATH%" && exit /b 0
for /f "tokens=*" %%a in ('msr -t "[^\.\w-]+$" -o ";" -aPAC -z "%PATH%" ^| %msrExe% -x "\;" -o ";" -aPAC') do set "tmpPATH=%%a"

for /f "tokens=*" %%a in ('%msrExe% -l -f "%~1" -PAC 2^>nul -p "%tmpPATH%" ^| %ninExe% nul "^([a-z]+.+?)[\\/][^\\/]*$" -iuPAC') do (
    REM echo Will remove folder in PATH: "%%a" | %msrExe% -aPA -t "(.+)"
    for /f "tokens=*" %%b in ('%msrExe% -z "!tmpPATH!" -t "\\*\s*;\s*" -o "\n" -aPAC ^| %msrExe% -x \\ -o \ -aPAC ^| %msrExe% --nx "%%a" -i -PAC ^| %ninExe% nul -uiPAC ^| %msrExe% -S -t "[\r\n]+(\S+)" -o ";$1" -aPAC ^| %msrExe% -S -t "\s+$" -o "" -aPAC') do (
        REM Removed folder in PATH: "%%a" | %msrExe% -aPA -e "(.+)"
        set "tmpPATH=%%b"
    )
)

:: %~dp0msr.exe -l -f "%~1" --wt --sz 2>nul -M -p "!tmpPATH!"
EndLocal & set "PATH=%tmpPATH%"
:: %~dp0msr.exe -z "%PATH%" | %~dp0msr.exe -t "Input string.*" -o "" -M -e \d+ -c %0
:: %~dp0msr.exe -z "%PATH%" -t "\\*\s*;\s*" -o "\n" -aPAC | %~dp0nin.exe nul "(\S+.+)" -uipd -k2 -c %0
exit /b 0
