::============================================================
:: Kill processes by their id or command line matching pattern.
:: Will show the processes info with colors before killing.
:: This scripts depends and will call psall.bat.
::
:: Latest version in: https://github.com/qualiu/msrTools/
::============================================================
@echo off

SetLocal EnableDelayedExpansion
where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%~dp0;%PATH%"

msr -z "LostArg%~1" -t "^LostArg(|-h|--help|/\?)$" > nul || (
    echo To see msr.exe matching options just run: msr --help | msr -PA -ie "options|\S*msr\S*" -x msr
    echo Usage   : %~n0  process-match-options or process-id-list | msr -PA -e "option\w*|\b(id)\b" -x %~n0
    echo Example : %~n0  -i -t "java.*-X\S+|cmd.exe" -x C:\Windows --nx Windows\System32 ---- kill processes by commandline matching | msr -PA -e "\s+-+\w+|msr" -x %~n0
    echo Example : %~n0    -it "java.*-X\S+|cmd.exe" -x C:\Windows --nx Windows\System32 --nt msr\.exe ---- kill processes by commandline matching | msr -PA -e "\s+-+\w+|msr" -x %~n0
    echo Example : %~n0  2030 3021 19980          ---- kill processes by id | msr -PA -e "\s+(\d+|\bid\b)" -x %~n0
    :: echo Should not use -P -A -C and their combination. | msr -PA -t "(-[PAC]+)|\w+"
    exit /b 0
)

:: Test args for msr.exe
msr -z justTestArgs %* >nul 2>nul
if %ERRORLEVEL% LSS 0 (
    echo Error parameters for %~nx0: %* , test with: -z justTestArgs: | msr -aPA -t "Error.*for (\S+)" -e "test with"
    msr -z justTestArgs %*
    exit /b -1
)

:: ==================================================================================
:: set allArgs=%*
:: set allArgs=%allArgs:|= %
:: set allArgs=%allArgs:"=%
:: for /f "delims=0123456789 " %%a in ("%allArgs%") do set NotAllNumbersAsPIDs=true
:: ==================================================================================

echo %* | msr -t "(^|\s+)(-[PACIMO]+|-[UDHT]\s*\d+|-c\s*.*)" -o "" -aPAC | msr -t "[^\d ]" >nul
if !ERRORLEVEL! GTR 0 set NotAllNumbersAsPIDs=true

msr -z justTestArgs %* -P >nul 2>nul
if !ERRORLEVEL! NEQ -1 set NoPathToPsAll=-P

msr -z justTestArgs %* -A >nul 2>nul
if !ERRORLEVEL! NEQ -1 set NoInfoToPsAll=-A

call psall.bat %* !NoPathToPsAll! -c Before killing processes %~nx0 calls psall.bat to check and display.

if !ERRORLEVEL! LSS 1 exit /b !ERRORLEVEL!

where taskkill.exe >nul 2>nul
if !ERRORLEVEL! EQU 0 ( set /a HasTaskKill=1 ) else ( set /a HasTaskKill=0 )

set PIDs=
if "!NotAllNumbersAsPIDs!" == "true" (
    if !HasTaskKill! EQU 1 (
        for /f "tokens=*" %%a in ('call psall.bat %* !NoPathToPsAll! !NoInfoToPsAll! ^| msr -t "^\d+\t(\d+).*" -o "/pid \1" -PAC ^| msr -S -t "\s+" -o " " -aPAC') do set PIDs=%%a
    ) else (
        for /f "tokens=*" %%a in ('call psall.bat %* !NoPathToPsAll! !NoInfoToPsAll! ^| msr -t "^\d+\t(\d+).*" -o " \1" -PAC ^| msr -S -t "\s+" -o "," -aPAC') do set PIDs=%%a
    )
) else (
    if !HasTaskKill! EQU 1 (
        for /f "tokens=*" %%a in ('echo %* ^| msr -t "\s+(\d+)" -o " /pid $1" -aPAC') do set PIDs=%%a
    ) else (
        for /f "tokens=*" %%a in ('echo %* ^| msr -t "\s+(\d+)" -o ",$1" -aPAC') do set PIDs=%%a
    )
)

:: Only call taskkill if has PID - numbers
echo !PIDs! | msr -t "\d+" >nul
if !ERRORLEVEL! EQU 0 exit /b 0
if !HasTaskKill! EQU 1 (
    @REM echo taskkill /f !PIDs!
    taskkill /f !PIDs!
) else (
    @REM echo PowerShell -Command "Stop-Process -Id !PowerShellPIDs! -Force -ErrorAction SilentlyContinue"
    where pwsh.exe >nul 2>nul
    if !ERRORLEVEL! EQU 0 (
        pwsh.exe -Command "Stop-Process -Id !PowerShellPIDs! -Force -ErrorAction SilentlyContinue"
    ) else (
        PowerShell -Command "Stop-Process -Id !PowerShellPIDs! -Force -ErrorAction SilentlyContinue"
    )
)
