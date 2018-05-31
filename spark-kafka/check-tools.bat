:: Download basic tools for utility and killing/checking processes.
@echo off
set TestRootDir=%~dp0
if %TestRootDir:~-1%==\ set TestRootDir=%TestRootDir:~0,-1%

set TestToolsDir=%TestRootDir%\tools
if not exist %TestToolsDir% md %TestToolsDir%

call :DownloadGitTool msr.exe
call :DownloadGitTool psall.bat
call :DownloadGitTool pskill.bat
call :DownloadGitTool nin.exe

:DownloadGitTool
    set ToolName=%1
    where %ToolName% 2>nul >nul || if not exist %TestToolsDir%\%ToolName% powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/%ToolName%?raw=true -OutFile %TestToolsDir%\%ToolName%"
    where %ToolName% 2>nul >nul || set "PATH=%TestToolsDir%;%PATH%"
