@echo off
SetLocal EnableExtensions EnableDelayedExpansion

where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%PATH%;%~dp0"

msr -z "X%~1" -it "^X(|-h|--help|/\?)$" >nul
if !ERRORLEVEL! EQU 1 (
    echo Usage:    Restart_AppPool_Sites  [Restart_IIS_Admin]^(default: 1^)  [Restart_WMSVC_AppHostSvc_W3SVC_WAS]^(default: 1^)
    echo Example:  1
    echo Example:  0  1
    echo Example:  1  1  1
    echo This script should be run as administrator role.
    exit /b -1
)

set Restart_AppPool_Sites=%~1
set Restart_IIS_Admin=%~2
set Restart_WMSVC_AppHostSvc_W3SVC_WAS=%~3

whoami /groups | msr -ix BUILTIN\Administrators -t Enabled >nul
if %ERRORLEVEL% NEQ 1 (
    echo %~dp0%~nx0 should be run as administrator role. | msr -aPA -t "(\S+\.bat)(.+)"
    exit /b -1
)

if "%Restart_IIS_Admin%" == "1" (
    msr -z "NET STOP IISADMIN & NET START IISADMIN" -XM
    msr -z "IISReset /stop & IISReset /start" -XM
)

if "%Restart_WMSVC_AppHostSvc_W3SVC_WAS%" == "1" (
    REM msr -z "WMSVC AppHostSvc W3SVC WAS" -t "(\S+)" -o "Start-Service $1; " -PAC | msr -t .+ -o "Powershell -Command \"$0\" " -XM
    REM echo Powershell -command "Remove-Item -Recurse -Force C:\inetpub\temp\appPools\*" | msr -XM
    REM msr -z "WMSVC AppHostSvc W3SVC WAS" -t "(\S+)" -o "Stop-Service -Force $1; " -PAC | msr -t .+ -o "Powershell -Command \"$0\" " -XM
    msr -z "WMSVC AppHostSvc W3SVC WAS" -t "(\S+)" -o "NET STOP $1 & " -PAC | msr -t "&\s*$" -o "" -XM
    echo Powershell -command "Remove-Item -Recurse -Force C:\inetpub\temp\appPools\*" | msr -XM
    msr -z "WMSVC AppHostSvc W3SVC WAS" -t "(\S+)" -o "NET START $1 & " -PAC | msr -t "&\s*$" -o "" -XM
)

if "%Restart_AppPool_Sites%" == "1" (
    %systemroot%\system32\inetsrv\APPCMD list site | msr -it "^SITE (.+?)\s*\(.*"

    for /f "tokens=*" %%a in ('%systemroot%\system32\inetsrv\APPCMD list site ^| msr -it "^SITE (.+?)\s*\(.*" -o "$1" -PAC') do (
        echo %systemroot%\system32\inetsrv\APPCMD stop site /site.name:%%a | msr -XA
        echo %systemroot%\system32\inetsrv\APPCMD start site /site.name:%%a | msr -XA
        if !ERRORLEVEL! NEQ 0 (
            echo Failed to restart site %%a: %systemroot%\system32\inetsrv\APPCMD start site /site.name:%%a | msr -aPA -it "Failed.*?site (.+?)\s*:\s*(.+)"
        )
    )

    %systemroot%\system32\inetsrv\APPCMD list apppool | msr -it "^APPPOOL (.+?)\s*\(.*"

    for /f "tokens=*" %%a in ('%systemroot%\system32\inetsrv\APPCMD list apppool ^| msr -it "^APPPOOL (.+?)\s*\(.*" -o "$1" -PAC') do (
        echo %systemroot%\system32\inetsrv\APPCMD stop apppool /apppool.name:%%a | msr -XA
        echo %systemroot%\system32\inetsrv\APPCMD start apppool /apppool.name:%%a | msr -XA
        if !ERRORLEVEL! NEQ 0 (
            echo Failed to restart apppool %%a : %systemroot%\system32\inetsrv\APPCMD start apppool /apppool.name:%%a | msr -aPA -it "Failed.*?apppool (.+?)\s*:\s*(.+)"
        )
    )
)
