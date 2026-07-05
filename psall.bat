:: ############################################################################
:: This tool is to find all process by the searching options of the process:
::  ParentProcessId ProcessId Name CommandLine
:: The script automatically excludes itself and related tool processes
::  (msr.exe, psall.bat, pskill.bat, PsTool.ps1) from results.
::
:: Add -kill to stop the matched processes directly (like pskill.bat), e.g.
::  psall.bat -it "edg\S+exe" -kill
::
:: Output line format, separated by TAB: ParentProcessId ProcessId Name CommandLine
:: [1]: Default: :RowNumber: ParentProcessId ProcessId Name CommandLine
:: [2]: With -P: ParentProcessId ProcessId Name CommandLine
::
:: IMPORTANT: Copy ps*.bat and PsTool.ps1 to the same PATH directory, e.g. the directory returned by: where psall.bat
:: Latest version in: https://github.com/qualiu/msrTools/
:: ############################################################################

@echo off
SetLocal EnableExtensions EnableDelayedExpansion

set "PsToolPath=%~dp0\PsTool.ps1" && for /f "tokens=*" %%a in ("%PsToolPath%") do set "PsToolPath=%%~dpa%%~nxa"
where pwsh.exe >nul 2>nul
if !ERRORLEVEL! EQU 0 ( set "PwshExe=pwsh" ) else ( set "PwshExe=PowerShell" )
where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true' -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%~dp0;%PATH%;"
where PsTool.ps1 >nul 2>nul || if not exist "!PsToolPath!" powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/qualiu/msrTools/master/PsTool.ps1' -OutFile '!PsToolPath!'"
where PsTool.ps1 >nul 2>nul || set "PATH=%PATH%;%~dp0;"

msr -z "LostArg%~1" -t "^LostArg(|-h|--help|/\?)$" > nul || (
    echo To see msr.exe matching options just run: msr --help | msr -PA -ie "options|\S*msr\S*" -x msr
    echo Usage  : %~n0 -t/-x "process-match-options"  -e "to-enhance"  -H "header-lines", ... -P, etc. | msr -aPA -e "\s+-+\w+\s+|-[txP]" -x %~n0
    echo Example: %~n0 -H 9 -T 9 -P  | msr -aPA -e "\s+-+\w+\s+" -x %~n0
    echo Example: %~n0 -it C:\\Windows --nx msr.exe | msr -PA -e "\s+-\w\s+" | msr -aPA -e "\s+-+\w+\s+" -x %~n0
    echo Example: %~n0 -ix C:\Windows -t "java.*" -H 3 --nx C:\Windows\system32 --nt msr\.exe | msr -aPA -e "\s+-+\w+\s+" -x %~n0
    exit /b 0
)

:: Rebuild msr args without wrapper-only flags before validation.
set "ShowDescendantsArg="
set "IsKill=0"
set "MsrArgs="
set "NextArgIsValue=0"
call :collect_msr_args %*
goto collect_msr_args_done

:collect_msr_args
    if "%~1"=="" exit /b 0
    set "currentArg=%~1"
    if "!NextArgIsValue!"=="1" (
        set MsrArgs=!MsrArgs! "!currentArg!"
        set "NextArgIsValue=0"
    ) else if /I "!currentArg!"=="-SD" (
        set "ShowDescendantsArg=-ShowDescendants true"
    ) else if /I "!currentArg!"=="-kill" (
        if "%~2"=="" ( set "IsKill=1" ) else ( set MsrArgs=!MsrArgs! "!currentArg!" )
    ) else (
        set MsrArgs=!MsrArgs! "!currentArg!"
        call :set_next_arg_is_value "!currentArg!"
    )
    shift
    goto collect_msr_args

:set_next_arg_is_value
    set "optionArg=%~1"
    if /I "!optionArg!"=="-t" set "NextArgIsValue=1"
    if /I "!optionArg!"=="-x" set "NextArgIsValue=1"
    if /I "!optionArg!"=="-it" set "NextArgIsValue=1"
    if /I "!optionArg!"=="-ix" set "NextArgIsValue=1"
    if /I "!optionArg!"=="-e" set "NextArgIsValue=1"
    if /I "!optionArg!"=="-H" set "NextArgIsValue=1"
    if /I "!optionArg!"=="-T" set "NextArgIsValue=1"
    if /I "!optionArg!"=="--text-match" set "NextArgIsValue=1"
    if /I "!optionArg!"=="--has-text" set "NextArgIsValue=1"
    if /I "!optionArg!"=="--nx" set "NextArgIsValue=1"
    if /I "!optionArg!"=="--nt" set "NextArgIsValue=1"
    if /I "!optionArg!"=="--head" set "NextArgIsValue=1"
    if /I "!optionArg!"=="--tail" set "NextArgIsValue=1"
    if /I "!optionArg!"=="--colors" set "NextArgIsValue=1"
    exit /b 0

:collect_msr_args_done

set "OnlyNumbers="
for /f "tokens=*" %%a in ('echo !MsrArgs! ^| msr -I -t "^\s*\x22?\d+\x22?(\s+\x22?\d+\x22?)*\s*$" -PAC') do set "OnlyNumbers=1"
if "!OnlyNumbers!"=="1" (
    echo %~n0 needs -t "regex" or -x "plain" ^(or -it/-ix^); use %~dp0pskill.bat PID for process id. | msr -aPA -e "\s+-+\w+|PID|-it|-ix|pskill" -x %~n0
    exit /b -1
)

:: Test args for msr.exe
msr -z justTestArgs !MsrArgs! >nul 2>nul
if %ERRORLEVEL% LSS 0 (
    echo Invalid %~nx0 args: %* | msr -aPA -e "Invalid|args" -x %~nx0
    msr -z justTestArgs !MsrArgs!
    exit /b -1
)

where pwsh.exe >nul 2>nul
if !ERRORLEVEL! EQU 0 ( set "PwshExe=pwsh" ) else ( set "PwshExe=PowerShell" )

:: -kill path: map msr's resolved options to PsTool Stop arguments.
if "!IsKill!"=="1" (
    set "PsToolArgs=-Action Stop"
    if defined ShowDescendantsArg set "PsToolArgs=!PsToolArgs! !ShowDescendantsArg!"
    set "HasMatch=0"
    set "ArgNamesPattern=has-text|text-match|ignore-case|nx|nt|head|tail"
    call :parse_msr_args_for_pstool
    if "!HasMatch!"=="0" (
        echo %~n0 -kill needs -t "regex" or -x "plain" ^(or -it/-ix^) to match processes. Nothing killed. | msr -aPA -e "\s+-+\w+|-kill|-it|-ix" -x %~n0
        exit /b -1
    )
    call !PwshExe! -NoProfile -Command "& '!PsToolPath!' !PsToolArgs!"
    exit /b !ERRORLEVEL!
)

set ALL_ARGS=
:reset_all_args
    if "%~1"=="" goto args_done
    set "currentArg=%~1"
    if /I "!currentArg!"=="-SD" ( shift & goto reset_all_args )
    if /I "!currentArg!"=="-kill" if "%~2"=="" ( shift & goto reset_all_args )
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
set "PsToolArgs=-Action Find"
if defined ShowDescendantsArg set "PsToolArgs=!PsToolArgs! !ShowDescendantsArg!"
set "ArgNamesPattern=has-text|text-match|ignore-case|nx|nt|colors|out-all|no-any-info|no-path-line|no-summary|head|tail"
call :parse_msr_args_for_pstool

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
    set "NoSummaryAdded=1"
    if "!NoPathRow!" == "false" set "PsToolArgs=!PsToolArgs! -NoHeader true"
)

if "!NoSummary!" == "false" (
    set "ColorsArg=!ColorsArg! -M"
) else (
    if not "!NoSummaryAdded!" == "1" set "PsToolArgs=!PsToolArgs! -NoSummary true"
)

msr -z "!NoAnyInfo! !NoPathRow! !NoSummary!" -it true -M -H 0 || set "PsToolArgs=!PsToolArgs! -OutToStderrForHeaderSummary true"

@REM echo !PwshExe! -NoProfile -Command "& '!PsToolPath!' !PsToolArgs!" ^| msr !ALL_ARGS! !ColorsArg!
call !PwshExe! -NoProfile -Command "& '!PsToolPath!' !PsToolArgs!" | msr !ALL_ARGS! !ColorsArg!
exit /b !ERRORLEVEL!

:parse_msr_args_for_pstool
    for /f "tokens=1,*" %%a in ('msr -z justTestArgs !MsrArgs! --verbose 2^>^&1 ^| msr -t "^([\s-]+)(!ArgNamesPattern!) = (.+)" -o "\1\2\t\3" -PAC') do (
        set "prefix="
        set "name=%%a"
        if "!name:~0,2!" == "--" set "prefix=--"
        set "name=!name:--=!" & set "name=!name: =!"
        set "value=%%b"
        set "value=!value:'=''!"
        if "!name!" == "has-text" ( set "PsToolArgs=!PsToolArgs! -MatchAllText '!value!'" & set "HasMatch=1" )
        if "!name!" == "text-match" ( set "PsToolArgs=!PsToolArgs! -MatchAllPattern '!value!'" & set "HasMatch=1" )
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
    for /f "tokens=1,*" %%a in ('msr -z justTestArgs !MsrArgs! --verbose 2^>^&1 ^| msr -t "^(-[txi]) = (.+)" -o "\1\t\2" -PAC') do (
        set "value=%%b"
        set "value=!value:'=''!"
        if "%%a" == "-t" ( set "PsToolArgs=!PsToolArgs! -MatchAllPattern '!value!'" & set "HasMatch=1" )
        if "%%a" == "-x" ( set "PsToolArgs=!PsToolArgs! -MatchAllText '!value!'" & set "HasMatch=1" )
        if "%%a" == "-i" set "PsToolArgs=!PsToolArgs! -IgnoreCase true"
    )
    exit /b 0
