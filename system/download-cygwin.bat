::======================================================================
::Download a portable Cygwin in specified diretory
::======================================================================

@echo off
SetLocal EnableExtensions EnableDelayedExpansion

if "%~1" == "" (
    echo Usage  : %~n0  Save_Directory   [Packages]                 [Just_Display_Command]  [Download_Cache_Directory]      [DefaultPackages]
    echo Example: %~n0  D:\tmp\cygwin64
    echo Example: %~n0  D:\tmp\cygwin64  "openssh,rsync"  1  "" ""
    echo Example: %~n0  D:\tmp\cygwin64  "dos2unix,unix2dos,egrep"   1  D:\tmp\cygwin64-download-cache  "wget,autossh,rsync,curl,cygwin32-binutils"
    echo Packages see: https://cygwin.com/packages/package_list.html
    echo If you just want to install ssh and rsync: %~n0  D:\tmp\cygwin64  "openssh,rsync" 0 "" "" | msr -PA -ie "If you.*?:|(\w*ssh|rsync)" -x %~n0 -t D:\S+
    exit /b -1
)

where msr.exe 2>nul >nul || if not exist %~dp0\msr.exe powershell -Command "Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile %~dp0\msr.exe"
where msr.exe 2>nul >nul || set "PATH=%PATH%;%~dp0"

where nin.exe 2>nul >nul || if not exist %~dp0\nin.exe powershell -Command "Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/nin.exe?raw=true -OutFile %~dp0\nin.exe"
where nin.exe 2>nul >nul || set "PATH=%PATH%;%~dp0"

set Save_Directory=%~dp1%~nx1
if %Save_Directory:~-1%==\ set Save_Directory=%Save_Directory:~0,-1%
if [%5] == [] if not defined DefaultPackages set "DefaultPackages=wget,gawk,grep,dos2unix,unix2dos,egrep,gcc-g++,bash,vim,gvim,zip,unzip,gzip,cmake,make,openssh,cgdb,gdb,gperf,bzip2,rsync,autossh,tar,expect,curl,clang,diffutils,cygutils,cygwin,duff,less,binutils,cygwin32-gcc-g++,cygwin32-gcc-core,cygwin32-binutils,cygwin32"

:: git,git-clang-format,gedit,lz4,nc,perl,php,putty,pv,pwgen,screen,rstart,rsh,run,sed,shed,
if "%~2" == "" (
    set Packages=%DefaultPackages%
) else (
    ::Remove double quotes
    if not [!DefaultPackages!] == [] (
        :: Remove quotes
        set DefaultPackages=%DefaultPackages:"=%
        for /f "tokens=*" %%a in ('msr -z !DefaultPackages! -t "\s+" -o "" -aPAC') do set "DefaultPackages=%%a"
        set "DefaultPackages=,!DefaultPackages!"
    )
    for /f "tokens=*" %%a in ('msr -z "%~2!DefaultPackages!" -t "\s*,\s*" -o "\n" -aPAC ^| nin nul -iuPAC ^| msr -S -t "[\r\n]+\s*(\S+)" -o ",$1" -aPAC ^| msr -t ",\W*$" -o "" -aPAC ') do set Packages="%%a"
)

set Just_Display_Command=%3
echo Packages=!Packages!| msr -aPA -ie "(Packages)=(.+)"

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

set cygwin64_setup_exe=%DownloadsDirectory%\cygwin-setup-x86_64.exe

if not exist %cygwin64_setup_exe% powershell -Command "Invoke-WebRequest -Uri https://www.cygwin.com/setup-x86_64.exe -OutFile %cygwin64_setup_exe%"

echo %cygwin64_setup_exe% --root %Save_Directory% --local-package-dir %Download_Cache_Directory% --packages !Packages! --arch x86_64 %OtherOptions% | msr -aPA -x %cygwin64_setup_exe% -ie "\w+"

msr -it "\w+" -z "!Packages!" >nul
if !ERRORLEVEL! EQU 0 echo No packages. | msr -aPA -t "(.+)"  & exit /b -1

if "%Just_Display_Command%" == "1" exit /b 0

%cygwin64_setup_exe% --root %Save_Directory% --local-package-dir %Download_Cache_Directory% --packages !Packages! --arch x86_64 %OtherOptions%
echo Please intialize or enter Cygwin by running: "%Save_Directory%\Cygwin.bat" | msr -aPA -t "(Please.*running)" -x "%Save_Directory%\Cygwin.bat"
