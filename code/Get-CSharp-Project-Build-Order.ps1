<#
.SYNOPSIS
    Get and output C# project order by dependencies.
.DESCRIPTION
    Output the path list of C# projects which are *.csproj files.
.EXAMPLE
    .\Get-CSharp-Project-Build-Order.ps1 .\
#>

[CmdletBinding()]
param(
      [Parameter(Position = 0, Mandatory = $true)][string] $SourceFolder,
      [switch]$OutSingleProjectPaths
      )

$scriptDirectory = Convert-Path $(Split-Path $PSCommandPath -Parent -Resolve)
if (! ($env:PATH -icontains $scriptDirectory)) {
    $env:PATH = $scriptDirectory + ";" + $env:PATH
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;

if( -not $(Get-Command msr.exe 2>$null) -and $(-not $(Test-Path $(Join-Path $scriptDirectory msr.exe) )) ) {
    Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile $(Join-Path $scriptDirectory msr.exe)
}

if( -not $(Get-Command nin.exe 2>$null) -and $(-not $(Test-Path $(Join-Path $scriptDirectory nin.exe) )) ) {
    Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/nin.exe?raw=true -OutFile $(Join-Path $scriptDirectory nin.exe)
}

Push-Location -Path $SourceFolder

# msr -rp . --nd "^([\.\$]|(Release|Debug|objd?|bin|node_modules|static|dist|target|(Js)?Packages|\w+-packages?)$|__pycache__)" -f "\.csproj$" -it "^\s*<ProjectReference Include=\"(.+?)\">.*" -o "$1" -M | msr -t "^(\S+\\)?([^\\]+?):\d+:\s*(\S+)" -o "$1$2\t$1$3" -PM | msr -t "([^\\\s]+)(\\)\.\.\2" -o "" -g -1 -PIC

$projectList = $(msr -rp . --nd "^([\.\$]|(Release|Debug|objd?|bin|node_modules|static|dist|target|(Js)?Packages|\w+-packages?)$|__pycache__)" -f "\.csproj$" -l -PAC) -split "`n"

$a = msr -rp . --nd "^([\.\$]|(Release|Debug|objd?|bin|node_modules|static|dist|target|(Js)?Packages|\w+-packages?)$|__pycache__)" -f "\.csproj$" -it '^\s*<ProjectReference Include=\"(.+?)\">.*' -o '\1' -M | msr -t '^(\S+\\)?([^\\]+?):\d+:\s*(\S+)' -o '\1\2\t\1\3' -PM  | msr -t '([^\\\s]+)(\\)\.\.\2' -g -1  -o '\3' -PAC

$callerToBaseProjects = New-Object 'System.Collections.Generic.Dictionary[[String],[System.Collections.Generic.HashSet[String]]]'
$baseToCallerProjects = New-Object 'System.Collections.Generic.Dictionary[[String],[System.Collections.Generic.HashSet[String]]]'

foreach($s in $a) {
    # Write-Host "s = " $s
    $p, $d = $s.Split("`t")

    $baseProjectSet = New-Object System.Collections.Generic.HashSet[String]
    if ($callerToBaseProjects.ContainsKey($p)) {
        $baseProjectSet = $callerToBaseProjects[$p]
    } else {
        $callerToBaseProjects[$p] = $baseProjectSet
    }

    $baseProjectSet.Add($d) | Out-Null

    $callerProjects = New-Object System.Collections.Generic.HashSet[String]
    if ($baseToCallerProjects.ContainsKey($d)) {
        $callerProjects = $baseToCallerProjects[$d]
    } else {
        $baseToCallerProjects[$d] = $callerProjects
    }

    $callerProjects.Add($p) | Out-Null
}

$orderedProjectList = New-Object System.Collections.Generic.List[String]($baseToCallerProjects.Keys)

function Get-Min-Caller($callerIndex, $callerProjects) {
    foreach($caller in $callerProjects) {
        $idx = $orderedProjectList.IndexOf($caller)
        if ($idx -ge 0) {
            $callerIndex = [Math]::Min($callerIndex, $idx)
        }

        if ($baseToCallerProjects.ContainsKey($caller)) {
            $subCallers = $baseToCallerProjects[$caller]
            $idxSub = Get-Min-Caller $callerIndex $subCallers
            if ($idxSub -ge 0) {
                $callerIndex = [Math]::Min($callerIndex, $idxSub)
            }
        }
    }

    return $callerIndex
}

# Write-Host "orderedProjectList.Count =" $orderedProjectList.Count
foreach($p in $baseToCallerProjects.Keys) {
    $baseIndex = $orderedProjectList.IndexOf($p)
    $callerProjects = $baseToCallerProjects[$p]
    $callerIndex = Get-Min-Caller 999999 $callerProjects
    if ($baseIndex -gt $callerIndex) {
        $tmp = $orderedProjectList[$callerIndex]
        $orderedProjectList[$callerIndex] = $p
        $orderedProjectList[$baseIndex] = $tmp
    }
}

if ($OutSingleProjectPaths) {
    foreach($p in $projectList) {
        if(-not $orderedProjectList.Contains($p)) {
            $orderedProjectList.Add($p) | Out-Null
        }
    }
}

$orderedProjectList
