::========================================================================
:: Check unused methods or methods called more than 2 times in *.vue files.
:: Latest version in: https://github.com/qualiu/msrTools/
::========================================================================
@if "%PATH:~-1%" == "\" set "PATH=%PATH:~0,-1%"

@echo off
SetLocal EnableExtensions EnableDelayedExpansion

where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%PATH%;%~dp0"

msr -z "NotFirstArg%~1" -t "^NotFirstArg(|-h|--help|/\?)$" > nul
if !ERRORLEVEL! NEQ 0 (
    echo Usage:   %0  Vue_files_folders  [Check_CallTimes]^(default: 0^)  [Need_Show_Detail]^(default: 0^)
    echo Example: %0  src\Frontend
    echo Example: %0  src\Frontend 1
    echo Example: %0  src\Frontend 0 1
    echo Check_CallTimes = 0 : Check unused methods.
    echo Check_CallTimes = 1 : Check methods called more than 1 times.
    exit /b -1
)

set Vue_files_folders=%1
set Check_CallTimes=%2
set Need_Show_Detail=%3

if [%Check_CallTimes%] == [1] (
    call :Check_Methods computed methods called more than 1 times.
    exit /b !ERRORLEVEL!
) else (
    call :Check_Methods computed methods called more than 1 times.
    set /a count=!ERRORLEVEL!
    call :Check_Methods methods which unused.
    set /a count+=!ERRORLEVEL!
    exit /b !count!
)

:Check_Methods
set /a foundCount=0
set KeyWords=%~1
set Opt1=-p %%a -b "^\s*%KeyWords%:\s*\{" -Q "^\s*</script>|^\s*\w+:\s*\{\s*$" -t "^\s*(\w+)\s*\(.*$" -o "$1" -PAC
set Opt2=-PICc --nt "\b(if|else|for|while)\b"
for /f "tokens=*" %%a in ('msr -l -f "\.vue$" -rp %Vue_files_folders% -PAC') do (
    if [%Need_Show_Detail%] == [1] msr %Opt1% | msr %Opt2%
    :: %%b is computed method name
    for /f "tokens=*" %%b in ('msr %Opt1% ^| msr %Opt2%') do (
        set Opt3=-p %%a -t "\b%%b\b" -q "^\s*</script>" --nt "console\.\w+\s*\("
        if [%Need_Show_Detail%] == [1] ( msr !Opt3! ) else ( msr !Opt3! > nul )
        if [%Check_CallTimes%] == [1] (
            if !ERRORLEVEL! GTR 2 (
                echo.
                echo Found method %%b in %%a was probably called more than 1 times. | msr -aPA -t "Found .*?method (\S+) (in) (\S+) |(.+)"
                echo msr !Opt3!
                msr !Opt3!
                echo.
                set /a foundCount+=1
            )
        ) else (
            if !ERRORLEVEL! LSS 2 (
                echo.
                echo Found unused method %%b in %%a | msr -aPA -t "Found .*?method (\S+) (in) (\S+) |(.+)"
                echo msr !Opt3!
                msr !Opt3!
                echo.
                set /a foundCount+=1
            )
        )
    )
)

echo Found !foundCount! %*
exit /b !foundCount!
