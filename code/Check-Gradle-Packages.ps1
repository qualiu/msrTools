<#
.SYNOPSIS
    Check dependency packages versions in gradle project files.

.DESCRIPTION

.Parameter CodeFolder
    Code folder of a service.

.Parameter SkipFolderPattern
    Regex pattern to skip folders when checking.

.EXAMPLE
    .\Check-Gradle-Packages.ps1 /git/repo/service1
    .\Check-Gradle-Packages.ps1 C:/repo/service1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $CodeFolder,
    [string] $SkipFolderPattern = '',
    [bool] $ShowAllPackageVersions = $false
)

Import-Module "$PSScriptRoot/../common/CommonUtils.psm1"

if ($MyInvocation.Line -imatch '\s+--help') {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    return
}

$TimeLogger = New-BeginEndLogger $MyInvocation
$repoInfo = Add-GitRepoInfo $CodeFolder
$RepoFolder = $repoInfo.RootFolder
$packagePattern = "\w+\s+\W(?<GroupId>[\w\.]+):(?<ArtifactId>[\w\.-]+):(?<Version>[\w\.\$\{\}-]+)"
$packageRegex = New-Object System.Text.RegularExpressions.Regex($packagePattern)
$versionRegex = New-Object System.Text.RegularExpressions.Regex("(\S+)=(\S+)")

$skipFolderArgs = if (-not [string]::IsNullOrWhiteSpace($SkipFolderPattern)) { @("--nd", $SkipFolderPattern) } else { @() }
$versionValueResults = msr -rp $RepoFolder $skipFolderArgs -f "^gradle.properties$" -t "^\s*(\w+\S+)\s*=\s*(\d+\S+)" -o "\1=\2" -M -C
$packageVersionResults = msr -rp $RepoFolder $skipFolderArgs -f "^build.gradle$" -t "^\s*$($packagePattern)" -W -C -M

$versionToValueMap = New-Object System.Collections.Generic.Dictionary'[[String],[String]]'
foreach ($result in $versionValueResults) {
    $match = $versionRegex.Match($result)
    $variable = $match.Groups[1].Value
    $value = $match.Groups[2].Value
    $versionToValueMap.Add($variable, $value)
}

$packageToVersionMap = New-Object System.Collections.Generic.Dictionary'[[String],[String]]'
foreach ($result in $packageVersionResults) {
    $match = $packageRegex.Match($result)
    $groupId = $match.Groups["GroupId"].Value
    $artifactId = $match.Groups["ArtifactId"].Value
    $package = $groupId + ':' + $artifactId
    $version = $match.Groups["Version"].Value
    $pureVersion = $version -replace '\$\{(.+)\}', '$1'
    if ($version.StartsWith("$")) {
        if (-not $versionToValueMap.TryGetValue($pureVersion, [ref] $version)) {
            Write-Error "Failed to get package value: $($result)" #-ThrowError:$ThrowErrorAndStop
            continue
        }
    }
    $existingVersion = ''
    if ($packageToVersionMap.TryGetValue($package, [ref] $existingVersion)) {
        if ($existingVersion -ne $version) {
            $versionValueResults | msr -PA -t "\b($($pureVersion))\b" -x $version
            $packageVersionResults | msr -PA -t "\b($($groupId)):($($artifactId)):(\S+)"
            Write-Host -ForegroundColor Red "Found multiple versions of package: $($package), existing = $($existingVersion), current = $($version)" #-ThrowError:$ThrowErrorAndStop
            continue
        }
    }
    else {
        $packageToVersionMap.Add($package, $version)
    }

    if ($ShowAllPackageVersions) {
        Write-Output "$($groupId):$($artifactId):$($version)"
    }
}

$TimeLogger.Dispose()
