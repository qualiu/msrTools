@if %PATH:~-1%==\ set PATH=%PATH:~0,-1%

@echo off
where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%~dp0;%PATH%"

(for /f "tokens=*" %%a in ('msr -rp %~dp0 --nd \.git -f "\.(bat|cmd)$" --nf "check-.*.bat|detect-.*.bat|clean-git-objects.bat" -l -PAC') do @msr -p %%a -it "^\s*echo.*(Usage|Example)" -l -H 0) | msr -it "^Matched 0 lines.*?Source = (\S+.+?)\s*\.?\s*$" -o "$1" -PI -O -c Check batch scripts which has no usage and examples
