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

dir /b /A:D %TestRootDir%\app 2>nul | msr -it "^(kafka|spark|hadoop)" >nul
:: Skip Spark and Hadoop currently, so match count = 1 other than 3
if %ERRORLEVEL% GEQ 1 exit /b 0

powershell -f %TestRootDir%\init-download.ps1 -SkipHadoop -SkipSpark
if %ERRORLEVEL% NEQ 0 (
    echo init-download.ps1 return error = %ERRORLEVEL% | msr -aPA -t "error = (-?\d+)" -e "(\S+\.ps1)"
)

exit /b %ERRORLEVEL%

:DownloadGitTool
    set ToolName=%1
    where %ToolName% 2>nul >nul || if not exist %TestToolsDir%\%ToolName% powershell -Command "Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/%ToolName%?raw=true -OutFile %TestToolsDir%\%ToolName%"
    where %ToolName% 2>nul >nul || set "PATH=%TestToolsDir%;%PATH%"
