:: Get jstack blocks of specified process
@if "%PATH:~-1%" == "\" set "PATH=%PATH:~0,-1%"

@if [%1] == [] (
    echo Usage:   %0  Process_Name_Pattern
    echo Example: %0  MavenServer
    echo Example: %0  "\s+Kafka\s*$"
    echo Example: %0  "\s+Kafka\s*$" -H 30
    exit /b -1
)

:: jps | msr -it %1
@for /f "tokens=*" %%a in ('jps ^| msr -it %1 -PAC ^| msr -t "^(\d+)\s+.*" -o "$1" -PAC') do jstack -l %%a | msr -b "#\d+ prio=" -Q "^\s*$" %2 %3 %4 %5 %6 %7 %8 %9
