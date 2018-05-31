@echo off
where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%~dp0;%PATH%"

for /f "tokens=*" %%a in ('msr -rp %~dp0 -f "\.bat" -it "\b(msr|nin)\s+.+" -l -PAC') do (
    msr -p %%a -it powershell.*SecurityProtocol.*OutFile >nul && echo %%a | msr -aPA -x %%a
)
