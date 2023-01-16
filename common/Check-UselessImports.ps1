<#
.SYNOPSIS
    Check useless imports in PowerShell scripts.

.DESCRIPTION

.PARAMETER SourcePaths
    Folders or files of powershell scripts.

.PARAMETER FileNamePattern
    Regex pattern of file name to search.

.PARAMETER SearchImportPattern
    Regex pattern of imports to search content.

.PARAMETER ExcludedFolderPattern
    Regex pattern of excluded folders.

.PARAMETER SkipPaths
    Paths or sub-paths to be skipped. Use comma(',') to separate multiple values.

.PARAMETER ShowDetails
    Print detail info.

.EXAMPLE
    ./Reduce-Imports common,Azure
    ./Reduce-Imports common,Azure -FileNamePattern '\.psm?1$' -SearchImportPattern '^\s*Import-Module\s+(.+)'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $SourcePaths,
    [string] $FileNamePattern = '\.psm?1$',
    [string] $SearchImportPattern = '^\s*#?\s*Import-Module\s+(.+\.psm1)',
    [string] $ExcludedFolderPattern = '^([\.\$]|(Release|Debug|objd?|bin|node_modules|static|dist|target|(Js)?Packages|\w+-packages?|wwwroot)$|__pycache__)',
    [string] $SkipPaths = '', #'no-skip-sub-paths-with-comma',
    [switch] $ShowDetails
)

Import-Module "$PSScriptRoot/CommonUtils.psm1"
$TimeLogger = New-BeginEndLogger $MyInvocation

$matchFilePathImportPattern = "^(.+?):\d+:\s*$($SearchImportPattern.TrimStart('^'))"
$matchResultRegex = New-Object System.Text.RegularExpressions.Regex($matchFilePathImportPattern)
$extraArgs = @()
if (-not [string]::IsNullOrWhiteSpace($SkipPaths)) {
    $extraArgs += @("--xp", $SkipPaths)
}
$resultFileLineAndImportModules = msr -rp $SourcePaths --nd $ExcludedFolderPattern -f $FileNamePattern -t $SearchImportPattern -C -I -W $extraArgs

$moduleFileToExportsMap = New-Object 'System.Collections.Generic.Dictionary[[string], [System.Collections.Generic.HashSet[string]]]'
$toChangeFiles = New-Object System.Collections.Generic.HashSet[string]
$toChangeLocationCount = 0
$checkedFilePaths = New-Object System.Collections.Generic.HashSet[string]
foreach ($result in $resultFileLineAndImportModules) {
    $match = $matchResultRegex.Match($result)
    if (-not $match.Success) {
        Show-ErrorThrow "Failed to match result: $($result)"
    }
    $currentFile = $match.Groups[1].Value
    $folder = [IO.Path]::GetDirectoryName($currentFile)
    $importedModule = $match.Groups[2].Value
    $importedModule = $importedModule.Replace('$PSScriptRoot', $folder).Trim('"', "'")
    if (-not [IO.File]::Exists($importedModule)) {
        Write-Warning "Not exist file: $($importedModule) , please check: $($result)"
        continue
    }

    $importedModule = Resolve-Path $importedModule
    [void] $checkedFilePaths.Add($currentFile)
    $exportedSet = New-Object System.Collections.Generic.HashSet[string]
    if (-not $($moduleFileToExportsMap.TryGetValue($importedModule, [ref] $exportedSet))) {
        $exportedSet = New-Object System.Collections.Generic.HashSet[string]
        $moduleFileToExportsMap.Add($importedModule, $exportedSet)
        foreach ($exported in $(msr -p $importedModule -t "^Export-ModuleMember\s+\S+\s+(\S+)" -PAC | msr -t ".*?-Variable\s+(\S+)" -o '$\1' -aPAC | msr -t ".*?-Function\s+(\S+)" -o '\1' -aPAC)) {
            [void] $exportedSet.Add($exported)
        }
    }

    $currentFileContent = [IO.File]::ReadAllText($currentFile) # Get-Content $currentFile
    $foundCount = 0
    foreach ($exported in $exportedSet) {
        $checkingRegex = New-Object System.Text.RegularExpressions.Regex("\b$([regex]::Escape($exported))\b".Replace('\b\$', '\$'))
        $matchContent = $checkingRegex.Match($currentFileContent)
        if ($matchContent.Success) {
            $lines = $currentFileContent.Substring(0, $matchContent.Index) -split '\n'
            $row = if ($lines.Count -gt 0) { $lines.Count } else { 1 }
            if ($ShowDetails) {
                msr -aPA -z "Found imported: $($exported) from module: $($importedModule) to file: $($currentFile):$($row)" -e "\w+: (\S+)" -x $currentFile
            }
            $foundCount += 1
            break
        }
    }

    if ($foundCount -gt 0) {
        continue
    }

    msr -aPA -z "You can reduce: $($result)" -t "You can reduce: (.+?:\d+:)\s*(.+)"
    [void] $toChangeFiles.Add($currentFile)
    $toChangeLocationCount += 1
}

Show-WarningOrInfo "Found $($toChangeFiles.Count) files $($toChangeLocationCount) lines need to reduce useless imports, checked $($checkedFilePaths.Count) files." -IsWarning $($toChangeLocationCount -gt 0)
$TimeLogger.Dispose()
