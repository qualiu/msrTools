
# $IsWindows may not defined on Window PowerShell
$IsWindowsOS = $IsWindows -or $([Environment]::OSVersion.Platform -imatch '^Win|Windows')
$env:HOME = if ([string]::IsNullOrEmpty($env:HOME)) { $env:USERPROFILE } else { $env:HOME }
$SysPathEnvSeparator = if ($IsWindowsOS) { ';' } else { ':' }
$SysTmpFolder = if ($IsWindowsOS) { [System.IO.Path]::GetTempPath() } else { '/tmp/' }

$Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding $False
# [Console]::InputEncoding = New-Object System.Text.UTF8Encoding

$PushFolderCmd = if ($IsWindowsOS) { 'pushd' } else { 'cd' }
$SysUserName = if ([string]::IsNullOrEmpty($env:USERNAME)) { $env:USER } else { $env:USERNAME }
$SysHostName = if ([string]::IsNullOrEmpty($env:COMPUTERNAME)) { $(hostname) } else { $env:COMPUTERNAME }
$PowerShellName = if ($IsWindowsOS) { 'powershell' } else { 'pwsh' }
$SudoInstallCmd = if ($IsMacOS) { "brew install" } elseif ($IsLinux) { 'sudo apt install -y' } else { 'choco install -y' }
$SudoUpdateCmd = if($IsMacOS) { 'brew update' } elseif ($IsLinux) { 'sudo apt update -y' } else { '' }
$SysPathEnvSeparator = if ($IsWindowsOS) { ';' } else { ':' }
$SudoCmd = if ($IsWindowsOS) { '' } else { 'sudo' }
$CurlExeName = if ($IsWindowsOS) { 'curl.exe' } else { 'curl' }
$WgetExeName = if ($IsWindowsOS) { 'wget.exe' } else { 'wget' }
$DeleteFileCmd = if ($IsWindowsOS) { 'del' } else { 'rm' }
$ForceDeleteFileCmd = if ($IsWindowsOS) { 'del /f' } else { 'rm -f' }
$DeleteDirectoryCmd = if ($IsWindowsOS) { 'rd /s' } else { 'rm -r' }
$ForceDeleteDirectoryCmd = if ($IsWindowsOS) { 'rd /q /s' } else { 'rm -rf' }

function Get-ToolPathByName {
    param (
        [string] $Name
    )

   return $(Get-Command $Name 2>$null).Source
}

function Test-ToolExistsByName {
    param (
        [string] $Name
    )

    $toolPath = Get-ToolPathByName $Name
    return -not [string]::IsNullOrWhiteSpace($toolPath)
}

function Test-ToolAndInstall {
    param (
        [string] $Name,
        [string] $IntallName
    )

    if (-not $(Test-ToolExistsByName $Name)) {
        if ([string]::IsNullOrWhiteSpace($InstallAppName)) {
            $InstallAppName = $Name
        }

        Invoke-CommandLineDirectly "$SudoInstallCmd $InstallAppName"
    }
}

function Set-ExecutableAddToPath {
    param (
        [string] $ToolPath,
        [bool] $SetExecutable,
        [bool] $AddToPath
    )

    if ($SetExecutable) {
        if ($IsWindowsOS) {
            cmd /c "icacls $ToolPath /grant %USERNAME%:RX" | Out-Null
        } else {
            bash -c "chmod +x $ToolPath" | Out-Null
        }
    }

    $folder = [IO.Path]::GetDirectoryName($ToolPath)
    $checkValue = $folder + $SysPathEnvSeparator
    if ($AddToPath -and $($env:PATH.IndexOf($checkValue) -lt 0)) {
        $env:PATH += $SysPathEnvSeparator + $checkValue
    }
}

function Save-WebFileToPath {
    param (
        [string] $SourceUrl,
        [string] $SavePath = $env:HOME,
        [string] $SaveName,
        [bool] $SetExecutable = $false,
        [bool] $AddToPath = $false,
        [bool] $IsExeTool = $false
    )

    if ([string]::IsNullOrWhiteSpace($SavePath)) {
        $SavePath = $env:HOME
    }

    $IsExeTool = $IsExeTool -or $SetExecutable
    if ($SavePath.EndsWith('/') -or $SavePath.EndsWith('\') -or [IO.Directory]::Exists($SavePath)) {
        $extension = if ($IsExeTool) {
            if($IsWindowsOS -and $SourceUrl -imatch '\.exe$') {'.exe' } else {}
        } else {
            [IO.Path]::GetExtension($SourceUrl)
        }

        $Name = if([string]::IsNullOrWhiteSpace($SaveName))  {
            $([IO.Path]::GetFileNameWithoutExtension($SourceUrl)) + $extension
        } else {
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
    $checkName = if ($IsWindowsOS) { 'wget.exe' } else { 'wget' }
    $wgetPath = Get-ToolPathByName $checkName
    if (-not [string]::IsNullOrEmpty($wgetPath)) {
        & $wgetPath $SourceUrl -O $tmpPath --quiet
    } else {
        $ProgressPreference = 'SilentlyContinue'
        wget $SourceUrl -O $tmpPath
    }

    if (-not $?) {
        throw "Failed to download $SourceUrl to $SavePath"
    }

    Rename-Item -Path $tmpPath -NewName $SavePath -Force
    if (-not $?) {
        throw "Failed to rename tmp file: $tmpPath to $SavePath"
    }

    Set-ExecutableAddToPath $SavePath $SetExecutable $AddToPath

    return $SavePath
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

    $homeUrl = 'https://raw.githubusercontent.com/qualiu/msr/master/tools/'
    $suffix = if ($Name -inotmatch '^(msr|nin|lzmw)$') {
        ''
    } elseif ($IsWindowsOS) {
        if ($env:PROCESSOR_ARCHITECTURE -imatch '64') {
            '.exe'
        } else {
            '-Win32.exe'
        }
    } elseif ($(uname -s) -ieq 'linux')   {
        if ($(uname -m) -imatch '64') {
            '.gcc48'
        } else {
            '-i386.gcc48'
        }
    } else { # ($(uname -s) -ieq 'darwin')
        "-$(uname -m).$(uname -s)".ToLower()
    }

    $downloadUrl = $homeUrl + $Name + $suffix
    Save-WebFileToPath $downloadUrl $SavePath -SaveName $Name -SetExecutable $true -AddToPath $true
}

Get-MsrToolByName 'msr'
Get-MsrToolByName 'nin'
if ($IsWindowsOS) {
    Get-MsrToolByName 'psall.bat'
    Get-MsrToolByName 'pskill.bat'
}

# Auto generated exports by Update-PowerShell-Module-Exports.ps1
Export-ModuleMember -Variable IsWindowsOS
Export-ModuleMember -Variable SysPathEnvSeparator
Export-ModuleMember -Variable SysTmpFolder
Export-ModuleMember -Variable Utf8NoBomEncoding
Export-ModuleMember -Variable PushFolderCmd
Export-ModuleMember -Variable SysUserName
Export-ModuleMember -Variable SysHostName
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
Export-ModuleMember -Function Get-ToolPathByName
Export-ModuleMember -Function Test-ToolExistsByName
Export-ModuleMember -Function Test-ToolAndInstall
Export-ModuleMember -Function Set-ExecutableAddToPath
Export-ModuleMember -Function Save-WebFileToPath
Export-ModuleMember -Function Get-MsrToolByName
