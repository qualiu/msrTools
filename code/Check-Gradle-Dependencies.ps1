<#
.SYNOPSIS
    Check dependency packages versions in gradle project files.

.DESCRIPTION

.Parameter CodeFolder
    Code folder of a service.

.Parameter ProjectName
    Gradle project/module name, defined in settings.gradle file.

.Parameter Configuration
    Gradle configuration name, default is "compileClasspath".

.Parameter OnlyCheckPackagePattern
    Regex pattern to check only matched packages.

.Parameter IgnorePackagePattern
    Regex pattern to ignore matched packages.

.Parameter ShowAllPackageVersions
    Show all package versions.

.Parameter ShowAllPackagePaths
    Show all package paths.

.EXAMPLE
    .\Check-Gradle-Dependencies.ps1 /git/repo/service1 used-service2 implementation
    .\Check-Gradle-Dependencies.ps1 C:/repo/service1 used-service2 compileClasspath
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $CodeFolder,
    [string] $ProjectName,
    [string] $Configuration = "compileClasspath",
    [string] $OnlyCheckPackagePattern = "",
    [string] $IgnorePackagePattern = "netty",
    [bool] $ShowAllPackageVersions = $false,
    [bool] $ShowAllPackagePaths = $false
)

Import-Module "$PSScriptRoot/../common/BasicOsUtils.psm1"
Import-Module "$PSScriptRoot/../common/CommonUtils.psm1"

if ($MyInvocation.Line -imatch '\s+--help') {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    return
}

$TimeLogger = New-BeginEndLogger $MyInvocation
$repoInfo = Add-GitRepoInfo $CodeFolder
$RepoFolder = $repoInfo.RootFolder
$packageRegex = New-Object System.Text.RegularExpressions.Regex("^(?<Indent>.*?---\s+)(?<Package>\w+[\w\.-]+:\w+[\w\.-]+):(?<Version>\d[\w\.-]*|[\{\[].*?[\}\]])\s*(->\s*(?<Upgrade>\d+[\w\.-]*))?")
$projectRegex = New-Object System.Text.RegularExpressions.Regex("\s+project\s+:?\s*(\w+[\w\.-]+)")
$flag = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
$ignorePackageRegex = if ([string]::IsNullOrWhiteSpace($IgnorePackagePattern)) { New-Object System.Text.RegularExpressions.Regex("not-match-any") } else { New-Object System.Text.RegularExpressions.Regex($IgnorePackagePattern, $flag) }
$onlyCheckPackageRegex = if ([string]::IsNullOrWhiteSpace($IgnorePackagePattern)) { New-Object System.Text.RegularExpressions.Regex(".") } else { New-Object System.Text.RegularExpressions.Regex($OnlyCheckPackagePattern, $flag) }

$packageToVersionMap = New-Object System.Collections.Generic.Dictionary'[[String],[String]]'
$packageToPathMap = New-Object System.Collections.Generic.Dictionary'[[String],[String]]'
$checkedProjects = New-Object System.Collections.Generic.HashSet'[String]'
$conflictPackages = New-Object System.Collections.Generic.HashSet'[String]'
$conflictPackagePaths = New-Object System.Collections.Generic.HashSet'[String]'
$GradleCmd = if ($IsWindowsOS) { "gradlew" } else { "./gradlew" }

function Check_ProjectDependencies {
    param (
        $checkedProjects,
        $packageToVersionMap,
        $packageToPathMap,
        [string] $ProjectName,
        [string] $ParentProjectPath = ""
    )

    if (-not $checkedProjects.Add($ProjectName)) {
        return
    }

    $CurrentProjectPath = ($ParentProjectPath + ' -> ' + $ProjectName).TrimStart(' -> '.ToCharArray())
    $message = if ([string]::IsNullOrEmpty($ParentProjectPath)) { "Checking project: $($ProjectName)" } else { "Checking project: $($ProjectName), parent = $($ParentProjectPath)" }
    Show-Message $message -ForegroundColor Green
    $output = Invoke-CommandLine "$($PushFolderCmd) $($RepoFolder) && $($GradleCmd) $($ProjectName):dependencies -q --configuration $($Configuration)" | msr -b "^$($Configuration)\b" -t "\s*\S+-+\s+\w+" -PAC
    $lastDepth = 0
    $lastParentPackages = New-Object System.Collections.Generic.List'[String]'
    foreach ($result in $output) {
        # Write-Output $output
        $matchProject = $projectRegex.Match($result)
        if ($matchProject.Success) {
            $subProjectName = $matchProject.Groups[1].Value
            Check_ProjectDependencies $checkedProjects $packageToVersionMap $packageToPathMap $subProjectName $CurrentProjectPath
            continue
        }

        $matchPackage = $packageRegex.Match($result)
        if (-not $matchPackage.Success) {
            throw "Should match either project or package Regex! Please check: $($result)"
        }

        $package = $matchPackage.Groups["Package"].Value
        $version = $matchPackage.Groups["Version"].Value
        $indent = $matchPackage.Groups["Indent"].Value
        $upgradeVersion = $matchPackage.Groups["Upgrade"].Value
        if ($version.StartsWith("{")) {
            $version = $upgradeVersion
        }
        elseif (-not [string]::IsNullOrEmpty($upgradeVersion)) {
            $version = $upgradeVersion
        }

        $packageAndVersion = $package + ':' + $version

        $depth = $($($indent -replace '---\s.*', '') -replace '\s+', '').Length - 1
        if ($depth -eq 0) {
            $lastParentPackages.Clear()
        }
        elseif ($depth -le $lastDepth) {
            for ($k = $depth; $k -le $lastDepth; $k += 1) {
                $lastParentPackages.RemoveAt($lastParentPackages.Count - 1)
            }
        }
        $lastParentPackages.Add($packageAndVersion)
        $lastDepth = $depth
        $currentPackages = $lastParentPackages[0 .. $depth] # if ($depth -gt 0) { $lastParentPackages[0 .. $depth] } else { New-Object System.Collections.Generic.List'[String]' }
        $currentPackagePath = $CurrentProjectPath + ' -> ' + $([string]::Join(' -> ', $currentPackages)).TrimStart(' -> '.ToCharArray())

        if ($ignorePackageRegex.IsMatch($package)) {
            continue
        }

        if (-not $onlyCheckPackageRegex.IsMatch($package)) {
            continue
        }

        if ($ShowAllPackageVersions) {
            Write-Output $packageAndVersion
        }

        if ($ShowAllPackagePaths) {
            Write-Output $currentPackagePath
        }

        $existingVersion = ''
        $hasFound = $packageToVersionMap.TryGetValue($package, [ref] $existingVersion)
        if (-not $hasFound) {
            $packageToVersionMap.Add($package, $version)
            $packageToPathMap.Add($package, $currentPackagePath)
            continue
        }

        if ($existingVersion -ne $version) {
            [void] $conflictPackages.Add($package + ':' + $existingVersion)
            [void] $conflictPackages.Add($packageAndVersion)
            [void] $conflictPackagePaths.Add($packageToPathMap[$package])
            [void] $conflictPackagePaths.Add($currentPackagePath)
            Write-Host -ForegroundColor Cyan $packageToPathMap[$package]
            Write-Host -ForegroundColor Yellow $currentPackagePath
            Write-Host -ForegroundColor Red "Found multiple versions of package: $($package), existing = $($existingVersion), current = $($version)" #-ThrowError:$ThrowErrorAndStop
        }
    }
}

$allProjects = if ([string]::IsNullOrWhiteSpace($ProjectName)) {
    Invoke-CommandLine "$($PushFolderCmd) $($RepoFolder) && $($GradleCmd) projects" | msr -t "^\W+Project \W+:(\w+[\w:\.-]+).*" -o "\1" --nt "Root project" -PAC
}
else {
    @( $ProjectName )
}

foreach ($project in $allProjects) {
    Check_ProjectDependencies $checkedProjects $packageToVersionMap $packageToPathMap $project
}

if ($conflictPackages.Count -gt 0) {
    Write-Host -ForegroundColor Red "Summary of $($conflictPackages.Count) conflict package-versions as below:"
    $conflictPackages | Write-Host -ForegroundColor Yellow
}

if ($conflictPackagePaths.Count -gt 0) {
    Write-Host -ForegroundColor Red "Summary of $($conflictPackagePaths.Count) conflict package-paths as below:"
    $conflictPackagePaths | Write-Host -ForegroundColor Yellow
}

Show-Message "Found $($packageToVersionMap.Count) packages with $($conflictPackages.Count) conflict versions in $($ProjectName) in $($RepoFolder)."
$TimeLogger.Dispose()
