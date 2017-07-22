::====================================================
:: Check and warn DLL or EXE file platform bits.
::====================================================
@echo off
SetLocal EnableExtensions EnableDelayedExpansion

where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%PATH%;%~dp0"

if "%~1" == "" (
    echo Usage   : %0  directory-has-dll-exe-or-in-sub-directory
    echo Example : %0  d:\msgit\testMobius\csharp\testKeyValueStream\bin
    exit /b -1
)

set ToCheckDir=%1

rem Check x64/x86 compilation result count
echo %~dp0\check-dll-exe-x64-x86.bat %ToCheckDir% --nd "^(obj|target)$" --nf "log4net|Json|Razorvine|PowerArgs|.vshost.exe"
set /a mpCount=0
for /F "tokens=*" %%a in ('call %~dp0\check-dll-exe-x64-x86.bat %ToCheckDir% --nd "^(obj|target)$" --nf "log4net|Json|Razorvine|PowerArgs" ^| msr -S -it "\s*dumpbin.*?header\S*\s+(.+?\.(exe|dll|lib))\s+.*?[\r\n]+\s*(\S+[^\r\n]*machine[^\r\n]*)" -o "$3 : $1\n" -PAC ^| nin nul "machine\s*\(\s*(\w+)\s*\)" -iuw -M') do (
    set /a mpCount+=1
    echo %%a | msr -PA -ie "machine|(x64|x86)|([^\\\\/]+\.\w+)\s*$" --nt "\.bat"
)

if %mpCount% EQU 1 ( echo Checked ok, found only 1 type, example as above. & exit /b 0 )
if %mpCount% EQU 0 ( echo Not found dll/exe/lib in %ToCheckDir% & exit /b 0 )

rem Warn if inconsistent
echo XXXXXX Found %mpCount% types, inconsistent XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
exit /b %mpCount%
