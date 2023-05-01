<#
.SYNOPSIS
    Auto write or update exports for PowerShell module files (*.psm1).

.DESCRIPTION

.PARAMETER SourcePaths
    Folders or files of powershell scripts.

.PARAMETER ExcludedFolderPattern
    Regex pattern of excluded folders.

.EXAMPLE
    .\Update-PowerShell-Module-Exports.ps1 D:\msrTools
    .\Update-PowerShell-Module-Exports.ps1 BasicOsUtils.psm1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $SourcePaths,
    [string] $ExcludedFolderPattern = '^([\.\$]|(Release|Debug|objd?|bin|node_modules|static|dist|target|(Js)?Packages|\w+-packages?|wwwroot)$|__pycache__)'
)

Import-Module "$PSScriptRoot/BasicOsUtils.psm1"

$EmptyTextForMsrReplace = Get-EmptyTextForMsrReplace $MyInvocation

$UnifiedToolName = [IO.Path]::GetFileName($MyInvocation.MyCommand.Path)
$ToolComment = "# Auto generated exports by "
$LegalVerbFile = Join-Path $SysTmpFolder "legal-function-name-verbs.txt"

function Get-NowText([string] $format = "yyyy-MM-dd HH:mm:ss.fff zzz") {
    return [DateTime]::Now.ToString($format)
}

function Remove-OldExports {
    $commentsPattern = "^\s*#\s*msr.*? -o .*?(Export-\w+)"
    $commentsPattern += "|^\s*$($ToolComment)"
    $exportPattern = "^\s*Export-ModuleMember\s+-\w+"
    $searchPattern = "(" + $commentsPattern + "|" + $exportPattern + ").*"

    Write-Output "`n$(Get-NowText) Clean up existing exports ..."
    msr -rp $SourcePaths -f "\.psm1$" -it $searchPattern -o $EmptyTextForMsrReplace -R --nd $ExcludedFolderPattern -T 0

    Write-Output "`n$(Get-NowText) Set one empty tail line ..."
    msr -rp $SourcePaths -f "\.psm1$" -S -t "\s*$" -o "\n" -R --nd $ExcludedFolderPattern -M -T 0
}

function Write-Exports {
    param (
        [string] $OneFilePath
    )

    $lines = @()
    $lines += $ToolComment + $UnifiedToolName
    $lines += msr -t '^\$([A-Z]\w+)\s*=.*' -o "Export-ModuleMember -Variable \1" -PAC -p $OneFilePath
    $variableCount = $LASTEXITCODE
    $lines += msr -t "^\s*function\s+(\w+-\w+)\s*\{\s*$" -o "Export-ModuleMember -Function \1" -PAC -p $OneFilePath
    $functionCount = $LASTEXITCODE
    if ($($variableCount + $functionCount) -eq 0) {
        return
    }

    Write-Output "Exported $($variableCount) variables + $($functionCount) functions in $($OneFilePath)" | msr -aPA -e "\d+" -x $([IO.Path]::GetFileName($OneFilePath))
    Add-Content $file -Value $lines -Encoding UTF8
}

function Find-IllegalFunctionNames {
    Write-Output "`n$(Get-NowText) Check illegal function name verbs ..."
    $pattern = "Export-ModuleMember\s+-Function"
    msr -rp $SourcePaths -f "\.psm1$" --nd $ExcludedFolderPattern -it "^\s*$($pattern)" -M -C | nin $LegalVerbFile "$($pattern)\s+(\w+)" "^(\w+)" -i -w
    if ($LASTEXITCODE -gt 0) {
        Write-Output "`n$(Get-NowText) Found $($LASTEXITCODE) illegal function verbs as above." | msr -aPA -t "(Found.*?(\d+).*)"
        exit $LASTEXITCODE
    }
}

Get-Verb | ForEach-Object { Write-Output $_.Verb } | Out-File $LegalVerbFile -Encoding UTF8

$files = msr -rp $SourcePaths -l -f "\.psm1$" -PAC --nd $ExcludedFolderPattern
if ($LASTEXITCODE -lt 1) {
    Write-Output "$(Get-NowText) Not found PowerShell module files (*.psm1) in SourcePaths: $(SourcePaths)"
    exit 0
}

Remove-OldExports

Write-Output "`n$(Get-NowText) Write new exports ..."
foreach ($file in $files) {
    Write-Exports $file
    # Keep only on line-ending style (Windows) since it's easy to operate on Linux.
    if (-not $IsWindowsOS -or $(Test-ToolExistsByName 'unix2dos')) {
        unix2dos $file
    }
}

Find-IllegalFunctionNames

Write-Host -ForegroundColor Green "$(Get-NowText) Please re-enter PowerShell console/terminal if changed exports."

exit 0
