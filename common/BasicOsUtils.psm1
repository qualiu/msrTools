$Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding $False
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding

# Linux/MacOS should use $env:PATH, don't use $env:Path
# $IsWindows may not defined on Window PowerShell
$IsWindowsOS = $IsWindows -or $([Environment]::OSVersion.Platform -imatch '^Win|Windows')
$env:HOME = if ([string]::IsNullOrEmpty($env:HOME)) { $env:USERPROFILE } else { $env:HOME }
$SysPathEnvSeparator = if ($IsWindowsOS) { ';' } else { ':' }
$SysPathChar = if ($IsWindowsOS) { '\' } else { '/' }
$SysTmpFolder = if ($IsWindowsOS) { [System.IO.Path]::GetTempPath() } else { '/tmp/' }
$SysOutNull = if ($IsWindowsOS) { "nul" } else { "/dev/null" }
$TmpToolPackageFolder = if ($IsWindowsOS) { Join-Path $env:LOCALAPPDATA "ToolPackages" } else { Join-Path $SysTmpFolder "ToolPackages" }
$PushFolderCmd = if ($IsWindowsOS) { 'pushd' } else { 'cd' }
$SysUserName = if ([string]::IsNullOrEmpty($env:USERNAME)) { $env:USER } else { $env:USERNAME }
$SysHostName = if ([string]::IsNullOrEmpty($env:COMPUTERNAME)) { $(hostname) } else { $env:COMPUTERNAME }
$SysDomainName = if ($IsWindowsOS) { $env:USERDOMAIN } else { hostname -d } # { scutil --dns | msr -it "^.*?domain\S*\s*:\s*(\w+\.\S+).*" -o "\1" --nt "\d+\.\d+|\.\w\.\w" -H 1 -PAC 2>/dev/null }
$SysDnsDomain = if ($IsWindowsOS) { $env:USERDNSDOMAIN } else { hostname -f }
$PowerShellName = if ($IsWindowsOS) { 'powershell' } else { 'pwsh' }
$SudoInstallCmd = if ($IsMacOS) { "brew install" } elseif ($IsLinux) { 'sudo apt install -y' } else { 'choco install -y' }
$SudoUpdateCmd = if ($IsMacOS) { 'brew update' } elseif ($IsLinux) { 'sudo apt update -y' } else { '' }
$SysPathEnvSeparator = if ($IsWindowsOS) { ';' } else { ':' }
$SudoCmd = if ($IsWindowsOS) { '' } else { 'sudo' }
$CurlExeName = if ($IsWindowsOS) { 'curl.exe' } else { 'curl' }
$WgetExeName = if ($IsWindowsOS) { 'wget.exe' } else { 'wget' }
$DeleteFileCmd = if ($IsWindowsOS) { 'del' } else { 'rm' }
$ForceDeleteFileCmd = if ($IsWindowsOS) { 'del /f' } else { 'rm -f' }
$DeleteDirectoryCmd = if ($IsWindowsOS) { 'rd /s' } else { 'rm -r' }
$ForceDeleteDirectoryCmd = if ($IsWindowsOS) { 'rd /q /s' } else { 'rm -rf' }
$MsrKeepColorArg = "--keep-color"
$MsrOutStderrArg = "--to-stderr"
$MsrOutStderrWithColorArgs = @($MsrKeepColorArg, $MsrOutStderrArg)
$MsrWarnColorArgs = @("-e", "(((((.+)))))")

# Clear environment variables below to avoid unexpected errors, skip: 'MSR_NO_COLOR', 'MSR_NOT_WARN_BOM'
foreach ($envName in @('MSR_EXIT', 'MSR_OUT_INDEX', 'MSR_OUT_FULL_PATH', 'MSR_SKIP_LAST_EMPTY', 'MSR_KEEP_COLOR', 'MSR_UNIX_SLASH')) {
    [System.Environment]::SetEnvironmentVariable($envName, $null, [System.EnvironmentVariableTarget]::Process)
}

Write-Host -ForegroundColor Green "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz')) Please don't forget to check/pull updates of this script repo (Do re-enter PowerShell if *.psm1 files updated)."

function Test-IsLaunchedFromWindowsCMD {
    param (
        [Parameter(Mandatory = $true)] $MyInvocation
    )

    if (-not $IsWindowsOS) {
        return $false
    }

    $scriptName = [IO.Path]::GetFileName($MyInvocation.MyCommand.Path)
    psall.bat -ix PowerShell.exe -t "[\\/]$scriptName" --nx msr.exe -H 0 -PAC
    return $LASTEXITCODE -gt 0
}

function Get-EmptyTextForMsrReplace {
    param (
        [Parameter(Mandatory = $true)] $MyInvocation
    )

    if ($(Test-IsLaunchedFromWindowsCMD $MyInvocation) -or $($PSVersionTable.PSVersion.Major -lt 7)) {
        return "`"`""
    }
    else {
        return ""
    }
}

function Restore-EnvVars {
    param (
        [bool] $DebugReload = $False
    )
    $processEnvs = [System.Environment]::GetEnvironmentVariables([System.EnvironmentVariableTarget]::Process)
    $sysEnvs = [System.Environment]::GetEnvironmentVariables([System.EnvironmentVariableTarget]::Machine)
    $userEnvs = [System.Environment]::GetEnvironmentVariables([System.EnvironmentVariableTarget]::User)
    $pathValueSet = New-Object System.Collections.Generic.HashSet[String]([StringComparer]::OrdinalIgnoreCase)
    $allPathValues = $($processEnvs['Path'] + ';' + $sysEnvs['Path'] + ';' + $userEnvs['Path']) -Split '\\*\s*;\s*'
    foreach ($path in $allPathValues) {
        [void] $pathValueSet.Add($path)
    }
    [void] $pathValueSet.Remove('')
    $nameValueMap = New-Object 'System.Collections.Generic.Dictionary[string,string]'([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $processEnvs.Keys) {
        $nameValueMap[$name] = $processEnvs[$name]
    }
    foreach ($name in $sysEnvs.Keys) {
        $nameValueMap[$name] = $sysEnvs[$name]
    }
    foreach ($name in $userEnvs.Keys) {
        $nameValueMap[$name] = $userEnvs[$name]
    }
    if ($nameValueMap.ContainsKey('USERNAME') -and $nameValueMap['USERNAME'] -eq 'SYSTEM') {
        $nameValueMap['USERNAME'] = [regex]::Replace($processEnvs['USERPROFILE'], '^.*\\', '');
    }
    $nameValueMap['PATH'] = $pathValueSet -Join ';'
    foreach ($name in $nameValueMap.Keys) {
        [Environment]::SetEnvironmentVariable($name, $nameValueMap[$name], [EnvironmentVariableTarget]::Process)
        if ($DebugReload) {
            Write-Host "Reload env-var: $name" -ForegroundColor Cyan
        }
    }
}

function Reset-EnvVars {
    param (
        [bool] $DebugReset = $False
    )
    $KnownEnvNames = @('ALLUSERSPROFILE', 'APPDATA', 'ChocolateyInstall', 'CommonProgramFiles', 'CommonProgramFiles(x86)', 'CommonProgramW6432',
        'COMPUTERNAME', 'ComSpec', 'DriverData', 'HOMEDRIVE', 'HOMEPATH', 'LOCALAPPDATA', 'LOGONSERVER', 'NugetMachineInstallRoot', 'NUMBER_OF_PROCESSORS',
        'OneDrive', 'OS', 'PACKAGE_CACHE_DIRECTORY', 'Path', 'PATHEXT', 'PROCESSOR_ARCHITECTURE', 'PROCESSOR_IDENTIFIER', 'PROCESSOR_LEVEL',
        'PROCESSOR_REVISION', 'ProgramData', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432', 'PROMPT', 'PSModulePath', 'PUBLIC', 'SystemDrive',
        'SystemRoot', 'TEMP', 'TMP', 'UATDATA', 'USERDNSDOMAIN', 'USERDOMAIN', 'USERDOMAIN_ROAMINGPROFILE', 'USERNAME', 'USERPROFILE', 'windir',
        'CLASSPATH', 'JAVA_HOME', 'GRADLE_HOME', 'MAVEN_HOME', 'CARGO_HOME', 'RUSTUP_HOME', 'GOPATH', 'GOROOT', 'ANDROID_SDK_ROOT', 'ANDROID_NDK_ROOT'
    )

    $processEnvs = [System.Environment]::GetEnvironmentVariables([System.EnvironmentVariableTarget]::Process)
    $sysEnvs = [System.Environment]::GetEnvironmentVariables([System.EnvironmentVariableTarget]::Machine)
    $userEnvs = [System.Environment]::GetEnvironmentVariables([System.EnvironmentVariableTarget]::User)
    $pathValueSet = New-Object System.Collections.Generic.HashSet[String]([StringComparer]::OrdinalIgnoreCase)
    $allPathValues = $($sysEnvs['Path'] + ';' + $userEnvs['Path']) -Split '\\*\s*;\s*'
    foreach ($path in $allPathValues) {
        [void] $pathValueSet.Add($path)
    }
    [void] $pathValueSet.Remove('');

    $nameValueMap = New-Object 'System.Collections.Generic.Dictionary[string,string]'([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $sysEnvs.Keys) {
        $nameValueMap[$name] = $sysEnvs[$name];
    }
    foreach ($name in $userEnvs.Keys) {
        $nameValueMap[$name] = $userEnvs[$name]
    }
    if ($nameValueMap.ContainsKey('USERNAME') -and $nameValueMap['USERNAME'] -eq 'SYSTEM') {
        $nameValueMap['USERNAME'] = [regex]::Replace($processEnvs['USERPROFILE'], '^.*\\', '');
    }
    $nameValueMap['PATH'] = $pathValueSet -Join ';'
    foreach ($name in $processEnvs.Keys) {
        if (-not $nameValueMap.ContainsKey($name) -and -not $KnownEnvNames.Contains($name)) {
            [System.Environment]::SetEnvironmentVariable($name, $null, [System.EnvironmentVariableTarget]::Process)
            if ($DebugReset) {
                Write-Host "Deleted env-var: $name" -ForegroundColor Magenta
            }
        }
    }
    foreach ($name in $nameValueMap.Keys) {
        [System.Environment]::SetEnvironmentVariable($name, $nameValueMap[$name], [System.EnvironmentVariableTarget]::Process)
        if ($DebugReset) {
            Write-Host "Set env-var: $name" -ForegroundColor Cyan
        }
    }
}

class GitRepoInfo {
    [string] $BranchName
    [string] $CommitId
    [string] $CommitTime
    [string] $RootFolder
    [string] $HomeUrl
    [string] $RepoName
    [string] $SubModuleRoot

    GitRepoInfo([string] $branchName, [string] $commitId, [string] $commitTime, [string] $rootFolder, [string] $homeUrl, [string] $subModuleRoot = '') {
        $this.BranchName = $branchName
        $this.CommitId = $commitId
        $this.CommitTime = $commitTime
        $this.RootFolder = $rootFolder
        $this.SubModuleRoot = $subModuleRoot
        $this.HomeUrl = $homeUrl
        $this.RepoName = [IO.Path]::GetFileName($rootFolder)
    }
}

function New-GitRepoInfo {
    param (
        [Parameter(Mandatory = $true)] $GitRepoRootOrFullSubPath,
        [bool] $ForceUseHttpRepoUrl = $true
    )

    $folder = if ([IO.File]::Exists($GitRepoRootOrFullSubPath)) {
        [IO.Path]::GetDirectoryName($GitRepoRootOrFullSubPath)
    }
    else {
        $GitRepoRootOrFullSubPath
    }

    Push-Location $folder
    $branchName = git rev-parse --abbrev-ref HEAD 2>$null
    $commitId = git rev-list head --max-count=1 2>$null
    $commitTime = git log -1 --format=%cd --date=iso 2>$null
    $rootFolder = $(git rev-parse --absolute-git-dir 2>$null) -ireplace '[\\/].git($|[\\/].*)', ''
    $subModuleRoot = git rev-parse --show-toplevel 2>$null

    if (-not [string]::IsNullOrEmpty($rootFolder)) {
        $rootFolder = $rootFolder.Replace('/', $SysPathChar)
    }

    if (-not [string]::IsNullOrEmpty($subModuleRoot)) {
        $subModuleRoot = $subModuleRoot.Replace('/', $SysPathChar)
    }

    $homeUrl = git remote -v 2>$null | Select-Object -First 1
    if (-not [string]::IsNullOrEmpty($homeUrl)) {
        $homeUrl = [regex]::Replace($homeUrl, ".*?(http\S+).*fetch.*", '$1')
        if ($ForceUseHttpRepoUrl) {
            $match = [regex]::Match($homeUrl, '\w+@(\S+?):(\S+).git\s+')
            if ($match.Success) {
                $homeUrl = "https://" + $match.Groups[1].Value + '/' + $match.Groups[2].Value
            }
        }
        else {
            $homeUrl = $homeUrl -ireplace '^\S+\s+(\S+).*', '$1'
        }
    }

    Pop-Location

    $gitRepoInfo = [GitRepoInfo]::new($branchName, $commitId, $commitTime, $rootFolder, $homeUrl, $subModuleRoot)
    return $gitRepoInfo
}

function Show-CallStack {
    $caughtThisTimes = 0
    $callStack = Get-PSCallStack
    if (-not $callStack -or $callStack.Count -eq 0) {
        return
    }

    for ($k = $callStack.Count - 1; $k -ge 0; $k -= 1) {
        $stack = $callStack[$k]
        if ($stack.FunctionName.StartsWith('Show-CallStack')) {
            $caughtThisTimes += 1
            if ($caughtThisTimes -gt 2) {
                break
            }
            continue
        }

        if ([string]::IsNullOrEmpty($stack.ScriptName)) {
            continue
        }
        Write-Host "$($stack.ScriptName):$($stack.ScriptLineNumber) $($stack.FunctionName)" -ForegroundColor Magenta
    }
}

function DumpErrorStackThrow {
    param(
        $MessageOrException,
        $PropertiesMap = @{}
    )
    Show-CallStack
    throw $MessageOrException
}

function Test-CreateDirectory {
    param (
        [string] $Folder
    )

    if (-not [IO.Directory]::Exists($Folder)) {
        [void] [IO.Directory]::CreateDirectory($Folder)
    }
}

function Test-DeleteFiles {
    param (
        [string[]] $Files
    )

    foreach ($file in $Files) {
        if ([IO.File]::Exists($file)) {
            [void] [IO.File]::Delete($file)
        }
    }
}

function Update-PathEnvForExe {
    param (
        [Parameter(Mandatory = $true)] [string] $ExeName,
        [switch] $DebugEnvPath
    )

    if (Test-ToolExistsByName $ExeName) {
        return
    }

    $toDetectNames = if ($IsWindowsOS) {
        @($ExeName, "$ExeName.exe", "$ExeName.cmd", "$ExeName.bat")
    }
    else {
        @($ExeName)
    }

    $pathsValue = [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::Machine);
    $pathsValue += ';' + [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::User);
    foreach ($directory in $($pathsValue -split '\s*;\s*')) {
        if ([string]::IsNullOrWhiteSpace($directory)) {
            continue
        }
        foreach ($toDetectName in $toDetectNames) {
            if (Test-Path $(Join-Path $directory $toDetectName)) {
                $env:PATH += ';' + $directory + ';'
                if ($DebugEnvPath) {
                    Write-Host "Temporarily added new directory to env PATH: $directory" -ForegroundColor Cyan
                }
                return
            }
        }
    }
}

function Get-ToolPathByName {
    param (
        [string] $Name
    )

    return $(Get-Command $Name 2>$null).Source
}


function Test-ToolExistsByName {
    param (
        [string] $Name,
        [string] $Message = $null,
        [bool] $ThrowMessage = $true,
        [switch] $RefreshEnvFirst
    )

    if ($RefreshEnvFirst) {
        Update-PathEnvForExe $Name -DebugEnvPath
    }
    $toolPath = Get-ToolPathByName $Name
    return -not [string]::IsNullOrWhiteSpace($toolPath)
}

function Test-ToolExistsThrowError {
    param (
        [string] $Name,
        [string] $Message
    )

    $toolPath = Get-ToolPathByName $Name
    if (-not [string]::IsNullOrWhiteSpace($toolPath)) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($Message)) {
        DumpErrorStackThrow "Not found $($Name), please install it or add it into PATH environment."
    }
    else {
        DumpErrorStackThrow $Message
    }
}

function Update-PathEnvToTrimmedAndCompacted {
    $comparison = if ($IsWindowsOS) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $pathSet = New-Object 'System.Collections.Generic.HashSet[String]'($comparison)
    $pathList = $env:PATH.Split($SysPathEnvSeparator)
    foreach ($p in $pathList) {
        if (-not [string]::IsNullOrWhiteSpace($p)) {
            [void] $pathSet.Add($p.TrimEnd($SysPathChar))
        }
    }

    $env:PATH = [string]::Join($SysPathEnvSeparator, $pathSet)
    # [System.Environment]::SetEnvironmentVariable('PATH', $env:PATH, [System.EnvironmentVariableTarget]::User)
}

function Set-ExecutableAddToPath {
    param (
        [string] $ToolPath,
        [bool] $SetExecutable = $true,
        [bool] $AddToPath = $true
    )

    if ($SetExecutable) {
        if ($IsWindowsOS) {
            cmd /c "icacls $($ToolPath) /grant %USERNAME%:RX" | Out-Null
        }
        else {
            bash -c "chmod +x $($ToolPath)" | Out-Null
        }
    }

    $folder = [IO.Path]::GetDirectoryName($ToolPath)
    $checkValue = $folder + $SysPathEnvSeparator
    if ($AddToPath -and $($env:PATH.IndexOf($checkValue) -lt 0)) {
        $env:PATH += $SysPathEnvSeparator + $checkValue
    }
    Update-PathEnvToTrimmedAndCompacted
}

function Save-WebFileToPath {
    param (
        [Parameter(Mandatory = $true)] [string] $SourceUrl,
        [string] $SavePath = $env:HOME,
        [string] $SaveName,
        [bool] $SetExecutable = $false,
        [bool] $AddToPath = $false,
        [bool] $IsExeTool = $false,
        [bool] $DebugDownload = $false,
        [bool] $CanUseCurl = $false
    )

    if ([string]::IsNullOrWhiteSpace($SavePath)) {
        $SavePath = $env:HOME
    }

    $IsExeTool = $IsExeTool -or $SetExecutable
    if ($SavePath.EndsWith('/') -or $SavePath.EndsWith('\') -or [IO.Directory]::Exists($SavePath)) {
        $extension = if ($IsExeTool) {
            if ($IsWindowsOS -and $SourceUrl -imatch '\.exe') { '.exe' } else {}
        }
        else {
            [IO.Path]::GetExtension($SourceUrl)
        }

        $Name = if ([string]::IsNullOrWhiteSpace($SaveName)) {
            $([IO.Path]::GetFileNameWithoutExtension($SourceUrl)) + $extension
        }
        else {
            $SaveName + $extension
        }

        $SavePath = Join-Path $($SavePath.TrimEnd('/', '\')) $Name
    }

    if ([IO.File]::Exists($SavePath)) {
        Set-ExecutableAddToPath $SavePath $SetExecutable $AddToPath
        return $SavePath
    }

    $folder = [IO.Path]::GetDirectoryName($SavePath)
    if (-not [IO.Directory]::Exists($folder)) {
        [IO.Directory]::CreateDirectory($folder)
    }

    $tmpPath = $SavePath + ".tmp"
    Test-DeleteFiles @($tmpPath)
    $checkWgetName = if ($IsWindowsOS) { 'wget.exe' } else { 'wget' }
    $wgetPath = Get-ToolPathByName $checkWgetName
    if (-not [string]::IsNullOrEmpty($wgetPath)) {
        if ($DebugDownload) {
            Write-Host "$wgetPath $SourceUrl -O $tmpPath --quiet" -ForegroundColor Cyan
        }
        & $wgetPath $SourceUrl -O $tmpPath --quiet
    }
    else {
        $checkCurlName = if ($IsWindowsOS) { 'curl.exe' } else { 'curl' }
        $curlPath = Get-ToolPathByName $checkCurlName
        if ($CanUseCurl -and -not [string]::IsNullOrEmpty($curlPath)) {
            if ($DebugDownload) {
                Write-Host "$curlPath --silent --show-error --fail $SourceUrl -o $tmpPath" -ForegroundColor Cyan
            }
            & $curlPath --silent --show-error --fail $SourceUrl -o $tmpPath
        }
        else {
            $ProgressPreference = 'SilentlyContinue'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            if ($DebugDownload) {
                Write-Host "Invoke-WebRequest -Uri $SourceUrl -OutFile $tmpPath" -ForegroundColor Cyan
            }
            Invoke-WebRequest -Uri $SourceUrl -OutFile $tmpPath
        }
    }

    if ((-not $?) -or -not $([IO.File]::Exists($tmpPath))) {
        DumpErrorStackThrow "Failed to download $($SourceUrl) to $($tmpPath)"
    }

    if ($DebugDownload) {
        $fileBytes = $(Get-Item $tmpPath).Length
        Write-Host "Size = $($fileBytes)B, downloaded to $($tmpPath)" -ForegroundColor Cyan
    }

    Rename-Item -Path $tmpPath -NewName $SavePath -Force
    if (-not $?) {
        DumpErrorStackThrow "Failed to rename tmp file: $($tmpPath) to $($SavePath)"
    }

    Set-ExecutableAddToPath $SavePath $SetExecutable $AddToPath

    return $SavePath
}

function Get-SysInternalsToolFromWeb {
    param (
        [Parameter(Mandatory = $true)] [string] $OneToolUrl
    )
    # https://learn.microsoft.com/en-us/sysinternals/downloads/sysinternals-suite
    $zipPath = Save-WebFileToPath $OneToolUrl -SavePath $SysTmpFolder -CanUseCurl $false
    $toolName = [IO.Path]::GetFileNameWithoutExtension($zipPath) + ".exe"
    Write-Host "Will extract downloaded $($OneToolUrl) to $($SysTmpFolder)"
    Expand-Archive -Path $zipPath -DestinationPath $SysTmpFolder -Force
    $exePath = Join-Path $SysTmpFolder $toolName
    if (-not [IO.File]::Exists($exePath)) {
        DumpErrorStackThrow "Failed to extract tool $($toolName) to $($exePath) from $($OneToolUrl)"
    }
    Set-ExecutableAddToPath $exePath
}

function Install-ToolByUrlIfNotFound {
    param (
        [string] $Name,
        [string] $DownloadUrl,
        [string] $SavePath = ''
    )
    return Save-WebFileToPath $DownloadUrl $SavePath -SaveName $Name -SetExecutable $true -AddToPath $true
}

function Install-AppIfNotFound {
    param (
        [string] $Name,
        [string] $InstallAppName
    )

    if (-not $(Test-ToolExistsByName $Name)) {
        if ([string]::IsNullOrWhiteSpace($InstallAppName)) {
            $InstallAppName = $Name
        }

        Invoke-CommandLineDirectly "$($SudoInstallCmd) $($InstallAppName)"
    }
}

$_SourceExeUrlArray = @(
    'https://raw.githubusercontent.com/qualiu/msr/master/tools/'
    'https://gitlab.com/lqm678/msr/-/raw/master/tools/'
    'https://master.dl.sourceforge.net/project/avasattva/'
)

$_SourceScriptUrlArray = @(
    'https://raw.githubusercontent.com/qualiu/msrTools/master/'
    'https://gitlab.com/lqm678/msrTools/-/raw/master/'
    'https://master.dl.sourceforge.net/project/avasattva/'
)

function Get-MsrDownloadUrl {
    param (
        [string] $SourceExeName,
        [int] $UseUrlIndex = 0
    )

    $sourceUrlArray = if ($SourceExeName -imatch '^(msr|nin)') { $_SourceExeUrlArray } else { $_SourceScriptUrlArray }
    $UseUrlIndex = $UseUrlIndex % $sourceUrlArray.Count
    $parentUrl = $sourceUrlArray[$UseUrlIndex]
    if ($parentUrl.Contains('sourceforge')) {
        return $parentUrl + $SourceExeName + '?viasf=1'
    }
    elseif ($parentUrl.Contains('gitlab')) {
        return $parentUrl + $SourceExeName + '?inline=false'
    }
    return $parentUrl + $SourceExeName
}

function Get-MsrToolByName {
    param (
        [string] $Name,
        [string] $SavePath
    )

    $existingPath = $(Get-Command $Name 2>$null).Source
    if (-not [string]::IsNullOrEmpty($existingPath)) {
        return
    }

    $kernelName = if ($IsWindowsOS) { '' } else { $(uname -s).ToLower() }
    $machineArch = if ($IsWindowsOS) { '' } else { $(uname -m).ToLower() }
    $suffix = if ($Name -inotmatch '^(msr|nin)$') {
        ''
    }
    elseif ($IsWindowsOS) {
        if ($env:PROCESSOR_ARCHITECTURE -imatch '64') {
            '.exe'
        }
        else {
            '-Win32.exe'
        }
    }
    elseif (($kernelName -ieq 'linux') -and ($machineArch -imatch 'i386|i686|x86|x64')) {
        if ($machineArch -imatch 'i386|i686') {
            '-i386.gcc48'
        }
        else {
            '.gcc48'
        }
    }
    else {
        "-$($machineArch).$($kernelName)".ToLower()
    }

    $sourceUrlArray = if ($Name -imatch '^(msr|nin)') { $_SourceExeUrlArray } else { $_SourceScriptUrlArray }
    for ($urlIndex = 0; $urlIndex -lt $sourceUrlArray.Count; $urlIndex += 1) {
        $sourceExeName = $Name + $suffix
        $downloadUrl = Get-MsrDownloadUrl $sourceExeName $urlIndex
        try {
            # Write-Host "Will download $($sourceExeName) from $($downloadUrl)"
            Save-WebFileToPath $downloadUrl $SavePath -SaveName $Name -SetExecutable $true -AddToPath $true
            return
        }
        catch {
            Write-Warning $_
            if ($($urlIndex + 1) -lt $sourceUrlArray.Count) {
                Write-Warning "Will try to download $($Name) from next source ..."
            }
        }
    }
}

Get-MsrToolByName 'msr'
Get-MsrToolByName 'nin'
if ($IsWindowsOS) {
    Get-MsrToolByName 'psall.bat'
    Get-MsrToolByName 'pskill.bat'
    Get-MsrToolByName 'PsTool.ps1'
}

msr -h -C | msr -t "keep-color" -H 0 -M
if ($LASTEXITCODE -eq 0) {
    $MsrKeepColorArg = ''
    $MsrOutStderrArg = ''
    $MsrOutStderrWithColorArgs = @()
}

# Auto generated exports by Update-PowerShell-Module-Exports.ps1
Export-ModuleMember -Variable Utf8NoBomEncoding
Export-ModuleMember -Variable IsWindowsOS
Export-ModuleMember -Variable SysPathEnvSeparator
Export-ModuleMember -Variable SysPathChar
Export-ModuleMember -Variable SysTmpFolder
Export-ModuleMember -Variable SysOutNull
Export-ModuleMember -Variable TmpToolPackageFolder
Export-ModuleMember -Variable PushFolderCmd
Export-ModuleMember -Variable SysUserName
Export-ModuleMember -Variable SysHostName
Export-ModuleMember -Variable SysDomainName
Export-ModuleMember -Variable SysDnsDomain
Export-ModuleMember -Variable PowerShellName
Export-ModuleMember -Variable SudoInstallCmd
Export-ModuleMember -Variable SudoUpdateCmd
Export-ModuleMember -Variable SysPathEnvSeparator
Export-ModuleMember -Variable SudoCmd
Export-ModuleMember -Variable CurlExeName
Export-ModuleMember -Variable WgetExeName
Export-ModuleMember -Variable DeleteFileCmd
Export-ModuleMember -Variable ForceDeleteFileCmd
Export-ModuleMember -Variable DeleteDirectoryCmd
Export-ModuleMember -Variable ForceDeleteDirectoryCmd
Export-ModuleMember -Variable MsrKeepColorArg
Export-ModuleMember -Variable MsrOutStderrArg
Export-ModuleMember -Variable MsrOutStderrWithColorArgs
Export-ModuleMember -Variable MsrWarnColorArgs
Export-ModuleMember -Function Test-IsLaunchedFromWindowsCMD
Export-ModuleMember -Function Get-EmptyTextForMsrReplace
Export-ModuleMember -Function Restore-EnvVars
Export-ModuleMember -Function Reset-EnvVars
Export-ModuleMember -Function New-GitRepoInfo
Export-ModuleMember -Function Show-CallStack
Export-ModuleMember -Function Test-CreateDirectory
Export-ModuleMember -Function Test-DeleteFiles
Export-ModuleMember -Function Update-PathEnvForExe
Export-ModuleMember -Function Get-ToolPathByName
Export-ModuleMember -Function Test-ToolExistsByName
Export-ModuleMember -Function Test-ToolExistsThrowError
Export-ModuleMember -Function Update-PathEnvToTrimmedAndCompacted
Export-ModuleMember -Function Set-ExecutableAddToPath
Export-ModuleMember -Function Save-WebFileToPath
Export-ModuleMember -Function Get-SysInternalsToolFromWeb
Export-ModuleMember -Function Install-ToolByUrlIfNotFound
Export-ModuleMember -Function Install-AppIfNotFound
Export-ModuleMember -Function Get-MsrDownloadUrl
Export-ModuleMember -Function Get-MsrToolByName
