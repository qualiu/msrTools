@echo off
if "%PATH:~-1%" == "\" set "PATH=%PATH:~0,-1%"
SetLocal EnableExtensions EnableDelayedExpansion

if "%~1" == "-h" (
    echo Usage:   %0  [SaveFolder] [IsForceCopyOrDownload ? 0 or 1]
    echo Example: %0  %~dp0
    echo Example: %0  %~dp0 1
    exit /b -1
)

if "%~1" == "" (
    set SaveFolder=%USERPROFILE%
) else (
    set SaveFolder=%~dp1%~nx1
)

if "%~2" == "" ( set /a IsForceCopyOrDownload=0 ) else ( set /a IsForceCopyOrDownload=%~2 )

if "%SaveFolder:~-1%" == "\" set "SaveFolder=%SaveFolder:~0,-1%"
if not exist !SaveFolder! md !SaveFolder!

echo "!PATH!" | findstr /I /L /C:"!SaveFolder!;" >nul || set "PATH=!SaveFolder!;!PATH!"
set /a HasCurl=0
set /a HasWget=0
where /q curl.exe && set /a HasCurl=1
where /q wget.exe && set /a HasWget=1

call :Download_File msr.exe || ( EndLocal &  exit /b -1 )
call :Download_File nin.exe || ( EndLocal &  exit /b -1 )
call :Download_File psall.bat || ( EndLocal &  exit /b -1 )
call :Download_File pskill.bat || ( EndLocal &  exit /b -1 )

EndLocal & set "PATH=%PATH%" & exit /b 0

:Download_File
    set name=%1
    for /f "tokens=*" %%a in ('where %name% 2^>nul') do (
        set oneSavePath=!SaveFolder!\%name%
        if %IsForceCopyOrDownload% EQU 1 (
            @REM if not /I "%%a" == "%oneSavePath%" copy /y %%a !SaveFolder!\
            echo %%a | findstr /I /C:"!oneSavePath!" >nul
            if !ERRORLEVEL! EQU 0 (
                @REM echo Skip existing !oneSavePath!
            ) else (
                @REM echo copy /y %%a !SaveFolder!\
                copy /y %%a !SaveFolder!\ > nul
            )
        )
        exit /b 0
    )
    if !HasCurl! EQU 1 (
        curl.exe https://github.com/qualiu/msr/raw/master/tools/%name% -o %name%.tmp --silent && move /y %name%.tmp %name% && icacls %name% /grant %USERNAME%:RX && move %name% !SaveFolder!\
    ) else if !HasWget! EQU 1 (
        wget.exe https://github.com/qualiu/msr/raw/master/tools/%name% -O %name%.tmp --no-check-certificate -q && move /y %name%.tmp %name% && icacls %name% /grant %USERNAME%:RX && move %name% !SaveFolder!\
    ) else (
        PowerShell -Command "$ProgressPreference = 'SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://github.com/qualiu/msr/raw/master/tools/%name%' -OutFile %name%.tmp" && move /y %name%.tmp %name% && icacls %name% /grant %USERNAME%:RX && move /y %name% !SaveFolder!\
    )

    where /q %name% && if %IsForceCopyOrDownload% EQU 0 copy /y %name% !SaveFolder!\
