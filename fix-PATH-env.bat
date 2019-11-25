::============================================================================================
:: Fix %PATH%:
:: (1) Tail slash caused future using %PATH% error like cannot find cmd.exe or powershell.exe
:: (2) Remove all redudant slashes in %PATH%
::============================================================================================

@if %PATH:~-1%==\ set PATH=%PATH:~0,-1%

@echo off
SetLocal EnableExtensions EnableDelayedExpansion

where cmd.exe /q 2>nul || set "PATH=C:\Windows;C:\Windows\system32;C:\Windows\System32\Wbem;%PATH%
where powershell /q || set "PATH=C:\windows\System32\WindowsPowerShell\v1.0;%PATH%

where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%PATH%;%~dp0"

where nin.exe 2>nul >nul || if not exist %~dp0\nin.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/nin.exe?raw=true -OutFile %~dp0\nin.exe"
where nin.exe 2>nul >nul || set "PATH=%PATH%;%~dp0"

for /f "tokens=*" %%a in ('msr -z "%PATH%" -t "\\*?\s*;\s*" -o "\n" -aPAC ^| nin nul "(\S+.+)" -ui -PAC ^| msr -S -t "[\r\n]+(\S+)" -o ";\1" -aPAC') do SET "PATH=%%a"

EndLocal & set "PATH=%PATH%"
