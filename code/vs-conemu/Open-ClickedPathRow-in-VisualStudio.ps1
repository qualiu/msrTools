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

function Select-FileRowColumnInVisualStudio {
    param (
        [string] $FilePath,
        [int] $LineNumber,
        [int] $ColumnNumber
    )

    $vsInstance = Get-ActiveVisualStudioInstance
    if (-not $vsInstance) {
        return
    }
    $dte = [Runtime.InteropServices.Marshal]::GetActiveObject("VisualStudio.DTE")
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
