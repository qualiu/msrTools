::======================================================================
::Find dependents for an exe or DLL. Only displays first level dependents if Save-Directory not provided.
::Principle:
::Step-1: Find dumpbin.exe : %PATH%; environment variables like VS120COMNTOOLS/VS150COMNTOOLS.
::Step-2: Dump dependents and grep them.
::Step-3: Exit if Save-Directory not provided or SaveDirectory is empty; Otherwise, recursively find the dependents.
::======================================================================

@if "%PATH:~-1%" == "\" set "PATH=%PATH:~0,-1%"

@echo off
SetLocal EnableExtensions EnableDelayedExpansion

where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%PATH%;%~dp0"

if "%~1" == "" (
    echo Usage  : %~n0  Exe-or-DLL-Path           [Save-Directory]   [Dependents-Directories: Optional; Separated by comma ','] | msr -e %~n0 -aPA -t "Exe-or-DLL-Path|(Save-Directory|(Dependents-Directories))"
    echo Example: %~n0  C:\Windows\System32\Robocopy.exe | msr -aPA -e %~n0 -t "\S+Robocopy.exe|(\S+tmp\S+|(\S+bin\s*$))"
    echo Example: %~n0  D:\cygwin64\bin\curl.exe  d:\tmp\curl-all    D:\cygwin64\bin       | msr -aPA -e %~n0 -t "\S+curl.exe|(\S+tmp\S+|(\S+bin\s*$))"
    echo Example: %~n0  D:\cygwin64\bin\curl.exe  "" "d:\cygwin64\bin,c:\Windows\System32" | msr -aPA -e %~n0 -t "\S+curl.exe|\s+(\W{2}(?=\s+)|(\S+bin,\S+))"
    echo Default Dependents-Directory = Exe-Directory , for the above examples, is D:\cygwin64\bin | msr -aPA -t "Exe-\S+|((Dependents-Directory|\S+bin))"
    echo Only displays first level dependents if Save-Directory not provided. | msr -aPA -it "Only.*first level|(Save-Directory)"
    exit /b -1
)

set ExeOrDLLPath=%1
set SaveDirectory=%2
set DependentsDirectories=%3

if "%~3" == "" for /f "tokens=*" %%a in ('msr -z %ExeOrDLLPath% -t "\\[^\\]+$" -o "" -PAC') do set DependentsDirectories="%%a"

where dumpbin.exe 2>nul >nul
if %ERRORLEVEL% GTR 0 (
    for /f "tokens=*" %%a in ('set VS ^| msr -it "^VS\d+COMNTOOLS=(.+?Visual Studio.+?)\\?$" -o "$1" -PAC -T 1') do (
        if exist "%%a\VsDevCmd.bat" call "%%a\VsDevCmd.bat" >nul
    )
)
where dumpbin.exe 2>nul >nul || (echo Not found dumpbin.exe | msr -PA -t "(dumpbin.exe)|\w+" & exit /b -1)


if "%~2" == "" (
    :: call dumpbin.exe /DEPENDENTS %ExeOrDLLPath% | msr --nt "^Dump of" -t "^\s*(\S+.*\.dll)\s*$" -o "$1" -PA
    echo ---- First level dependents of %ExeOrDLLPath% ---------------- | msr -PA -t "(First level)" -e "[\w\.-]+\.(dll|exe)"
    for /f "tokens=*" %%a in ('call dumpbin.exe /DEPENDENTS %ExeOrDLLPath% ^| msr --nt "^Dump of" -t "^\s*(\S+.*\.dll)\s*$" -o "$1" -PAC') do (
        for /f "tokens=*" %%p in ('msr -z "%%a" -t "[\.\$\+]" -o "\\$0" -PAC') do set "toFindFilePattern=%%p"
        :: echo toFindFilePattern=!toFindFilePattern! | msr -PA -e .+
        echo msr -l -f "^^!toFindFilePattern!$" -rp %DependentsDirectories% --wt --sz -PAC >nul
        msr -l -f "^^!toFindFilePattern!$" -rp %DependentsDirectories% --wt --sz -PAC 2>nul | msr -PA -e .+
        if !ERRORLEVEL! EQU 0 (
            echo %%a | msr -PA -t .+
        )
    )

    exit /b 0
)

if not exist %SaveDirectory% md %SaveDirectory%
if not exist %SaveDirectory%\%~nx1 (
    copy "%~1" %SaveDirectory%
)

echo ---- Dependents of %ExeOrDLLPath% ---------------- | msr -PA -e "[\w\.-]+\.(dll|exe)"
for /f "tokens=*" %%a in ('call dumpbin.exe /DEPENDENTS %ExeOrDLLPath% ^| msr --nt "^Dump of" -t "^\s*(\S+.*\.dll)\s*$" -o "$1" -PAC') do (
    for /f "tokens=*" %%p in ('msr -z "%%a" -t "[\.\$\+]" -o "\\$0" -PAC') do set "toFindFilePattern=%%p"
    ::echo toFindFilePattern=!toFindFilePattern!
    echo msr -l -f "^^!toFindFilePattern!$" -rp %DependentsDirectories% --wt --sz -PAC >nul
    msr -l -f "^^!toFindFilePattern!$" -rp %DependentsDirectories% --wt --sz -PAC 2>nul | msr -PA -e .+
    if !ERRORLEVEL! EQU 0 (
        echo %%a | msr -PA -t .+
    ) else (
        for /f "tokens=*" %%b in ('msr -l -f "^^!toFindFilePattern!$" -rp %DependentsDirectories% --wt --sz -PAC 2^>nul') do (
            for /f "tokens=*" %%c in ('msr -z %%b -t "^.+\\([^\\]+)$" -o "$1" -PAC') do set fileName=%%c
            if not exist %SaveDirectory%\!fileName! (
                copy "%%b" %SaveDirectory%
                call %0 "%%b" %SaveDirectory% %DependentsDirectories%
            )
        )
    )
)
