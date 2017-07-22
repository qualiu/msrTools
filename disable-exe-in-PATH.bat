::===============================================
:: Find and disable specified exe files in PATH
::===============================================
@echo off
where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%PATH%;%~dp0"

if "%~1" == "" (
    echo Usage  : %~n0  ExeFilePattern      | msr -aPA -e "%~n0\s+(\S+).*"
    echo Example: %~n0  msr.exe            | msr -aPA -e "%~n0\s+(\S+).*"
    echo Example: %~n0  "^msr\.exe$"       | msr -aPA -e "%~n0\s+(\S+).*"
    echo Example: %~n0  "^(msr|nin)\.exe$" | msr -aPA -e "%~n0\s+(\S+).*"
    exit /b -1
)

where nin.exe 2>nul >nul || if not exist %~dp0\nin.exe powershell -Command "Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/nin.exe?raw=true -OutFile %~dp0\nin.exe"
where nin.exe 2>nul >nul || set "PATH=%PATH%;%~dp0"

:: Dispaly files with pattern %1
msr -l -p "%PATH%" -f %1 --wt --sz -M 2>nul

for /f "tokens=*" %%a in ('msr -l -p "%PATH%" -f %1 -PAC 2^>nul ^| nin nul "^(.+)[\\/][^\\/]*$" -iuPAC') do (
    for /f "tokens=*" %%p in ('msr -z "%PATH%" -ix "%%a;" -o "" -aPAC 2^>nul') do set "PATH=%%p"
    msr -l -p "%PATH%" -f %1 -PAC >nul 2>nul || for /f "tokens=*" %%p in ('msr -z "%PATH%" -ix "%%a\\;" -o "" -aPAC 2^>nul') do set "PATH=%%p"
    msr -l -p "%PATH%" -f %1 -PAC >nul 2>nul || for /f "tokens=*" %%p in ('msr -z "%PATH%" -ix ";%%a\\" -o "" -aPAC 2^>nul') do set "PATH=%%p"
    msr -l -p "%PATH%" -f %1 -PAC >nul 2>nul || for /f "tokens=*" %%p in ('msr -z "%PATH%" -ix ";%%a" -o "" -aPAC 2^>nul') do set "PATH=%%p"
)
