<#
.DESCRIPTION
    Open clicked file path from terminal in Visual Studio (like VS 2022) and auto locate the row + column.

.Parameter Arg1
    File path or row number.

.Parameter Arg2
    Row number or file path (if not input file path to Arg1 - for ConEmu terminal).

.Parameter Arg3
    Column number (optional).

.EXAMPLE
    .\Open-ClickedPathRow-in-VisualStudio.ps1 C:\code\my-code.cs 100 23
    .\Open-ClickedPathRow-in-VisualStudio.ps1 C:\code\my-code.cs:100:23:
    .\Open-ClickedPathRow-in-VisualStudio.ps1 C:\code\my-code.cs:100:
    .\Open-ClickedPathRow-in-VisualStudio.ps1 C:\code\my-code.cs 100
    .\Open-ClickedPathRow-in-VisualStudio.ps1 C:\code\my-code.cs
    .\Open-ClickedPathRow-in-VisualStudio.ps1 100 C:\code\my-code.cs
    .\Open-ClickedPathRow-in-VisualStudio.ps1 100 C:\code\my-code.cs 23
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Arg1,
    [string] $Arg2,
    [string] $Arg3,
    [switch] $WaitClose
)

$BeginTime = Get-Date

function Get-FilePathRowColumn {
    [int]$rowNumber = 0
    [int]$columnNumber = 0
    $filePath = ''
    $inputArgs = @($Arg1, $Arg2, $Arg3)
    foreach ($arg in $inputArgs) {
        $match = [Regex]::Match($filePath, "^(?<filePath>.+?):(?<rowNumber>\d+)(:(?<columnNumber>\d+))?")
        if ($match.Success) {
            $filePath = $match.Groups["filePath"].Value
            $rowNumber = [int]$match.Groups["rowNumber"].Value
            if ($match.Groups["columnNumber"].Success) {
                $columnNumber = [int]$match.Groups["columnNumber"].Value
            }
        }
        else {
            if ($arg -match "^\d+$") {
                if ($rowNumber -eq 0) {
                    $rowNumber = [int]$arg
                }
                else {
                    $columnNumber = [int]$arg
                }
            }
            elseif ([string]::IsNullOrWhiteSpace($filePath)) {
                $filePath = $arg
            }
        }
    }
    return @($filePath, $rowNumber, $columnNumber)
}

function Get-ActiveVisualStudioInstance {
    param (
        [string] $Name = 'devenv'
    )
    $vsProcesses = Get-Process -Name $Name -ErrorAction SilentlyContinue
    if ($vsProcesses) {
        foreach ($process in $vsProcesses) {
            $mainWindowHandle = $process.MainWindowHandle
            if ($mainWindowHandle -ne [IntPtr]::Zero) {
                return $process
            }
        }
    }
    Write-Error "Failed to find an active Visual Studio instance."
    Start-Sleep -Seconds 5
    return $null
}

function Get-AvailableVisualStudioProgIDs {
    # Dynamically discover available Visual Studio COM ProgIDs by checking registry
    $progIds = @()

    # Add generic version first
    $progIds += "VisualStudio.DTE"

    # Check registry for installed Visual Studio versions
    $registryPaths = @(
        "HKLM:\SOFTWARE\Classes\VisualStudio.DTE.*",
        "HKLM:\SOFTWARE\WOW6432Node\Classes\VisualStudio.DTE.*"
    )

    foreach ($registryPath in $registryPaths) {
        try {
            $keys = Get-ChildItem -Path ($registryPath -replace '\.\*$', '') -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'VisualStudio\.DTE\.\d+\.\d+$' }

            foreach ($key in $keys) {
                $progId = Split-Path $key.Name -Leaf
                if ($progId -match '^VisualStudio\.DTE\.\d+\.\d+$' -and $progIds -notcontains $progId) {
                    $progIds += $progId
                }
            }
        }
        catch {
            # Registry access might fail, continue silently
        }
    }

    # Add some common versions as fallback (in case registry detection fails)
    $fallbackProgIds = @(
        "VisualStudio.DTE.17.0",  # VS 2022
        "VisualStudio.DTE.16.0",  # VS 2019
        "VisualStudio.DTE.15.0",  # VS 2017
        "VisualStudio.DTE.14.0",  # VS 2015
        "VisualStudio.DTE.12.0",  # VS 2013
        "VisualStudio.DTE.11.0",  # VS 2012
        "VisualStudio.DTE.10.0"   # VS 2010
    )

    foreach ($fallbackProgId in $fallbackProgIds) {
        if ($progIds -notcontains $fallbackProgId) {
            $progIds += $fallbackProgId
        }
    }

    # Sort by version number (descending) - newer versions first
    $sortedProgIds = $progIds | Where-Object { $_ -match '\d+\.\d+$' } |
    Sort-Object {
        if ($_ -match '(\d+)\.(\d+)$') {
            [int]$matches[1] * 100 + [int]$matches[2]
        }
        else { 0 }
    } -Descending

    # Add generic version at the end
    $genericProgId = $progIds | Where-Object { $_ -eq "VisualStudio.DTE" }

    return $sortedProgIds + $genericProgId
}

function Get-VisualStudioDTE {
    # Dynamically get available Visual Studio COM ProgIDs
    $progIds = Get-AvailableVisualStudioProgIDs

    Write-Host "Detected Visual Studio COM ProgIDs: $($progIds -join ', ')" -ForegroundColor Cyan

    foreach ($progId in $progIds) {
        try {
            Write-Host "Attempting to connect to $progId ..." -ForegroundColor Yellow
            $dte = [Runtime.InteropServices.Marshal]::GetActiveObject($progId)
            if ($dte) {
                Write-Host "Successfully connected to $progId" -ForegroundColor Green
                return $dte
            }
        }
        catch {
            Write-Host "Cannot connect to $progId : $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    return $null
}

function Select-FileRowColumnInVisualStudio {
    param (
        [string] $FilePath,
        [int] $LineNumber,
        [int] $ColumnNumber
    )

    # Check if Visual Studio is running
    $vsInstance = Get-ActiveVisualStudioInstance
    if (-not $vsInstance) {
        Write-Host "No running Visual Studio instance found. Please start Visual Studio first." -ForegroundColor Red
        return
    }

    # Try to get DTE object
    $dte = Get-VisualStudioDTE
    if (-not $dte) {
        Write-Host "Cannot connect to Visual Studio via COM interface." -ForegroundColor Red
        Write-Host "Possible solutions:" -ForegroundColor Yellow
        Write-Host "1. Ensure Visual Studio is fully loaded (not just starting up)" -ForegroundColor White
        Write-Host "2. Run this script as Administrator" -ForegroundColor White
        Write-Host "3. Restart Visual Studio and wait for it to fully load" -ForegroundColor White
        Write-Host "4. Check if any Visual Studio COM ProgIDs were detected above" -ForegroundColor White
        return
    }

    try {
        $dte.MainWindow.Activate()
        [void] $dte.ItemOperations.OpenFile($FilePath)
        $dte.ExecuteCommand("View.TrackActivityInSolutionExplorer")
        $selection = $dte.ActiveDocument.Selection
        if ($LineNumber -gt 1 -and $selection) {
            $selection.GotoLine($LineNumber, $true)
            if ($ColumnNumber -gt 0) {
                $selection.MoveToLineAndOffset($LineNumber, $ColumnNumber)
            }
        }
        Write-Host "File opened in Visual Studio and navigated to specified location" -ForegroundColor Green
    }
    catch {
        Write-Host "Error operating Visual Studio: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "This may happen if Visual Studio is busy or the file cannot be opened." -ForegroundColor Yellow
    }
}

function Close-ParentTerminal {
    param (
        [string] $FilePath,
        [int] $MaxDurationSeconds = 6
    )
    # Terminate ConEmu process if it was started within max seconds
    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, Name, CommandLine, CreationDate
    foreach ($process in $processes) {
        if ($process.Name -imatch '^ConEmu\w*' -and ($process.CommandLine -and $process.CommandLine.Contains($FilePath))) {
            Write-Host "PID = $($process.ProcessId), Name = $($process.Name), StartTime = $($process.CreationDate.ToString('o')), CommandLine = $($process.CommandLine)"
            if ($process.CreationDate -and $($BeginTime - $process.CreationDate) -lt [TimeSpan]::FromSeconds($MaxDurationSeconds)) {
                Write-Host "Will terminate process: $($process.ProcessId)"
                if (-not $WaitClose) {
                    Stop-Process -Id $process.ProcessId -Force
                }
                break
            }
        }
    }
}

$FilePath, $LineNumber, $ColumnNumber = Get-FilePathRowColumn
Write-Host "Opening $FilePath and locate to row = $LineNumber, column = $ColumnNumber" -ForegroundColor Green
Select-FileRowColumnInVisualStudio -FilePath $FilePath -LineNumber $LineNumber -ColumnNumber $ColumnNumber
Close-ParentTerminal -FilePath $FilePath
