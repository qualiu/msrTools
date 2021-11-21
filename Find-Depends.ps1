
<#
.DESCRIPTION
    Find dependencies of a .NET DLL/EXE file.

.Parameter ExeOrDLLFile
    File path of a .NET DLL/EXE.

.EXAMPLE

#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ExeOrDLLFile,
    [Parameter(Mandatory = $false)][int] $MaxLayer = -1,
    [Parameter(Mandatory = $false)][string] $ExemptNamePattern = "^(mscorlib|System(\.\S+)?|Microsoft.CSharp)$",
    [switch] $NotStopAtFirstError
)

$ExemptNameRegex = if ([string]::IsNullOrEmpty($ExemptNamePattern)) {
    New-Object System.Text.RegularExpressions.Regex("^###$")
} else {
    $flag = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Compiled
    New-Object System.Text.RegularExpressions.Regex($ExemptNamePattern, $flag)
}

$CheckedAssemblySet = New-Object 'System.Collections.Generic.HashSet[String]'([StringComparer]::OrdinalIgnoreCase)

function Throw_Errors {
    param (
        [string[]] $UpperFiles,
        [string] $message
    )

    Write-Host -ForegroundColor Red "The $($UpperFiles.Count) upper level files as below:"
    Write-Host -ForegroundColor Yellow ([String]::Join([System.Environment]::NewLine, $UpperFiles))
    if ($NotStopAtFirstError) {
        Write-Error $message
    } else {
        throw $message
    }
}

function Find-OneDependency {
    param (
        [string] $filePath,
        [int] $layer = 1,
        [string[]] $UpperFiles = @()
    )

    Write-Output "`nLayer[$layer] Will check dependencies of $filePath"
    $assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($filePath)) # LoadFrom($filePath) #

    $folder = [IO.Path]::GetDirectoryName($filePath)
    $searchPaths = $folder + ";" + $env:Path
    $references = $assembly.GetReferencedAssemblies()

    $UpperFiles += "$($assembly.GetName().Version.ToString()) $filePath"
    $toCheckList = @()
    foreach ($rd in $references) {
        if (-not $CheckedAssemblySet.Add("$($rd.Version) $($rd.FullName)")) {
            # Write-Output "Already checked $rd"
            continue
        }

        if ($ExemptNameRegex.IsMatch($rd.Name)) {
            Write-Output "Skip checking $rd"
            continue
        }

        $pattern = "^" + $rd.Name + "\.(dll|exe)$"
        $dependPath = msr -p $searchPaths -f $pattern -l -W -PAC 2>$null -H 1 -J
        if ([string]::IsNullOrEmpty($dependPath)) {
            Throw_Errors $UpperFiles "Cannot find dependency: $rd for $filePath"
        }

        $da = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($dependPath)) #LoadFrom($dependPath) #
        if (-not $rd.Version.Equals($da.GetName().Version)) {
            Throw_Errors $UpperFiles "Inconsistent dependency: require $rd but found $da at $dependPath for $filePath"
        }

        Write-Output "Found dependency: $rd at $dependPath"
        $toCheckList += $dependPath

        if ($($layer -lt $MaxLayer) -or $($MaxLayer -lt 0)) {
            $layer += 1
            foreach ($dp in $toCheckList) {
                Find-OneDependency $dependPath $layer $UpperFiles
            }
        }
    }
}

Find-OneDependency $ExeOrDLLFile
