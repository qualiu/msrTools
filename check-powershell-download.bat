@echo off
where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%~dp0;%PATH%"

msr -z "X%~1" -it "^X(|-h|--help|/\?)$" >nul
if !ERRORLEVEL! EQU 1 (
    echo Usage:   %0  IsPreview
    echo Example: %0  1
    echo Example: %0  0
    exit /b -1
)

:: Replace if not preview
if "%~1" == "0" (
    msr -rp %~dp0 -f "\.bat$"  --nt "SecurityProtocol" -x OutFile -it "Invoke-WebRequest" -o "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $0" -e Command -R
) else (
    msr -rp %~dp0 -f "\.bat$"  --nt "SecurityProtocol" -x OutFile -it "Invoke-WebRequest" -o "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $0" -e Command
)
