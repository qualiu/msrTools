::==============================================================================
:: Download and install portable Cygwin into a specified diretory, no pollution.
::
:: Latest version in: https://github.com/qualiu/msrTools/
::==============================================================================

@if "%PATH:~-1%" == "\" set "PATH=%PATH:~0,-1%"

@echo off
SetLocal EnableExtensions EnableDelayedExpansion

where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%PATH%;%~dp0"

where nin.exe 2>nul >nul || if not exist %~dp0\nin.exe powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/nin.exe?raw=true -OutFile %~dp0\nin.exe"
where nin.exe 2>nul >nul || set "PATH=%PATH%;%~dp0"

msr -z "NotFirstArg%~1" -t "^NotFirstArg(|-h|--help|/\?)$" > nul || (
    echo Usage  : %0  Save_Directory   [Extra_Packages]  [Just_Display_Command]  [Download_Cache_Directory]  [Default_Packages] | msr -aPA -t Extra_Packages -e "(Default_Packages)" -x Save_Directory
    echo Example: %0  D:\app\cygwin64 | msr -aPA -x D:\app\cygwin64
    echo Example: %0  D:\app\cygwin64  "git,sed,nc,putty,rsh,perl"     | msr -aPA -t "\S*git\S+" -e "(\S+)\s*$" -x D:\app\cygwin64
    echo Example: %0  D:\app\cygwin64  "openssh,rsync,expect"  1  ""  "" | msr -aPA -t "\S*openssh\S+" -e "(\S+)\s*$" -x D:\app\cygwin64
    echo Example: %0  D:\app\cygwin64  "openssh,rsync,expect,dos2unix,unix2dos,egrep"   1  D:\app\cygwin64-download-cache  "wget,autossh,rsync,curl,cygwin32-binutils" | msr -aPA -t "\S*openssh\S+" -e "(\S+)\s*$" -x D:\app\cygwin64
    echo All packages see: https://cygwin.com/packages/package_list.html
    echo If you just want to install Cygwin plus ssh + rsync + expect: | msr -aPA -e .+ -t "ssh|rsync|expect"
    echo          %0  D:\app\cygwin64  "openssh,rsync,expect"  0  ""  ""  | msr -aPA -t "\S*openssh\S+" -e "(\S+)\s*$" -x D:\app\cygwin64
    echo.
    msr -p %0 -t "^if.*?set.*?Default_Packages=(.+)?.$" -o "\1" -PAC | msr -t "," -o "\n" -PAC | msr -t "\w+" >nul
    echo Default !ERRORLEVEL! packages to merge with Extra_Packages: | msr -aPA -x Default -t Extra_Packages -e "!ERRORLEVEL!|(packages)"
    msr -p %0 -t "^if.*?set.*?Default_Packages=(.+)?.$" -o "\1" -PAC | msr -aPA -e "(.+)"
    echo.
    echo Default Download_Cache_Directory = %%Save_Directory%%-download-cache | msr -aPA -x Default -e Save_Directory
    exit /b -1
)

set Save_Directory=%~dp1%~nx1
if %Save_Directory:~-1%==\ set Save_Directory=%Save_Directory:~0,-1%
if [%5] == [] if not defined Default_Packages set "Default_Packages=wget,gawk,grep,dos2unix,unix2dos,egrep,gcc-g++,bash,vim,gvim,zip,unzip,gzip,cmake,make,openssh,cgdb,gdb,gperf,bzip2,rsync,autossh,tar,expect,curl,clang,diffutils,cygutils,cygwin,duff,less,binutils,cygwin32-gcc-g++,cygwin32-gcc-core,cygwin32-binutils,cygwin32"

:: git,git-clang-format,gedit,lz4,nc,perl,php,putty,pv,pwgen,screen,rstart,rsh,run,sed,shed,
if "%~2" == "" (
    set Packages=%Default_Packages%
) else (
    ::Remove double quotes
    if not [!Default_Packages!] == [] (
        :: Remove quotes
        set Default_Packages=%Default_Packages:"=%
        for /f "tokens=*" %%a in ('msr -z !Default_Packages! -t "\s+" -o "" -aPAC') do set "Default_Packages=%%a"
        set "Default_Packages=,!Default_Packages!"
    )
    for /f "tokens=*" %%a in ('msr -z "%~2!Default_Packages!" -t "\s*,\s*" -o "\n" -aPAC ^| nin nul -iuPAC ^| msr -S -t "[\r\n]+\s*(\S+)" -o ",$1" -aPAC ^| msr -t ",\W*$" -o "" -aPAC ') do set Packages="%%a"
)

set Just_Display_Command=%3
msr -z !Packages! -t "," -o "\n" -PAC | msr -t "\w+" >nul
set /a PackageCount=!ERRORLEVEL!
echo !PackageCount! Packages=!Packages!| msr -aPA -ie "Packages=(.+)" -t !PackageCount!

if "%~4" == "" (
    set Download_Cache_Directory=%Save_Directory%-download-cache
) else (
    set Download_Cache_Directory=%~dp3%~nx3
)

:: --download  --verbose --no-shortcuts --no-startmenu --no-desktop  --prune-install
set OtherOptions=--no-admin --quiet-mode --no-shortcuts --no-startmenu --no-desktop  --prune-install --site http://cygwin.mirror.constant.com/

set ThisDir=%~dp0
if %ThisDir:~-1%==\ set ThisDir=%ThisDir:~0,-1%
set DownloadsDirectory=%ThisDir%\..\downloads
if not exist %DownloadsDirectory% md %DownloadsDirectory%

for /f "tokens=*" %%a in ("%DownloadsDirectory%\cygwin-setup-x86_64.exe") do set cygwin64_setup_exe=%%~dpa%%~nxa

if exist %cygwin64_setup_exe%.tmp del %cygwin64_setup_exe%.tmp
if not exist %cygwin64_setup_exe% powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri https://www.cygwin.com/setup-x86_64.exe -OutFile %cygwin64_setup_exe%.tmp" && move %cygwin64_setup_exe%.tmp %cygwin64_setup_exe%

echo. & echo Install Cygwin command line: | msr -aPA -e .+
echo %cygwin64_setup_exe% --root %Save_Directory% --local-package-dir %Download_Cache_Directory% --packages !Packages! --arch x86_64 %OtherOptions% | msr -aPA -x %Save_Directory% -ie "--packages\s+(\S+)" -t "\s+-+\w+\S*"

msr -it "\w+" -z "!Packages!" >nul
if !ERRORLEVEL! EQU 0 echo No packages. | msr -aPA -t "(.+)"  & exit /b -1
if "%Just_Display_Command%" == "1" exit /b 0

%cygwin64_setup_exe% --root %Save_Directory% --local-package-dir %Download_Cache_Directory% --packages !Packages! --arch x86_64 %OtherOptions%
echo.
echo To use Linux utilities: Add %Save_Directory%\bin to %%PATH-PP- or temporarily: SET "PATH=%%PATH-PP-;%Save_Directory%\bin" | msr -x -PP- -o "%%" -PAC | msr -aPA -e "(To use \w+ \w+)|\S+" -x %Save_Directory%\bin -t "(SET\s+\S*PATH=\S+)"
echo Please intialize or enter Cygwin by running: "%Save_Directory%\Cygwin.bat" | msr -aPA -t "(Please.*running)" -x "%Save_Directory%\Cygwin.bat"
start "Initialize Cygwin in %Save_Directory%" %Save_Directory%\Cygwin.bat
