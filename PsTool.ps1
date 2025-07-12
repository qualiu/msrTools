<#
.SYNOPSIS
    Process tool for finding or stopping processes when wmic is deprecated(removed) on latest Windows 11.

.DESCRIPTION
    This script provides an alternative to wmic for process operations.
    It can find processes by name and/or command line using plain text or regex patterns.

.PARAMETER Action
    Specifies the action to perform: "Find" or "Stop"

.PARAMETER ProcessName
    Plain text process name (partial or full name)

.PARAMETER CommandLine
    Plain text command line content (partial or full text)

.PARAMETER ProcessNamePattern
    Regex pattern for process name matching

.PARAMETER CommandLinePattern
    Regex pattern for command line matching

.PARAMETER ExcludeProcessName
    Plain text process name to exclude (partial or full name)

.PARAMETER ExcludeProcessNamePattern
    Regex pattern for process name exclusion

.PARAMETER ExcludeCommandLine
    Plain text command line content to exclude (partial or full text)

.PARAMETER ExcludeCommandLinePattern
    Regex pattern for command line exclusion

.PARAMETER Head
    Output first N matching processes (-1 means no limit, default: -1)

.PARAMETER Tail
    Output last N matching processes (-1 means no limit, default: -1)

.PARAMETER IgnoreCase
    Whether to ignore case when matching (default: "true"). Accepts "1", "0", "true", or "false". Affects ProcessName, CommandLine, ProcessNamePattern, CommandLinePattern, and all Excluding parameters.

.NOTES
    The script automatically excludes itself and related tool processes from the results.

.EXAMPLE
    .\ProcessTool.ps1 -Action Find -CommandLine "java server"

.EXAMPLE
    .\ProcessTool.ps1 -Action Find -ProcessNamePattern "^note.*\.exe$"

.EXAMPLE
    .\ProcessTool.ps1 -Action Find -CommandLinePattern "java.*-X\w+" -Head 5

.EXAMPLE
    .\ProcessTool.ps1 -Action Find -ProcessName "NOTEPAD" -IgnoreCase false

.EXAMPLE
    .\ProcessTool.ps1 -Action Find -ProcessName "code" -ExcludeCommandLine "gpu-process"

.EXAMPLE
    .\ProcessTool.ps1 -Action Stop -CommandLinePattern "Visual.*?Studio" -ExcludeProcessNamePattern 2022
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("Find", "Stop")]
    [string]$Action = 'Find',

    [Parameter(Mandatory = $false)]
    [string]$ProcessName = "",

    [Parameter(Mandatory = $false)]
    [string]$CommandLine = "",

    [Parameter(Mandatory = $false)]
    [string]$ProcessNamePattern = "",

    [Parameter(Mandatory = $false)]
    [string]$CommandLinePattern = "",

    [Parameter(Mandatory = $false)]
    [string]$ExcludeProcessName = "",

    [Parameter(Mandatory = $false)]
    [string]$ExcludeProcessNamePattern = "",

    [Parameter(Mandatory = $false)]
    [string]$ExcludeCommandLine = "",

    [Parameter(Mandatory = $false)]
    [string]$ExcludeCommandLinePattern = "",

    [Parameter(Mandatory = $false)]
    [int]$Head = -1,

    [Parameter(Mandatory = $false)]
    [int]$Tail = -1,

    [Parameter(Mandatory = $false)]
    [string]$IgnoreCase = "true"
)

# Safety check for Stop action - at least one parameter must be specified
if ($Action -eq "Stop") {
    if ([string]::IsNullOrWhiteSpace($ProcessName) -and
        [string]::IsNullOrWhiteSpace($CommandLine) -and
        [string]::IsNullOrWhiteSpace($ProcessNamePattern) -and
        [string]::IsNullOrWhiteSpace($CommandLinePattern) -and
        [string]::IsNullOrWhiteSpace($ExcludeProcessName) -and
        [string]::IsNullOrWhiteSpace($ExcludeCommandLine) -and
        [string]::IsNullOrWhiteSpace($ExcludeProcessNamePattern) -and
        [string]::IsNullOrWhiteSpace($ExcludeCommandLinePattern)) {
        Write-Error "For Stop action, at least one of the following parameters must be specified: ProcessName, CommandLine, ProcessNamePattern, or CommandLinePattern"
        exit 1
    }
}

# Convert IgnoreCase parameter to boolean
$IgnoreCaseBool = $IgnoreCase -imatch "1|true|yes|on"

# Define global string comparison type based on IgnoreCase setting
$ComparisonType = if ($IgnoreCaseBool) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }

function New-RegexObject {
    param (
        [string]$Pattern,
        [bool] $IsExclusive,
        [bool] $IgnoreCase = $true
    )

    # Convert regex patterns to Regex objects at the beginning
    $regexOptions = if ($IgnoreCase) { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase } else { [System.Text.RegularExpressions.RegexOptions]::None }

    try {
        if ([string]::IsNullOrWhiteSpace($Pattern)) {
            return $null
        }
        else {
            return New-Object System.Text.RegularExpressions.Regex($Pattern, $regexOptions)
        }
    }
    catch {
        Write-Error "Invalid regex pattern: '$Pattern'. Error: $($_.Exception.Message)"
        exit 1
    }
}

$ProcessNameRegex = New-RegexObject -Pattern $ProcessNamePattern -IsExclusive $false -IgnoreCase $IgnoreCaseBool
$CommandLineRegex = New-RegexObject -Pattern $CommandLinePattern -IsExclusive $false -IgnoreCase $IgnoreCaseBool
$ExcludeProcessNameRegex = New-RegexObject -Pattern $ExcludeProcessNamePattern -IsExclusive $true -IgnoreCase $IgnoreCaseBool
$ExcludeCommandLineRegex = New-RegexObject -Pattern $ExcludeCommandLinePattern -IsExclusive $true -IgnoreCase $IgnoreCaseBool

function Get-MatchedProcesses {
    param(
        [string]$PlainProcessName = "",
        [string]$PlainCommandLine = "",
        [System.Text.RegularExpressions.Regex]$ProcessNameRegex,
        [System.Text.RegularExpressions.Regex]$CommandLineRegex,
        [string]$ExcludePlainProcessName = "",
        [string]$ExcludePlainCommandLine = "",
        [System.Text.RegularExpressions.Regex]$ExcludeProcessNameRegex,
        [System.Text.RegularExpressions.Regex]$ExcludeCommandLineRegex,
        [bool]$IgnoreCaseBool = $true
    )

    try {
        # Try CIM first (newer), then WMI, then fallback to Get-Process
        $processes = $null

        try {
            $processes = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue
        }
        catch {
            Write-Warning "CIM query failed, falling back to WMI"
            try {
                $processes = Get-WmiObject -Class Win32_Process -ErrorAction SilentlyContinue
            }
            catch {
                Write-Warning "WMI query failed, falling back to Get-Process"
            }
        }

        $allProcesses = $processes

        if (-not $processes) {
            # Fallback to Get-Process if WMI/CIM is not available
            $allProcesses = Get-Process -ErrorAction SilentlyContinue
            $processes = $allProcesses | ForEach-Object {
                try {
                    $commandLine = $_.Path
                    if ($_.MainModule -and $_.MainModule.FileName) {
                        $commandLine = $_.MainModule.FileName
                    }
                }
                catch {
                    $commandLine = $_.ProcessName
                }

                $parentId = 0
                try {
                    $parentId = (Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).ParentProcessId
                    if (-not $parentId) {
                        $parentId = (Get-WmiObject -Class Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).ParentProcessId
                    }
                }
                catch {
                    $parentId = 0
                }

                [PSCustomObject]@{
                    ParentProcessId = if ($parentId) { $parentId } else { 0 }
                    ProcessId       = $_.Id
                    Name            = if ($_.ProcessName.EndsWith(".exe")) { $_.ProcessName } else { $_.ProcessName + ".exe" }
                    CommandLine     = $commandLine
                }
            }
        }
        else {
            $processes = $processes | ForEach-Object {
                [PSCustomObject]@{
                    ParentProcessId = if ($_.ParentProcessId) { $_.ParentProcessId } else { 0 }
                    ProcessId       = $_.ProcessId
                    Name            = if (-not [string]::IsNullOrEmpty($_.Name)) { $_.Name } else { "" }
                    CommandLine     = if (-not [string]::IsNullOrEmpty($_.CommandLine)) { $_.CommandLine } else { $_.Name }
                }
            }
        }

        # Filter by plain process name (case-sensitive or case-insensitive based on IgnoreCaseBool parameter)
        if (-not [string]::IsNullOrEmpty($PlainProcessName)) {
            $processes = $processes | Where-Object {
                -not [string]::IsNullOrEmpty($_.Name) -and (
                    $_.Name.Contains($PlainProcessName, $ComparisonType)
                )
            }
        }

        # Filter by plain command line text (case-sensitive or case-insensitive based on IgnoreCaseBool parameter)
        if (-not [string]::IsNullOrEmpty($PlainCommandLine)) {
            $processes = $processes | Where-Object {
                -not [string]::IsNullOrEmpty($_.CommandLine) -and (
                    $_.CommandLine.Contains($PlainCommandLine, $ComparisonType)
                )
            }
        }

        $processes = $processes | Where-Object { (-not $ProcessNameRegex) -or (-not [string]::IsNullOrEmpty($_.Name) -and $ProcessNameRegex.IsMatch($_.Name)) }
        $processes = $processes | Where-Object { (-not $ExcludeProcessNameRegex) -or ([string]::IsNullOrEmpty($_.Name) -or -not $ExcludeProcessNameRegex.IsMatch($_.Name)) }
        $processes = $processes | Where-Object { (-not $CommandLineRegex) -or (-not [string]::IsNullOrEmpty($_.CommandLine) -and $CommandLineRegex.IsMatch($_.CommandLine)) }
        $processes = $processes | Where-Object { (-not $ExcludeCommandLineRegex) -or ([string]::IsNullOrEmpty($_.CommandLine) -or -not $ExcludeCommandLineRegex.IsMatch($_.CommandLine)) }

        # Exclude self process (ProcessTool.ps1 execution and related tools)
        $currentPid = $PID

        # Find current process and check its parent
        $currentProcess = $processes | Where-Object { $_.ProcessId -eq $currentPid }
        $excludePIDs = @()
        # Write-Host "Current process ID: $currentPid, Parent Process ID: $($currentProcess.ParentProcessId)"
        if ($currentProcess -and $currentProcess.ParentProcessId -gt 0) {
            $excludeProcesses = $allProcesses | Where-Object { $_.Parent -eq $currentProcess.ParentProcessId -or $_.ParentProcessId -eq $currentProcess.ParentProcessId }
            # $excludeProcesses | ForEach-Object { Write-Host "Exclude process $($_.ProcessId) with ParentProcessId = $($_.ParentProcessId) , Name = $($_.Name), CommandLine = $($_.CommandLine)" }
            $excludePIDs = $excludeProcesses | ForEach-Object { $_.ProcessId }
        }

        $processes = $processes | Where-Object {
            ($_.ProcessId -ne $currentPid) -and ($_.ProcessId -notin $excludePIDs)
        }

        # Exclude by plain process name (case-sensitive or case-insensitive based on IgnoreCaseBool parameter)
        if (-not [string]::IsNullOrEmpty($ExcludePlainProcessName)) {
            $processes = $processes | Where-Object {
                [string]::IsNullOrEmpty($_.Name) -or -not ($_.Name.Contains($ExcludePlainProcessName, $ComparisonType))
            }
        }

        # Exclude by plain command line text (case-sensitive or case-insensitive based on IgnoreCaseBool parameter)
        if (-not [string]::IsNullOrEmpty($ExcludePlainCommandLine)) {
            $processes = $processes | Where-Object {
                [string]::IsNullOrEmpty($_.CommandLine) -or -not ($_.CommandLine.Contains($ExcludePlainCommandLine, $ComparisonType))
            }
        }

        return $processes
    }
    catch {
        Write-Error "Failed to get process information: $($_.Exception.Message)"
        return @()
    }
}

function Find-Processes {
    param(
        [string]$PlainProcessName = "",
        [string]$PlainCommandLine = "",
        [System.Text.RegularExpressions.Regex]$ProcessNameRegex,
        [System.Text.RegularExpressions.Regex]$CommandLineRegex,
        [string]$ExcludePlainProcessName = "",
        [string]$ExcludePlainCommandLine = "",
        [System.Text.RegularExpressions.Regex]$ExcludeProcessNameRegex,
        [System.Text.RegularExpressions.Regex]$ExcludeCommandLineRegex,
        [int]$Head = -1,
        [int]$Tail = -1,
        [bool]$IgnoreCaseBool = $true
    )

    $processes = Get-MatchedProcesses -PlainProcessName $PlainProcessName -PlainCommandLine $PlainCommandLine -ProcessNameRegex $ProcessNameRegex -CommandLineRegex $CommandLineRegex -ExcludePlainProcessName $ExcludePlainProcessName -ExcludePlainCommandLine $ExcludePlainCommandLine -ExcludeProcessNameRegex $ExcludeProcessNameRegex -ExcludeCommandLineRegex $ExcludeCommandLineRegex -IgnoreCaseBool $IgnoreCaseBool

    if ($processes.Count -eq 0) {
        Write-Host "No matching processes found."
        return
    }

    # Apply Head and Tail filtering
    $outputProcesses = @()

    if ($Head -gt 0 -and $Tail -gt 0) {
        # Both Head and Tail specified - get first Head and last Tail, avoiding duplicates
        $headProcesses = $processes | Select-Object -First $Head
        $tailProcesses = $processes | Select-Object -Last $Tail

        # Combine and remove duplicates based on ProcessId
        $combined = @($headProcesses) + @($tailProcesses)
        $outputProcesses = $combined | Sort-Object ProcessId -Unique
    }
    elseif ($Head -gt 0) {
        # Only Head specified
        $outputProcesses = $processes | Select-Object -First $Head
    }
    elseif ($Tail -gt 0) {
        # Only Tail specified
        $outputProcesses = $processes | Select-Object -Last $Tail
    }
    else {
        # No limits specified
        $outputProcesses = $processes
    }

    # Sort by ProcessId before output
    $outputProcesses = $outputProcesses | Sort-Object ProcessId

    # Output in the same format as wmic: ParentProcessId ProcessId Name CommandLine (tab-separated)
    foreach ($proc in $outputProcesses) {
        $parentId = if ($proc.ParentProcessId) { $proc.ParentProcessId } else { "0" }
        $processId = if ($proc.ProcessId) { $proc.ProcessId } else { "0" }
        $name = if (-not [string]::IsNullOrEmpty($proc.Name)) { $proc.Name } else { "" }
        $cmdLine = if (-not [string]::IsNullOrEmpty($proc.CommandLine)) { $proc.CommandLine } else { "" }
        Write-Output "$parentId`t$processId`t$name`t$cmdLine"
    }

    Write-Host "$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz')) Found $($processes.Count) matched processes." -ForegroundColor Green
}

function Stop-Processes {
    param(
        [string]$PlainProcessName = "",
        [string]$PlainCommandLine = "",
        [System.Text.RegularExpressions.Regex]$ProcessNameRegex,
        [System.Text.RegularExpressions.Regex]$CommandLineRegex,
        [string]$ExcludePlainProcessName = "",
        [string]$ExcludePlainCommandLine = "",
        [System.Text.RegularExpressions.Regex]$ExcludeProcessNameRegex,
        [System.Text.RegularExpressions.Regex]$ExcludeCommandLineRegex,
        [bool]$IgnoreCaseBool = $true
    )

    $processes = Get-MatchedProcesses -PlainProcessName $PlainProcessName -PlainCommandLine $PlainCommandLine -ProcessNameRegex $ProcessNameRegex -CommandLineRegex $CommandLineRegex -ExcludePlainProcessName $ExcludePlainProcessName -ExcludePlainCommandLine $ExcludePlainCommandLine -ExcludeProcessNameRegex $ExcludeProcessNameRegex -ExcludeCommandLineRegex $ExcludeCommandLineRegex -IgnoreCaseBool $IgnoreCaseBool

    if ($processes.Count -eq 0) {
        Write-Host "No matching processes found to terminate."
        return
    }

    # Sort processes by ProcessId for consistent output
    $processes = $processes | Sort-Object ProcessId | Where-Object { $_.ProcessId -gt 0 }
    foreach ($proc in $processes) {
        $parentId = if ($proc.ParentProcessId) { $proc.ParentProcessId } else { "0" }
        $processId = if ($proc.ProcessId) { $proc.ProcessId } else { "0" }
        $name = if (-not [string]::IsNullOrEmpty($proc.Name)) { $proc.Name } else { "" }
        $cmdLine = if (-not [string]::IsNullOrEmpty($proc.CommandLine)) { $proc.CommandLine } else { "" }
        Write-Output "$parentId`t$processId`t$name`t$cmdLine"
    }

    # Extract process IDs for batch killing
    $processIds = $processes | ForEach-Object { $_.ProcessId }
    if ($processIds.Count -eq 0) {
        Write-Host "No matching process to terminate."
        return
    }

    # Use batch termination with Stop-Process (more efficient and handles dependencies better)
    Write-Debug "Attempting to terminate $($processIds.Count) processes using batch operation..."

    try {
        # Use Stop-Process with multiple IDs for batch termination
        Stop-Process -Id $processIds -Force -ErrorAction Stop

        # Wait a moment for processes to terminate
        Start-Sleep -Milliseconds 500

        # Check which processes were successfully terminated
        $succeededCount = 0
        $failedCount = 0

        foreach ($processId in $processIds) {
            $stillRunning = Get-Process -Id $processId -ErrorAction SilentlyContinue
            $procName = ($processes | Where-Object { $_.ProcessId -eq $processId }).Name

            if (-not $stillRunning) {
                $succeededCount++
                Write-Debug "Successfully terminated process $processId ($procName)"
            }
            else {
                $failedCount++
                Write-Warning "Failed to terminate process $processId ($procName) - process still running."
            }
        }

        Write-Debug "Batch termination result: $succeededCount/$($processIds.Count) processes terminated successfully."
        if ($failedCount -gt 0) {
            Write-Warning "Remains $failedCount processes could not be terminated (may be protected or have dependencies)."
        }
        else {
            Write-Host "$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz')) Successfully terminated $($processIds.Count) processes." -ForegroundColor Green
        }
    }
    catch {
        Write-Error "Batch termination failed: $($_.Exception.Message)"
        Write-Error "This may be due to insufficient permissions, protected processes, or process dependencies."
    }
}

# Main execution
try {
    switch ($Action) {
        "Find" {
            Find-Processes -PlainProcessName $ProcessName -PlainCommandLine $CommandLine -ProcessNameRegex $ProcessNameRegex -CommandLineRegex $CommandLineRegex -ExcludePlainProcessName $ExcludeProcessName -ExcludePlainCommandLine $ExcludeCommandLine -ExcludeProcessNameRegex $ExcludeProcessNameRegex -ExcludeCommandLineRegex $ExcludeCommandLineRegex -Head $Head -Tail $Tail -IgnoreCaseBool $IgnoreCaseBool
        }
        "Stop" {
            Stop-Processes -PlainProcessName $ProcessName -PlainCommandLine $CommandLine -ProcessNameRegex $ProcessNameRegex -CommandLineRegex $CommandLineRegex -ExcludePlainProcessName $ExcludeProcessName -ExcludePlainCommandLine $ExcludeCommandLine -ExcludeProcessNameRegex $ExcludeProcessNameRegex -ExcludeCommandLineRegex $ExcludeCommandLineRegex -IgnoreCaseBool $IgnoreCaseBool
        }
    }
}
catch {
    Write-Error "Error executing action '$Action': $($_.Exception.Message)"
    exit 1
}
