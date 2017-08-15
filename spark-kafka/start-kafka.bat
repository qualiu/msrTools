::===============================================================
:: Check and start Kafka
::===============================================================

@echo off
SetLocal EnableExtensions EnableDelayedExpansion

set StopAtFirst=%1
if /I "%~1" == "true" set "StopAtFirst=1"

call %~dp0\set-path-variables.bat 1 || exit /b !ERRORLEVEL!

for /f "tokens=*" %%a in ('msr -z "%KAFKA_HOME%" -x \ -o \\ -PAC') do set "KAFKA_HOME_Pattern=%%a"

if "%StopAtFirst%" == "1" (
    call psall -it "%KAFKA_HOME_Pattern%" --nx msr.exe > nul
    if !ERRORLEVEL! GTR 0 call %~dp0\stop-kafka
)

set ZookeeperProcessPattern="%KAFKA_HOME_Pattern%\S+zookeeper-server-start.*config\\zookeeper.properties"

call psall -it "%ZookeeperProcessPattern%" --nx msr.exe > nul
if %ERRORLEVEL% EQU 0 (
    echo %KafkaBin%\zookeeper-server-start %KafkaConfigDir%\zookeeper.properties | msr -aPA -e "[\w-]+start|([\w\.-]+).properties"
    start %KafkaBin%\zookeeper-server-start %KafkaConfigDir%\zookeeper.properties
    ::powershell -Command "Start-Sleep -Seconds 5"
    ping 127.0.0.1 -n 5 -w 1000 > nul 2>nul
)

:: Wait for Zookeeper process.
for /L %%k in (1,1,5) do (
    call psall -it "%ZookeeperProcessPattern%" --nx msr.exe > nul
    if !ERRORLEVEL! GTR 0 (
       call :StartKafaProcess
       exit /b 0
    )
    ::powershell -Command "Start-Sleep -Seconds 3"
    ping 127.0.0.1 -n 3 -w 1000 > nul 2>nul
)


call :StartKafaProcess
exit /b !ERRORLEVEL!

:StartKafaProcess
    set /a kafkaServerNodeCount=0
    for /f "tokens=*" %%a in ('msr -p %KafkaConfigDir% -f "^server-?\d*\.properties$" -l -PAC') do (
        for /f "tokens=*" %%p in ('msr -z "%%a" -t ".*\\(server-?\d*.properties$)" -o "$1" -PAC') do (
            set oneKafkaConfig=%%p
            ::set killOneCmdPattern=-it "%KAFKA_HOME_Pattern%\S+kafka-server-start.+%%p" -x cmd.exe --nx msr.exe
            set killOneCmdPattern=-ix %KafkaConfigDir%\!oneKafkaConfig! -t cmd.exe --nx msr.exe
            set oneKafkaProcessPattern=-ix %KafkaConfigDir%\!oneKafkaConfig! -t java.exe --nx msr.exe
        )
        
        set /a kafkaServerNodeCount=!kafkaServerNodeCount!+1
        :: echo psall !oneKafkaProcessPattern!
        call psall !oneKafkaProcessPattern! > nul
        if !ERRORLEVEL! EQU 0 (
            :: Close possible dead cmd window
            call pskill !killOneCmdPattern! -M 2>nul
            echo %KafkaBin%\kafka-server-start %KafkaConfigDir%\!oneKafkaConfig! | msr -aPA -e "[\w-]+start|([\w\.-]+).properties"
            start %KafkaBin%\kafka-server-start %KafkaConfigDir%\!oneKafkaConfig!
            ::powershell -Command "Start-Sleep -Seconds 3"
            ping 127.0.0.1 -n 3 -w 1000 > nul 2>nul
        )
    )
    
    :: Wait for Kafka process nodes
    set KafkaProcessPattern=-it "%KAFKA_HOME_Pattern%\S+config\\server-?\d*.properties" -x java.exe --nx msr.exe
    ::echo kafkaServerNodeCount=!kafkaServerNodeCount!, KafkaProcessPattern=!KafkaProcessPattern!
    for /L %%k in (1,1,5) do (
        call psall %KafkaProcessPattern% > nul
        :: echo return=!ERRORLEVEL!, kafkaServerNodeCount=!kafkaServerNodeCount!
        if !ERRORLEVEL! GEQ !kafkaServerNodeCount! exit /b 0
        ::powershell -Command "Start-Sleep -Seconds 3"
        ping 127.0.0.1 -n 3 -w 1000 > nul 2>nul
    )
    
    exit /b -1
