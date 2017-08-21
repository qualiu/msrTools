::=========================================================
:: Set PATH and variables for Kafka, Hadoop and Spark, to directly call their commands.
::=========================================================
@echo off
if "%~1" == "-h"        goto :ShowUsage
if "%~1" == "--help"    goto :ShowUsage
if "%~1" == "/?"        goto :ShowUsage

SetLocal EnableExtensions EnableDelayedExpansion
:: if DisplayVariables=1 will display PATH and variables.
set "DisplayVariables=%1"

:: if ForceCheck=1 will check, ignore existing settings.
set "ForceCheck=%2"

:: Skip Spark and Hadoop for now
set "SkipSpark=%3"
set "SkipHadoop=%4"

call %~dp0\check-tools.bat

if not "%SkipSpark%" == "0" set "ArgsForInitDownloading=-SkipSpark"
if not "%SkipHadoop%" == "0" set "ArgsForInitDownloading=!ArgsForInitDownloading! -SkipHadoop"

powershell -f %TestRootDir%\init-download.ps1 !ArgsForInitDownloading!
if !ERRORLEVEL! NEQ 0 (
    echo init-download.ps1 return error = !ERRORLEVEL! | msr -aPA -t "error = (-?\d+)" -e "(\S+\.ps1)"
)

if !ERRORLEVEL! NEQ 0 exit /b !ERRORLEVEL!

for /f "tokens=*" %%a in ('msr -z "%~dp0\app" -x \\ -o \ -aPAC') do set "AppRootDir=%%a"

:: Get Hadoop directory
::for /f "tokens=*" %%a in ('dir /S /B /A:D %AppRootDir% ^| msr -it "(.*\\Hadoop[^\\]*)\\bin.*$" -o "$1" -PAC') do set "HADOOP_HOME=%%a"
for /f "tokens=*" %%a in ('msr -l -rp %AppRootDir% --pp hadoop.*bin -PAC -H 1 -J ^| msr -it "(.*\\Hadoop[^\\]*)\\bin.*$" -o "$1" -PAC') do set "HADOOP_HOME=%%a"

:: Get Spark directory
::for /f "tokens=*" %%a in ('dir /S /B /A:D %AppRootDir% ^| msr -it "(.*\\Spark[^\\]*)\\bin.*$" -o "$1" -PAC') do set "SPARK_HOME=%%a"
for /f "tokens=*" %%a in ('msr -l -rp %AppRootDir% --pp "spark.*bin" -f spark-submit -H 1 -J -PAC ^| msr -it "(.*\\Spark[^\\]*)\\bin.*$" -o "$1" -PAC') do set "SPARK_HOME=%%a"

::for /f "tokens=*" %%a in ('dir /S /B /A:D %AppRootDir% ^| msr -it "(.*\\Kafka[^\\]*)\\bin\\windows.*$" -o "$1" -PAC') do set "KAFKA_HOME=%%a"
for /f "tokens=*" %%a in ('msr -l -rp %AppRootDir% --pp kafka.*bin.*windows -PAC -H 1 -J ^| msr -it "(.*\\Kafka[^\\]*)\\bin\\windows.*$" -o "$1" -PAC') do set "KAFKA_HOME=%%a"

if [%SkipHadoop%] == [] if not exist "%HADOOP_HOME%" set "SkipHadoop=1"
if [%SkipSpark%] == [] if not exist "%SPARK_HOME%" set "SkipSpark=1"

if not "%ForceCheck%" == "1" (
    if exist "%KafkaBin%" if exist "%HadoopBin%" if exist "%SparkBin%" (
        rem found all existing settings
        if "%DisplayVariables%" == "1" call :DisplayAll
        exit /b 0
    )
)

:: Get Kafka bin directory of Windows platform
if "%KAFKA_HOME%" == "" (
    echo Not found Kafka, please check Kafka existence. | msr -aPA -t .+
    exit /b -1
)

set "KafkaBin=%KAFKA_HOME%\bin\windows"
set "KafkaConfigDir=%KAFKA_HOME%\config"

:: Clear any existing kafka or hdfs directories in %PATH%

:: call :Clean_ExeDir_In_PATH_Except kafka-server-start %KafkaBin%
call :Clean_ExeDir_In_PATH_Except kafka-server-start
call :Add_ExeDir_To_PATH %KafkaBin%

if not "%SkipHadoop%" == "1" (
    if "%HADOOP_HOME%" == "" (
        echo Not found Hadoop, please check Hadoop existence. | msr -aPA -t .+
        exit /b -1
    )
    
    set "HadoopBin=%HADOOP_HOME%\bin"
    set "HadoopSBin=%HADOOP_HOME%\sbin"
    set "HadoopConfigDir=%HADOOP_HOME%\etc\hadoop"
    
    :: Clear another existing kafka or hdfs directories in %PATH%, except the ones to set.
    call :Clean_ExeDir_In_PATH_Except hdfs.cmd
    call :Clean_ExeDir_In_PATH_Except start-yarn.cmd
    
    call :Add_ExeDir_To_PATH !HadoopBin!
    call :Add_ExeDir_To_PATH !HadoopSBin!
)

if not "%SkipSpark%" == "1" (
    if "%SPARK_HOME%" == "" (
        echo Not found Spark, please check Spark existence. | msr -aPA -t .+
        exit /b -1
    )

    set "SparkBin=%SPARK_HOME%\bin"
    :: call :Clean_ExeDir_In_PATH_Except spark-submit.cmd %SparkBin%
    call :Clean_ExeDir_In_PATH_Except spark-submit.cmd
    call :Add_ExeDir_To_PATH !SparkBin!
)


::Remove redundant ;
for /f "tokens=*" %%a in ('msr -z "%PATH%" -t "\s*;[\s;]*" -o ";" -aPAC') do set "PATH=%%a"

::Remove duplicated pathes in %PATH% to shorten the length of %PATH%
for /f "tokens=*" %%a in ('msr -z "%PATH%" -t "\\?\s*;[;\s]*" -o "\n" -PAC ^| nin nul -iuPAC ^| msr -S -t "(\S+)[\r\n]+" -o "$1;" -PAC') do set "PATH=%%a"

::Set brokers for some test script files
for /f "tokens=*" %%a in ('msr -p %KafkaConfigDir% -f "^server-?\d*\.properties$" -it "^\s*port\s*=\s*(\d+).*" -o "$1" -PAC ^| msr -t "\d+" -o "localhost:$0" -PAC ^| msr -S -t "\s+(\S+)" -o ",$1" -aPAC') do set "KafkaBrokers=%%a"
if "%DisplayVariables%" == "1" (
    :: EndLocal & call :Set_Variables & call :DisplayAll
    EndLocal & set "HADOOP_HOME=%HADOOP_HOME%" & set "SPARK_HOME=%SPARK_HOME%" & set "KAFKA_HOME=%KAFKA_HOME%" & set "PATH=%PATH%" & set "KafkaBin=%KafkaBin%" & set "SparkBin=%SparkBin%" & set "HadoopBin=%HadoopBin%" & set "HadoopSBin=%HadoopSBin%" & set "KafkaConfigDir=%KafkaConfigDir%" & call :DisplayAll
) else (
    :: EndLocal & call :Set_Variables
    EndLocal & set "HADOOP_HOME=%HADOOP_HOME%" & set "SPARK_HOME=%SPARK_HOME%" & set "KAFKA_HOME=%KAFKA_HOME%" & set "PATH=%PATH%" & set "KafkaBin=%KafkaBin%" & set "SparkBin=%SparkBin%" & set "HadoopBin=%HadoopBin%" & set "HadoopSBin=%HadoopSBin%" & set "KafkaConfigDir=%KafkaConfigDir%"
)

exit /b 0
    
:: ==========================================================================
:: Will use return value of msr.exe at bellow instead of %ERRORLEVEL%
:: because not use SetLocal EnableDelayedExpansion, cannot use !ERRORLEVEL!
:: ==========================================================================

:: Input a path : %1, check and add it to %PATH%
:Add_ExeDir_To_PATH
    :: Not add the directory which is %1, if there's no exe/bat/cmd file.
    msr -l -f "\.(exe|bat|cmd)$" -p %1 -PAC >nul
    if !ERRORLEVEL! EQU 0 (
        echo Needless to add to PATH as no exe/bat/cmd found in %1. | msr -aPA -e \w+ -x %1
        exit /b 0
    )
    
    :: if %ERRORLEVEL% EQU 0 exit /b 0
    :: Add to %PATH% if directory %1 not in %PATH%
    :: msr -z "%PATH%" -ix "%1;" -PAC > nul && set "PATH=%PATH%;%1;"
    
    msr -z "%PATH%" -ix "%1;" -PAC > nul
    if !ERRORLEVEL! EQU 0 (
        :: Check PATH length, prepend it if it will exceed the limit.
        msr -z "%PATH%;%1;" > nul
        if !ERRORLEVEL! LSS 2048 ( set "PATH=%PATH%;%1;" ) else ( set "PATH=%1;%PATH%;")
    )
    
    msr -z "%PATH%" -ix %1 -PA >nul && (echo Failed to add %1 to PATH && exit /b -1)
    
    exit /b 0

:: Input exe-name and directory, check and remove other locations in %PATH%, by where exe
:Clean_ExeDir_In_PATH_Except
    for /f "tokens=*" %%a in ('where %1 2^>nul ^| msr -t "\\[^\\]+$" -o "" -aPAC') do (
        if /I "%%a" == "%2" (
            rem Keep, not remove %%a May have 1 redundant at most.
        ) else (
            :: Check and remove %%a; in PATH, if found, not check and remove ;%%a
            msr -z "%PATH%" -ix "%%a;" -o "" -PAC >nul || ( ( for /f "tokens=*" %%p in ('msr -z "%PATH%" -ix "%%a;" -o "" -aPAC') do set "PATH=%%p" ) & exit /b 0 )
            :: Check and remove ;%%a in PATH
            msr -z "%PATH%" -ix ";%%a" -o "" -PAC >nul && for /f "tokens=*" %%p in ('msr -z "%PATH%" -ix ";%%a" -o "" -aPAC') do set "PATH=%%p"
        )
    )
    exit /b 0
    
:DisplayAll
    set | msr -PA  -it "^(spark\w*|hadoop\w*|kafka\w*|(PATH))=(\S+)" -e "[^;]*(spark|hadoop|kafka|winutils)[^;]*"
    exit /b 0
 
:ShowUsage
    echo Usage   : %0 [DisplayVariables] [ForceCheck] [SkipSpark] [SkipHadoop]
    echo Example : %0
    echo Example : %0  1  0
    echo Example : %0  1  1  1  1
    exit /b -1
