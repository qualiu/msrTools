:: ==================================================================================================
:: Auto detect and use latest Visual Studio from environment variables like: VS150COMNTOOLS
::    VS110COMNTOOLS=C:\Program Files (x86)\Microsoft Visual Studio 11.0\Common7\Tools\
::    VS120COMNTOOLS=C:\Program Files (x86)\Microsoft Visual Studio 12.0\Common7\Tools\
::    VS140COMNTOOLS=C:\Program Files (x86)\Microsoft Visual Studio 14.0\Common7\Tools\
::    VS150COMNTOOLS=C:\Program Files (x86)\Microsoft Visual Studio\2017\Enterprise\Common7\Tools\
:: If not found variables like VS150COMNTOOLS,
::  Then find the Visual Studio link from start menu.
::
:: If need the older version on your machine, please manually initialize the older one at first.
:: ==================================================================================================
@echo off

( where msbuild.exe 2>nul >nul && where devenv.exe 2>nul >nul ) && exit /b 0

where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%~dp0;%PATH%"

:: To avoid missing non-English link file name like: VS 2019的开发人员命令提示符.lnk
for /f "tokens=*" %%a in ('dir "%ProgramData%\Microsoft\Windows\Start Menu\Programs"\v*s*20*.lnk /S /B /O:D ^| nin nul "^(.+?)[^\\]+$" -uPAC -T 1') do (
    for /f "tokens=*" %%b in ('powershell -Command "[IO.directory]::GetFiles('%%a', '*.lnk') | ForEach-Object { (New-Object -COM WScript.Shell).CreateShortcut(\"$_\").Arguments }" ^| msr -t "^\s*/\w+\s*(.+\.(bat|cmd)\W*$)" -o "$1" -PAC -T 1') do call "%%~b"
)

( where msbuild.exe 2>nul >nul && where devenv.exe 2>nul >nul ) && exit /b 0

:: Get path like: C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Visual Studio 2017\Visual Studio Tools\Developer Command Prompt for VS 2017.lnk
for /f "tokens=*" %%a in ('msr -rp "%ProgramData%\Microsoft\Windows\Start Menu\Programs" -d "Visual Studio" -l -f "Develop.*\.lnk$" -PAC ^| msr -s "[^\\]+?(\d+)[^\\]*$" -PAC -T 1') do (
    for /f "tokens=*" %%b in ('powershell -Command "(New-Object -COM WScript.Shell).CreateShortcut('%%a').Arguments" ^| msr -t "^\s*/\w+\s*" -o "" -PAC') do (
       :: Cannot direct call %%b , for VS2015 extra double quotes: ""C:\Program Files (x86)\Microsoft Visual Studio 14.0\Common7\Tools\VsDevCmd.bat""
       for /f "tokens=*"  %%c in ('echo %%~b') do call "%%~c"
    )
)

( where msbuild.exe 2>nul >nul && where devenv.exe 2>nul >nul ) && exit /b 0

for /f "tokens=*" %%a in ('set VS ^| msr -it "^vs\d+\w+Tools=(.+?)\\?\s*$" -s "^(\w+)" -o "$1" -PAC -T 1') do (
    for /f "tokens=*" %%b in ('msr -p "%%a" -f "^(VsDevCmd|vsvar\w+)\.(cmd|bat)$" -l -PAC -H 1') do (
        call "%%b"
    )
)

( where msbuild.exe 2>nul >nul && where devenv.exe 2>nul >nul ) && exit /b 0

echo %~nx0: Not found Visual Studio environment with devenv.exe or msbuild.exe | msr -aPA -x "%~nx0" -it "(Not found.+)"

for /f "tokens=*" %%a in ('where msr.exe ^| msr -H 1 -PAC') do set "msrPath=%%a"
echo Please check whether Visual Studio exists in 'Start Menu' ^(Use %msrPath% if not found msr.exe^) by command below: | msr -aPA -e "Start Menu|(\S+.exe)" -t "Please.*?in"
echo msr -rp "%ProgramData%\Microsoft\Windows\Start Menu\Programs" -d "Visual Studio" -f "Develop.*\.lnk$" -l | msr -aPA -t "\s+(-\w+)" -e ".+"

exit /b -1
