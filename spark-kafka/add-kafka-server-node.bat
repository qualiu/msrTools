::===============================================================
:: Add Kafka server nodes.
::===============================================================

@if "%PATH:~-1%" == "\" set "PATH=%PATH:~0,-1%"

@echo off
SetLocal EnableExtensions EnableDelayedExpansion

if "%~1" == "-h"        goto :ShowUsage
if "%~1" == "--help"    goto :ShowUsage
if "%~1" == "/?"        goto :ShowUsage
if "%~1" == ""          goto :ShowUsage

if "%~1" == "" ( set /a AddCount=1 ) else (set /a AddCount=%1)
if "%~2" == "" ( set /a PortBeginForAll=9092 ) else ( set /a PortBeginForAll=%2 )

call %~dp0\set-path-variables.bat 0 || exit /b !ERRORLEVEL!

:: Get current Newest broker id and file
for /f "tokens=*" %%a in ('msr -p %KafkaConfigDir% -f "^server-?\d*\.properties$" -it "^\s*broker.id\s*=\s*(\d+).*" -o "$1" -s "\d+" -PAC') do set /a NewestBrokerId=%%a
for /f "tokens=*" %%a in ('msr -p %KafkaConfigDir% -f "^server-?\d*\.properties$" -l -PAC ^| msr -s "[^\\/]+$" -PAC') do set NewestBrokerFile=%%a

:: Get newest port
for /f "tokens=*" %%a in ('msr -p %KafkaConfigDir% -f "^server-?\d*\.properties$" -it "^\s*port\s*=\s*(\d+).*" -o "$1" -s "\d+" -PAC -T 1') do set /a NewestPort=%%a
if "%NewestPort%" == "" (
    for /f "tokens=*" %%a in ('msr -p %KafkaConfigDir% -f "^server-?\d*\.properties$" -l -PAC ^| msr -s "[^\\/]+$" -PAC') do (
        msr -p %%a -S -t "(\S+)$" -o "$1\n" -H0 -R -c Check and add tail new line
        echo port=!PortBeginForAll! >> %%a
        set /a PortBeginForAll+=1
    )
    set /a NewestPort=!PortBeginForAll!-1
)

:: Copy to new broker files and update the properties
for /L %%k in (1,1,%AddCount%) do (
    set /a NewestBrokerId=!NewestBrokerId!+1
    set /a NewestPort=!NewestPort!+1
    set newConfig=%KafkaConfigDir%\server-!NewestBrokerId!.properties
    copy /y %NewestBrokerFile% !newConfig!
    msr -p !newConfig! -it "^(\s*broker.id)\s*=\s*(\d+)(.*)" -o "$1=!NewestBrokerId!$3" -R -c Update broker.id to !NewestBrokerId!
    msr -p !newConfig! -it "^(\s*port)\s*=\s*(\d+)(.*)" -o "$1=!NewestPort!$3" -R -c Update port to !NewestPort!
    msr -p !newConfig! -it "^(\s*log.dirs)\s*=\s*(\S+)\d*.*$" -o "$1=${2}-!NewestBrokerId!" -R -c Update log.dirs
)

exit /b 0

:ShowUsage
    echo Usage:   %0  [AddCount=1]  [PortBeginForAll=9092]
    echo Example: %0   1
    echo Example: %0   1  9092
    exit /b -1
