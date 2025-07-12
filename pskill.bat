::============================================================
:: Kill processes by their id or command line matching pattern.
:: Will show the processes info with colors before killing.
:: This scripts depends and will call psall.bat.
::
:: Latest version in: https://github.com/qualiu/msrTools/
::============================================================
@echo off
SetLocal EnableDelayedExpansion
set "PsToolPath=%~dp0\PsTool.ps1" && for /f "tokens=*" %%a in ("%PsToolPath%") do set "PsToolPath=%%~dpa%%~nxa"
where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true' -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%~dp0;%PATH%;"
where PsTool.ps1 >nul 2>nul || if not exist "!PsToolPath!" powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/qualiu/msrTools/master/PsTool.ps1' -OutFile '!PsToolPath!'"
where PsTool.ps1 >nul 2>nul || set "PATH=%PATH%;%~dp0;"

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

echo %* | msr -t "(^|\s+)(-[PACIMO]+|-[UDHT]\s*\d+|-c\s*.*)" -o "" -aPAC | msr -t "^\d+[\d ]*$" >nul
set /a IsAllNumbersAsPIDs=!ERRORLEVEL!

msr -z justTestArgs %* -P >nul 2>nul
if !ERRORLEVEL! NEQ -1 set NoPathToPsAll=-P

msr -z justTestArgs %* -A >nul 2>nul
if !ERRORLEVEL! NEQ -1 set NoInfoToPsAll=-A

where taskkill.exe >nul 2>nul
if !ERRORLEVEL! EQU 0 ( set /a HasTaskKill=1 ) else ( set /a HasTaskKill=0 )

where pwsh.exe >nul 2>nul
if !ERRORLEVEL! EQU 0 ( set "PwshExe=pwsh" ) else ( set "PwshExe=PowerShell" )

set "PIDs="
if !IsAllNumbersAsPIDs! GTR 0 (
    for /f "tokens=*" %%a in ('echo %* ^| msr -t "\s+(\d+)" -o ",\1" -aPAC ^| msr -t "\s+$" -o "" -aPAC') do (
        call !PwshExe! -Command "& '!PsToolPath!' -Ids '%%a' -Action Stop"
    )
    exit /b !ERRORLEVEL!
)

set ALL_ARGS=
:reset_all_args
    if "%~1"=="" goto args_done
    set "currentArg=%~1"
    if "!currentArg:~0,2!"=="-H" ( shift & if "!currentArg!"=="-H" shift & goto reset_all_args )
    if "!currentArg:~0,2!"=="-T" ( shift & if "!currentArg!"=="-T" shift & goto reset_all_args )
    if "!currentArg:~0,6!"=="--head" ( shift & shift & goto reset_all_args )
    if "!currentArg:~0,6!"=="--tail" ( shift & shift & goto reset_all_args )
    :: Check if found argument has special characters that need to be quoted (with double quotes):
    set needQuotes=0
    set "noQuoteArg=!currentArg:"=!"
    if "!noQuoteArg!" NEQ "!currentArg!" set needQuotes=1
    if !needQuotes! EQU 0 (
        echo "!noQuoteArg!"| findstr >nul /R "^[0-9a-zA-Z+.,\-\"]*$"
        if !ERRORLEVEL! NEQ 0 set needQuotes=1
    )

    if !needQuotes! EQU 1 (
        set ALL_ARGS=!ALL_ARGS! "!currentArg!"
    ) else (
        set ALL_ARGS=!ALL_ARGS! !currentArg!
    )
    shift
    goto reset_all_args

:args_done

:: Parse msr arguments for PsTool.ps1
set "PsToolArgs=-Action Stop"
set "ArgNamesPattern=has-text|text-match|ignore-case|nx|nt|colors|out-all|no-any-info|no-path-line|no-summary|head|tail"
for /f "tokens=1,*" %%a in ('msr -z justTestArgs %* --verbose 2^>^&1 ^| msr -t "^([\s-]+)(!ArgNamesPattern!) = (.+)" -o "\1\2\t\3" -PAC') do (
    echo %%a | findstr /R "^--" >nul && set "prefix=--" || set "prefix="
    set "name=%%a" & set "name=!name:--=!" & set "name=!name: =!"
    set "value=%%b"
    if "!name!" == "has-text" set "PsToolArgs=!PsToolArgs! -MatchAllText '!value!'"
    if "!name!" == "text-match" set "PsToolArgs=!PsToolArgs! -MatchAllPattern '!value!'"
    if "!name!" == "nx" set "PsToolArgs=!PsToolArgs! -ExcludeAllText '!value!'"
    if "!name!" == "nt" set "PsToolArgs=!PsToolArgs! -ExcludeAllPattern '!value!'"
    if "!name!" == "ignore-case" set "PsToolArgs=!PsToolArgs! -IgnoreCase !value!"
    if "!name!" == "colors" set "ColorsArg=!value!"
    if "!name!" == "out-all" set "OutAll=!value!"
    if "!name!" == "no-path-line" set "NoPathRow=!value!"
    if "!name!" == "no-any-info" set "NoAnyInfo=!value!"
    if "!name!" == "no-summary" set "NoSummary=!value!"
    if "!name!" == "head" if "!prefix!" == "--" set "PsToolArgs=!PsToolArgs! -Head !value!"
    if "!name!" == "tail" if "!prefix!" == "--" set "PsToolArgs=!PsToolArgs! -Tail !value!"
)

if "!ColorsArg!" == "" ( set "ColorsArg=--colors u=Yellow,m=Green" ) else ( set "ColorsArg=" )
if "!OutAll!" == "false" set "ColorsArg=!ColorsArg! -a"

if "!NoPathRow!" == "false" (
    set "ColorsArg=!ColorsArg! -P"
) else (
    set "PsToolArgs=!PsToolArgs! -NoHeader true"
)

if "!NoAnyInfo!" == "false" (
    set "ColorsArg=!ColorsArg! -A"
) else (
    set "PsToolArgs=!PsToolArgs! -NoSummary true"
    if "!NoPathRow!" == "false" set "PsToolArgs=!PsToolArgs! -NoHeader true"
)

if "!NoSummary!" == "false" (
    set "ColorsArg=!ColorsArg! -M"
) else (
    set "PsToolArgs=!PsToolArgs! -NoSummary true"
)

msr -z "!NoAnyInfo! !NoPathRow! !NoSummary!" -it true -M -H 0 || set "PsToolArgs=!PsToolArgs! -OutToStderrForHeaderSummary true"

@REM echo !PwshExe! -Command "& '!PsToolPath!' !PsToolArgs!" ^| msr !ALL_ARGS! !ColorsArg!
call !PwshExe! -Command "& '!PsToolPath!' !PsToolArgs!" | msr !ALL_ARGS! !ColorsArg!
exit /b !ERRORLEVEL!
