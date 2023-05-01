<#
.SYNOPSIS
    Check TypeScript circle dependencies.
    https://learn.microsoft.com/en-us/visualstudio/msbuild/msbuild-command-line-reference

.PARAMETER CodeFolder
    Code folder of your TypeScript project.

.PARAMETER ExtensionPattern
    Regex pattern of TypeScript file extension. Default is '\.tsx?$'.

.PARAMETER ThisLogLevel
    Log level of this script. Default is "message".

.PARAMETER ExcludeFolderPattern
    Regex pattern to exclude folders when checking.

.EXAMPLE
    ./Check-TypeScript-Dependency.ps1 /git/my-ts-repo
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $CodeFolder,
    [string] $ExtensionPattern = '\.tsx?$',
    [string] $ThisLogLevel = "message",
    [string] $ExcludeFolderPattern = "^([\.\$]|(Release|Debug|objd?|bin|node_modules|(Js)?Packages|\w+-packages?|static|dist|target|build|out)$|__pycache__)"
)

# Import-Module "$PSScriptRoot/../common/BasicOsUtils.psm1"
Import-Module "$PSScriptRoot/../common/CommonUtils.psm1"

$ErrorActionPreference = "Stop"

if ($MyInvocation.Line -imatch '\s+--help') {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    return
}

$TimeLogger.SetLogLevel($ThisLogLevel).SetInfo($MyInvocation)
$FileToDependencyMap = New-Object 'System.Collections.Generic.Dictionary[[string], System.Collections.Generic.HashSet[string]]'

function Get-FullTypeScriptFilePath {
    param (
        [string] $Folder,
        [string] $SubPath
    )
    $checkList = @(
        Join-Path $thisFolder "$($subPath).ts"
        Join-Path $thisFolder "$($subPath).tsx"
        Join-Path $thisFolder "$($subPath)"
    )
    foreach ($path in $checkList) {
        if ([IO.File]::Exists($path)) {
            return $(Resolve-Path $path).Path
        }
    }

    $TimeLogger.ShowErrorThrow("Not found file: $($checkList[0])")
}

function Check_One_File {
    param (
        [string] $FilePath,
        $ShouldNotImportFilePathSet
    )
    $indent = "`n"
    $ShouldNotImportFilePathSet | ForEach-Object { $indent += "  " }
    $FilePath = $(Resolve-Path $FilePath).Path
    Write-Host "$($indent.Substring(1))$(Get-NowText) Check file: $($FilePath)"
    # $TimeLogger.ShowMessage("$($indent.Substring(1)) Check file: $($FilePath)")
    $thisFolder = [IO.Path]::GetDirectoryName($FilePath)
    msr -p $FilePath -t "^\s*import\s+.*?from\s+'(\./.+?)';\s*$" -o "\1" -M -C | msr -t "(.+)" -o "$($indent.Substring(1))\1" -PAC | msr -aPA -e "(\S+:\d+:)"

    $importedFileSubPaths = msr -p $FilePath -t "^\s*import\s+.*?from\s+'(\./.+?)';\s*$" -o "\1" -PAC
    foreach ($subPath in $importedFileSubPaths) {
        $dependencyFilePath = Get-FullTypeScriptFilePath $thisFolder $subPath
        if ($ShouldNotImportFilePathSet.Contains($dependencyFilePath)) {
            # msr -p $FilePath -t "^\s*import\s+.*?from\s+'(\./.+?)';\s*$" -o "\1" -M -C | msr -t "(.+)" -o "$($indent.Substring(1))\1" -PAC | msr -aPA -e "(\S+:\d+:)"
            $TimeLogger.ShowErrorThrow("Circular dependencies of $($dependencyFilePath) as below: $($indent)$([string]::Join($indent, $ShouldNotImportFilePathSet))$($indent)$($dependencyFilePath)")
        }

        if ($FileToDependencyMap.ContainsKey($dependencyFilePath)) {
            continue
        }

        $tmpPathSet = New-Object System.Collections.Generic.HashSet[string]
        foreach ($path in $ShouldNotImportFilePathSet) {
            [void] $tmpPathSet.Add($path)
        }

        [void] $tmpPathSet.Add($FilePath)
        [void] $tmpPathSet.Add($dependencyFilePath)
        Check_One_File $dependencyFilePath $tmpPathSet

        # record to know dependency map:
        [void] $tmpPathSet.Remove($FilePath)
        foreach ($path in $ShouldNotImportFilePathSet) {
            [void] $tmpPathSet.Remove($path)
        }
        $FileToDependencyMap.Add($dependencyFilePath, $tmpPathSet)
    }
}

foreach ($file in $(msr -rp $CodeFolder -l -f $ExtensionPattern --nd $CommonJunkFolderPattern -PAC)) {
    $set = New-Object System.Collections.Generic.HashSet[string]
    Check_One_File $file $set
}

$TimeLogger.ShowInfo("Well checked, no circular dependencies found.")
$TimeLogger.Dispose()
