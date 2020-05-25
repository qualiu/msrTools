:: ==================================================================================================
:: Auto detect latest or specific Visual Studio and initialize the environment.
:: Support clearing previous different environment variables.
::
:: If not found variables like VS150COMNTOOLS, Then find the Visual Studio link from start menu.
::
:: If need the older version on your machine, please manually initialize the older one at first.
::
:: More/Dependency scripts: https://github.com/qualiu/msrTools
:: ==================================================================================================
@if "%PATH:~-1%" == "\" set "PATH=%PATH:~0,-1%"

@echo off

where msr.exe /q || if not exist %~dp0\msr.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe /q || set "PATH=%~dp0;%PATH%;"

where nin.exe /q || if not exist %~dp0\nin.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/nin.exe?raw=true -OutFile %~dp0\nin.exe"
where nin.exe /q || set "PATH=%~dp0;%PATH%;"

:: Remove duplicate folders to avoid PATH value too long.
for /f "tokens=*" %%a in ('msr -z "!PATH!;" -t "\\*?\s*;\s*" -o "\n" -aPAC ^| nin nul "(\S+.+)" -uiPAC ^| msr -S -t "[\r\n]+(\S+)" -o ";\1" -PAC') do set "PATH=%%a"

msr -z "NotFirstArg%~1" -t "^NotFirstArg(-h|--help|/\?)$" >nul || (
    echo Usage: %0   [MustContainWordsForVisualStudio]
    echo Example: %0
    echo Example: %0  2019
    echo Example: %0  2017
    exit /b -1
)

if not "%~1" == "" (
    set MatchVSArgs=-ix "%~1"
    set MatchOtherVSArgs=--nx "%~1"
    call :Clear_Other_VS_Env || ( call :Clear_Tmp_Envs "%~dp0%~nx0" & exit /b -1 )
)

call :DetectAndCheckMatchWords && ( call :Clear_Tmp_Envs "%~dp0%~nx0" & exit /b 0 )

:: Get path like: C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Visual Studio 2017\Visual Studio Tools\Developer Command Prompt for VS 2017.lnk
for /f "tokens=*" %%a in ('msr -rp "%ProgramData%\Microsoft\Windows\Start Menu\Programs" -d "Visual Studio" -l -f "Develop.*Promp.*\.lnk$" -PAC ^| msr %MatchVSArgs% -s "[^\\]+?(\d+)[^\\]*$" -PAC -T 1') do (
    echo %%a | msr -aPA -e .+
    for /f "tokens=*" %%b in ('powershell -Command "(New-Object -COM WScript.Shell).CreateShortcut('%%a').Arguments" ^| msr %MatchVSArgs% -t "^\s*/\w+\s*" -o "" -PAC') do (
       :: Cannot direct call %%b , for VS2015 extra double quotes: ""C:\Program Files (x86)\Microsoft Visual Studio 14.0\Common7\Tools\VsDevCmd.bat""
       for /f "tokens=*"  %%c in ('echo %%~b') do (
          echo %%~c
          call "%%~c"
       )
    )
)

call :DetectAndCheckMatchWords && ( call :Clear_Tmp_Envs "%~dp0%~nx0" & exit /b 0 )

:: To avoid missing non-English link file name like: VS 2019的开发人员命令提示符.lnk
for /f "tokens=*" %%a in ('dir "%ProgramData%\Microsoft\Windows\Start Menu\Programs"\v*s*20*.lnk /S /B /O:D ^| nin nul "^(.+?)[^\\]+$" %MatchVSArgs% -uPAC -T 1') do (
    for /f "tokens=*" %%b in ('powershell -Command "[IO.directory]::GetFiles('%%a', '*.lnk') | ForEach-Object { (New-Object -COM WScript.Shell).CreateShortcut(\"$_\") }" ^| msr -it "\.(cmd|bat)" -PAC ^| msr -it ".*?\W([A-Z]:\\\w+.*?\.(bat|cmd)).*" -o "$1" -aPAC -s "(\d{2,}+\S*)" -T 1') do (
        echo %%~b
        call "%%~b"
    )
)

call :DetectAndCheckMatchWords && ( call :Clear_Tmp_Envs "%~dp0%~nx0" & exit /b 0 )


for /f "tokens=*" %%a in ('set VS ^| msr -it "^vs\d+\w+Tools=(.+?)\\?\s*$" -s "^(\w+)" -o "$1" -PAC -T 1') do (
    for /f "tokens=*" %%b in ('msr -p "%%a" -f "^(VsDevCmd|vsvar\w+)\.(cmd|bat)$" -l -PAC -H 1') do (
        echo %%b
        call "%%b"
    )
)

call :DetectAndCheckMatchWords && ( call :Clear_Tmp_Envs "%~dp0%~nx0" & exit /b 0 )

echo %~nx0: Not found Visual Studio environment with devenv.exe or msbuild.exe | msr -aPA -x "%~nx0" -it "(Not found.+)"

for /f "tokens=*" %%a in ('where msr.exe ^| msr -H 1 -PAC') do set "msrPath=%%a"
echo Please check whether Visual Studio exists in 'Start Menu' ^(Use %msrPath% if not found msr.exe^) by command below: | msr -aPA -e "Start Menu|(\S+.exe)" -t "Please.*?in"
echo msr -rp "%ProgramData%\Microsoft\Windows\Start Menu\Programs" -d "Visual Studio" -f "Develop.*\.lnk$" -l | msr -aPA -t "\s+(-\w+)" -e ".+"

call :Clear_Tmp_Envs "%~dp0%~nx0" & exit /b -1

:DetectAndCheckMatchWords
    set /a matchVsCount=0
    (where msbuild.exe 2>nul | msr -t "20\d+" %MatchVSArgs% -aPM >nul ) || set /a matchVsCount+=1
    (where devenv.exe 2>nul | msr -t "20\d+" %MatchVSArgs% -aPM >nul ) || set /a matchVsCount+=1
    if %matchVsCount% EQU 2 exit /b 0
    exit /b 1

:Clear_Other_VS_Env
    set /a otherVsCount=0
    (where msbuild.exe 2>nul | msr -t "20\d+" %MatchOtherVSArgs% -aPM >nul ) || set /a otherVsCount+=1
    (where devenv.exe 2>nul | msr -t "20\d+" %MatchOtherVSArgs% -aPM >nul ) || set /a otherVsCount+=1

    if %otherVsCount% GTR 0 (
        for /f "tokens=*" %%a in ('set ^| msr -it "^(DevEnvDir|CommandPromptType|VSINSTALLDIR|\w*VSCMD_\w+|VC\w+Dir|_*DOTNET\w+|INCLUDE|LIB|LIBPATH|VisualStudioVersion|NETFXSDKDir|VCTool\w+)=.*" -o "\1" -PAC') do set "%%a="
        echo call %~dp0\disable-exe-in-PATH.bat "^(msbuild|devenv)\.(exe|bat|cmd)$" | msr -aPA -e "(.+)"
        call %~dp0\disable-exe-in-PATH.bat "\b(msbuild|devenv)\.(exe|bat|cmd)$" || exit /b -1
    )
    exit /b 0

:Clear_Tmp_Envs
    for /f "tokens=*" %%a in ('nin %1 nul "\bset\s+(?:/a\s+)?(\w+)=" --nt "\bset\s+.?PATH=" -iuPAC') do set %%a=
    :: set | msr -t "VisualStudioVersion|NETFXSDKDir|UniversalCRTSdkDir|UCRTVersion|FSHARPINSTALLDIR|ExtensionSdkDir|WindowsSdk\w+|WindowsLib\w+|Framework\w+" -M -e "20\d{2}"
    :: where msbuild.exe & where devenv.exe
    call :Remove_Duplicates_in_PATH
    REM msr -z "%PATH%" -t "\\*\s*;\s*" -o "\n" -aPAC | nin nul "(\S+.+)" -uipd -k2
    REM msr -z "%PATH%" | msr -t "Input string.*" -o ""
    exit /b 0

:Remove_Duplicates_in_PATH
    for /f "tokens=*" %%a in ('msr -z "%PATH%" -t "\\*\s*;\s*" -o "\n" -aPAC ^| msr -x \\ -o \ -aPAC ^| nin nul -uiPAC ^| msr -S -t "[\r\n]+(\S+)" -o ";$1" -aPAC ^| msr -S -t "\s+$" -o "" -aPAC') do set "PATH=%%a"

    exit /b 0
