<#
.SYNOPSIS
    Process tool for finding or stopping processes when wmic is deprecated(removed) on latest Windows 11.

.DESCRIPTION
    This script provides an alternative to wmic for process operations.
    It can find processes by name and/or command line using plain text or regex patterns.
    It also supports finding or stopping processes by specific process IDs.

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

.PARAMETER Ids
    Comma-separated list of specific process IDs to find or stop (e.g., "123,456,789")

.PARAMETER ExcludeProcessName
    Plain text process name to exclude (partial or full name)

.PARAMETER ExcludeProcessNamePattern
    Regex pattern for process name exclusion

.PARAMETER ExcludeCommandLine
    Plain text command line content to exclude (partial or full text)

.PARAMETER ExcludeCommandLinePattern
    Regex pattern for command line exclusion

.PARAMETER MatchAllPattern
    Regex pattern that matches against process ID, parent process ID, process name, or command line (any one match is sufficient)

.PARAMETER MatchAllText
    Plain text that matches against process ID, parent process ID, process name, or command line using string contains (any one match is sufficient)

.PARAMETER ExcludeAllPattern
    Regex pattern that excludes processes when matched against process ID, parent process ID, process name, or command line (any one match excludes the process)

.PARAMETER ExcludeAllText
    Plain text that excludes processes when found in process ID, parent process ID, process name, or command line using string contains (any one match excludes the process)

.PARAMETER NoHeader
    Whether to suppress header output (default: "false"). Accepts "1", "0", "true", or "false". When true, suppresses "ParentId PID Name CommandLine" header.

.PARAMETER NoSummary
    Whether to suppress summary output (default: "false"). Accepts "1", "0", "true", or "false". When true, suppresses summary messages like "Found X processes" or "Successfully terminated Y processes".

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

.EXAMPLE
    .\ProcessTool.ps1 -Action Find -Ids "123,456,789"

.EXAMPLE
    .\ProcessTool.ps1 -Action Find -MatchAllPattern "java.*-X\w+"

.EXAMPLE
    .\ProcessTool.ps1 -Action Find -MatchAllText "java server"

.EXAMPLE
    .\ProcessTool.ps1 -Action Find -ExcludeAllPattern "^(System|Registry)"

.EXAMPLE
    .\ProcessTool.ps1 -Action Find -ExcludeAllText "gpu-process"

.EXAMPLE
    .\ProcessTool.ps1 -Action Find -ProcessName "notepad" -NoHeader "true" -NoSummary "true"
#>

[CmdletBinding()]
param(
    [ValidateSet("Find", "Stop")] [string]$Action = 'Find',
    [string]$ProcessName = "",
    [string]$CommandLine = "",
    [string]$ProcessNamePattern = "",
    [string]$CommandLinePattern = "",
    $Ids = $null,
    [string]$ExcludeProcessName = "",
    [string]$ExcludeProcessNamePattern = "",
    [string]$ExcludeCommandLine = "",
    [string]$ExcludeCommandLinePattern = "",
    [string]$MatchAllPattern = "",
    [string]$MatchAllText = "",
    [string]$ExcludeAllPattern = "",
    [string]$ExcludeAllText = "",
    [string]$NoHeader = "false",
    [string]$NoSummary = "false",
    [int]$Head = -1,
    [int]$Tail = -1,
    [string]$IgnoreCase = "true",
    [string]$OutToStderrForHeaderSummary = "false"
)

# Function to check if any search criteria is specified
function Test-HasSearchCriteria {
    # Use script-level parameters directly
    return -not (
        [string]::IsNullOrWhiteSpace($ProcessName) -and
        [string]::IsNullOrWhiteSpace($CommandLine) -and
        [string]::IsNullOrWhiteSpace($ProcessNamePattern) -and
        [string]::IsNullOrWhiteSpace($CommandLinePattern) -and
        [string]::IsNullOrWhiteSpace($Ids) -and
        [string]::IsNullOrWhiteSpace($ExcludeProcessName) -and
        [string]::IsNullOrWhiteSpace($ExcludeCommandLine) -and
        [string]::IsNullOrWhiteSpace($ExcludeProcessNamePattern) -and
        [string]::IsNullOrWhiteSpace($ExcludeCommandLinePattern) -and
        [string]::IsNullOrWhiteSpace($MatchAllPattern) -and
        [string]::IsNullOrWhiteSpace($MatchAllText) -and
        [string]::IsNullOrWhiteSpace($ExcludeAllPattern) -and
        [string]::IsNullOrWhiteSpace($ExcludeAllText)
    )
}

function Get-NowText {
    param (
        [string]$Format = "yyyy-MM-dd HH:mm:ss zzz"
    )
    return (Get-Date).ToString($Format)
}

# Safety check for Stop action - at least one parameter must be specified
if ($Action -eq "Stop") {
    if (-not (Test-HasSearchCriteria)) {
        Write-Error "For Stop action, at least one of the following parameters must be specified: ProcessName, CommandLine, ProcessNamePattern, CommandLinePattern, or Ids"
        exit 1
    }
}

$ProcessIdList = @()
if (-not [string]::IsNullOrWhiteSpace($Ids)) {
    if ($Ids -notmatch '^\d+[\d, ]*$') {
        throw "Invalid Ids format: '$Ids'. Expected format: '123,456,789' or '123' (comma-separated list of integers)."
    }
    $ProcessIdList = @($Ids) | ForEach-Object { "$_" -split ',' } | ForEach-Object { [int] $_.Trim() }
}

$IgnoreCaseBool = $IgnoreCase -imatch "1|true|yes|on"
$NoHeaderBool = $NoHeader -imatch "1|true|yes|on"
$NoSummaryBool = $NoSummary -imatch "1|true|yes|on"
$OutToStderrForHeaderSummaryBool = $OutToStderrForHeaderSummary -imatch "1|true|yes|on"

$script:MatchedProcessCount = 0

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
$MatchAllRegex = New-RegexObject -Pattern $MatchAllPattern -IsExclusive $false -IgnoreCase $IgnoreCaseBool
$ExcludeAllRegex = New-RegexObject -Pattern $ExcludeAllPattern -IsExclusive $true -IgnoreCase $IgnoreCaseBool

# Function to check if parent/self process should be excluded based on tool execution patterns
function Test-ShouldExcludeSelfProcess {
    param(
        [PSCustomObject]$Process
    )

    # Check if it's a msr.exe process (msr tool used by our scripts)
    if ($Process.Name -imatch '^(msr)(\.exe)?$') {
        return $true
    }

    # Check if it's a cmd.exe process that is executing our scripts
    if ($Process.Name -imatch '^(cmd)(\.exe)?$' -and -not [string]::IsNullOrEmpty($Process.CommandLine)) {
        if ($Process.CommandLine -match "\b(psall\.bat|pskill\.bat)\b") {
            return $true
        }
    }

    # Check if it's PowerShell executing PsTool.ps1
    if (($Process.Name -imatch '^(pwsh|PowerShell)(\.exe)?$') -and
        -not [string]::IsNullOrEmpty($Process.CommandLine)) {
        if ($Process.CommandLine -match "\b(PsTool\.ps1)\b") {
            return $true
        }
    }

    return $false
}

# Function to get parent/self processes that should be excluded from results
function Get-ExcludedSelfProcessIds {
    param(
        [array]$AllProcesses,
        [int]$CurrentPid,
        [string]$PlainCommandLine = "",
        [string]$CommandLinePattern = ""
    )

    $excludePIDs = @()


    # Exclude current process (PsTool.ps1)
    $excludePIDs += $CurrentPid

    # Find parent process information
    $currentProcess = $AllProcesses | Where-Object { $_.ProcessId -eq $CurrentPid } | Select-Object -First 1
    if ($currentProcess -and $currentProcess.ParentProcessId -gt 0) {
        $parentProcess = $AllProcesses | Where-Object { $_.ProcessId -eq $currentProcess.ParentProcessId } | Select-Object -First 1

        if ($parentProcess) {
            # Exclude parent process (usually cmd.exe that calls psall.bat/pskill.bat)
            $excludePIDs += $parentProcess.ProcessId

            # Find all child processes of the parent (siblings of current process)
            $siblings = $AllProcesses | Where-Object { $_.ParentProcessId -eq $parentProcess.ProcessId }

            foreach ($sibling in $siblings) {
                # Only exclude processes that are actually executing our tools, not just referencing them
                if (Test-ShouldExcludeSelfProcess -Process $sibling) {
                    $excludePIDs += $sibling.ProcessId
                }
            }

            # Also check grandparent level if parent is cmd.exe (often the case)
            if (($parentProcess.Name -imatch '^(cmd)(\.exe)?$') -and $parentProcess.ParentProcessId -gt 0) {
                $grandparentProcess = $AllProcesses | Where-Object { $_.ProcessId -eq $parentProcess.ParentProcessId } | Select-Object -First 1
                if ($grandparentProcess) {
                    # Find all children of grandparent that might be related to our tools
                    $grandparentChildren = $AllProcesses | Where-Object { $_.ParentProcessId -eq $grandparentProcess.ProcessId }
                    foreach ($child in $grandparentChildren) {
                        # Only exclude processes that are actually executing our tools
                        if (Test-ShouldExcludeSelfProcess -Process $child) {
                            $excludePIDs += $child.ProcessId
                        }
                    }
                }
            }
        }
    }

    return $excludePIDs | Sort-Object -Unique
}

# Function to get all processes with normalized structure
function Get-AllProcesses {
    try {
        # Try CIM first (newer), then WMI, then fallback to Get-Process
        $processes = $null

        if ($IsWindows) {
            try {
                $processes = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue
            }
            catch {
                Write-Debug "CIM query failed, falling back to WMI"
                try {
                    $processes = Get-WmiObject -Class Win32_Process -ErrorAction SilentlyContinue
                }
                catch {
                    Write-Debug "WMI query failed, falling back to Get-Process"
                }
            }
        }

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

        return $processes
    }
    catch {
        Write-Error "Failed to get process information: $($_.Exception.Message)"
        return @()
    }
}

# Function to get ANSI colored message
function Get-AnsiColoredMessage {
    param (
        [string] $Message,
        [string] $Color = "White"
    )

    # ANSI color codes
    $ansiColors = @{
        "Black"       = "`e[30m"
        "DarkRed"     = "`e[31m"
        "DarkGreen"   = "`e[32m"
        "DarkYellow"  = "`e[33m"
        "DarkBlue"    = "`e[34m"
        "DarkMagenta" = "`e[35m"
        "DarkCyan"    = "`e[36m"
        "Gray"        = "`e[37m"
        "DarkGray"    = "`e[90m"
        "Red"         = "`e[91m"
        "Green"       = "`e[92m"
        "Yellow"      = "`e[93m"
        "Blue"        = "`e[94m"
        "Magenta"     = "`e[95m"
        "Cyan"        = "`e[96m"
        "White"       = "`e[97m"
    }

    $resetCode = "`e[0m"

    if ($ansiColors.ContainsKey($Color)) {
        return "$($ansiColors[$Color])$Message$resetCode"
    }
    else {
        return $Message
    }
}

# Function to format process output
function Format-ProcessOutput {
    param(
        [PSCustomObject]$Process
    )

    $parentId = if ($Process.ParentProcessId) { $Process.ParentProcessId } else { "0" }
    $processId = if ($Process.ProcessId) { $Process.ProcessId } else { "0" }
    $name = if (-not [string]::IsNullOrEmpty($Process.Name)) { $Process.Name } else { "" }
    $cmdLine = if (-not [string]::IsNullOrEmpty($Process.CommandLine)) { $Process.CommandLine } else { "" }

    return "$parentId`t$processId`t$name`t$cmdLine"
}

function Out-StderrMessage {
    param (
        [string] $Message,
        [string] $Color = "White"
    )

    if ($OutToStderrForHeaderSummaryBool) {
        $Message = if ([string]::IsNullOrWhiteSpace($Color)) { $Message } else { Get-AnsiColoredMessage -Message $Message -Color $Color }
        [Console]::Error.WriteLine($Message)
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Color)) {
            Write-Host $Message
        }
        else {
            Write-Host (Get-AnsiColoredMessage -Message $Message -Color $Color)
        }
    }
}

# Function to output result header if not suppressed
function Out-ResultHeader {
    if (-not $NoHeaderBool) {
        Out-StderrMessage -Message "Parent`tPID`tName`tCommandLine" -Color "Cyan"
    }
}

# Function to output result summary if not suppressed
function Out-KeyMessage {
    param(
        [string]$Message = "",
        [ValidateSet("success", "failed", "warning", "info")]
        [string]$Type = "info"
    )

    if (-not $NoSummaryBool -and -not [string]::IsNullOrEmpty($Message)) {
        $Message = "$(Get-NowText) $Message"
        switch ($Type) {
            "success" {
                Out-StderrMessage -Message $Message -Color "Green"
            }
            "failed" {
                Out-StderrMessage -Message $Message -Color "Red"
            }
            "warning" {
                Out-StderrMessage -Message $Message -Color "Yellow"
            }
            "info" {
                Out-StderrMessage -Message $Message -Color "Cyan"
            }
        }
    }
}

# Function to apply Head/Tail filtering
function Get-FilteredByHeadTail {
    param(
        [array]$Processes,
        [int]$Head = -1,
        [int]$Tail = -1
    )

    $outputProcesses = @()

    if ($Head -gt 0 -and $Tail -gt 0) {
        # Both Head and Tail specified - get first Head and last Tail, avoiding duplicates
        $headProcesses = $Processes | Select-Object -First $Head
        $tailProcesses = $Processes | Select-Object -Last $Tail

        # Combine and remove duplicates based on ProcessId
        $combined = @($headProcesses) + @($tailProcesses)
        $outputProcesses = $combined | Sort-Object ProcessId -Unique
    }
    elseif ($Head -gt 0) {
        # Only Head specified
        $outputProcesses = $Processes | Select-Object -First $Head
    }
    elseif ($Tail -gt 0) {
        # Only Tail specified
        $outputProcesses = $Processes | Select-Object -Last $Tail
    }
    else {
        # No limits specified
        $outputProcesses = $Processes
    }

    return $outputProcesses
}

# Helper function to apply all-field filtering (matches or excludes based on ProcessId, ParentProcessId, Name, or CommandLine)
function Test-ProcessAllFieldsMatch {
    param(
        [PSCustomObject]$Process,
        [System.Text.RegularExpressions.Regex]$Regex = $null,
        [string]$Text = "",
        [bool]$IsExclusive = $false
    )

    # Convert ProcessId and ParentProcessId to string for matching
    $processIdStr = $Process.ProcessId.ToString()
    $parentProcessIdStr = $Process.ParentProcessId.ToString()

    # Determine match result based on regex or text matching
    $hasMatch = $false
    if ($Regex) {
        $hasMatch = ($Regex.IsMatch($processIdStr)) -or
        ($Regex.IsMatch($parentProcessIdStr)) -or
        (-not [string]::IsNullOrEmpty($Process.Name) -and $Regex.IsMatch($Process.Name)) -or
        (-not [string]::IsNullOrEmpty($Process.CommandLine) -and $Regex.IsMatch($Process.CommandLine))
    }
    elseif (-not [string]::IsNullOrEmpty($Text)) {
        $hasMatch = ($processIdStr.Contains($Text, $ComparisonType)) -or
        ($parentProcessIdStr.Contains($Text, $ComparisonType)) -or
        (-not [string]::IsNullOrEmpty($Process.Name) -and $Process.Name.Contains($Text, $ComparisonType)) -or
        (-not [string]::IsNullOrEmpty($Process.CommandLine) -and $Process.CommandLine.Contains($Text, $ComparisonType))
    }

    # Return result based on whether this is an exclusion or inclusion filter
    if ($IsExclusive) {
        return -not $hasMatch
    }
    else {
        return $hasMatch
    }
}

function Get-MatchedProcesses {
    try {
        # Get all processes with normalized structure
        $allProcesses = Get-AllProcesses
        $processes = $allProcesses

        if ($ProcessIdList.Count -gt 0) {
            $processes = $processes | Where-Object { $_.ProcessId -in $ProcessIdList }
        }

        # Filter by plain process name (case-sensitive or case-insensitive based on IgnoreCaseBool parameter)
        if (-not [string]::IsNullOrEmpty($ProcessName)) {
            $processes = $processes | Where-Object {
                -not [string]::IsNullOrEmpty($_.Name) -and (
                    $_.Name.Contains($ProcessName, $ComparisonType)
                )
            }
        }

        # Filter by plain command line text (case-sensitive or case-insensitive based on IgnoreCaseBool parameter)
        if (-not [string]::IsNullOrEmpty($CommandLine)) {
            $processes = $processes | Where-Object {
                -not [string]::IsNullOrEmpty($_.CommandLine) -and (
                    $_.CommandLine.Contains($CommandLine, $ComparisonType)
                )
            }
        }

        $processes = $processes | Where-Object { (-not $ProcessNameRegex) -or (-not [string]::IsNullOrEmpty($_.Name) -and $ProcessNameRegex.IsMatch($_.Name)) }
        $processes = $processes | Where-Object { (-not $ExcludeProcessNameRegex) -or ([string]::IsNullOrEmpty($_.Name) -or -not $ExcludeProcessNameRegex.IsMatch($_.Name)) }
        $processes = $processes | Where-Object { (-not $CommandLineRegex) -or (-not [string]::IsNullOrEmpty($_.CommandLine) -and $CommandLineRegex.IsMatch($_.CommandLine)) }
        $processes = $processes | Where-Object { (-not $ExcludeCommandLineRegex) -or ([string]::IsNullOrEmpty($_.CommandLine) -or -not $ExcludeCommandLineRegex.IsMatch($_.CommandLine)) }

        if ($MatchAllRegex) {
            $processes = $processes | Where-Object { Test-ProcessAllFieldsMatch -Process $_ -Regex $MatchAllRegex -IsExclusive $false }
        }

        if (-not [string]::IsNullOrEmpty($MatchAllText)) {
            $processes = $processes | Where-Object { Test-ProcessAllFieldsMatch -Process $_ -Text $MatchAllText -IsExclusive $false }
        }

        if ($ExcludeAllRegex) {
            $processes = $processes | Where-Object { Test-ProcessAllFieldsMatch -Process $_ -Regex $ExcludeAllRegex -IsExclusive $true }
        }

        if (-not [string]::IsNullOrEmpty($ExcludeAllText)) {
            $processes = $processes | Where-Object { Test-ProcessAllFieldsMatch -Process $_ -Text $ExcludeAllText -IsExclusive $true }
        }

        # Get processes to exclude (self and related tool processes)
        $excludePIDs = Get-ExcludedSelfProcessIds -AllProcesses $allProcesses -CurrentPid $PID -PlainCommandLine $CommandLine -CommandLinePattern $CommandLinePattern

        # Filter out excluded processes
        $processes = $processes | Where-Object {
            $_.ProcessId -notin $excludePIDs
        }

        # Exclude by plain process name (case-sensitive or case-insensitive based on IgnoreCaseBool parameter)
        if (-not [string]::IsNullOrEmpty($ExcludeProcessName)) {
            $processes = $processes | Where-Object {
                [string]::IsNullOrEmpty($_.Name) -or -not ($_.Name.Contains($ExcludeProcessName, $ComparisonType))
            }
        }

        # Exclude by plain command line text (case-sensitive or case-insensitive based on IgnoreCaseBool parameter)
        if (-not [string]::IsNullOrEmpty($ExcludeCommandLine)) {
            $processes = $processes | Where-Object {
                [string]::IsNullOrEmpty($_.CommandLine) -or -not ($_.CommandLine.Contains($ExcludeCommandLine, $ComparisonType))
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
    $processes = Get-MatchedProcesses
    $script:MatchedProcessCount = $processes.Count

    if ($processes.Count -eq 0) {
        Out-KeyMessage -Message "No matching processes found." -Type "warning"
        return
    }

    # Apply Head and Tail filtering
    $outputProcesses = Get-FilteredByHeadTail -Processes $processes -Head $Head -Tail $Tail

    # Sort by ProcessId before output
    $outputProcesses = $outputProcesses | Sort-Object ProcessId

    # Output header
    Out-ResultHeader

    # Output in the same format as wmic: ParentProcessId ProcessId Name CommandLine (tab-separated)
    foreach ($proc in $outputProcesses) {
        Write-Output (Format-ProcessOutput -Process $proc)
    }

    Out-KeyMessage -Message "Found $($processes.Count) matched processes." -Type "success"
}

function Stop-Processes {
    $processes = Get-MatchedProcesses
    $script:MatchedProcessCount = $processes.Count

    if ($processes.Count -eq 0) {
        Out-KeyMessage -Message "No matching processes found to terminate." -Type "warning"
        return
    }

    # Sort processes by ProcessId for consistent output
    $processes = $processes | Sort-Object ProcessId | Where-Object { $_.ProcessId -gt 0 }

    # Output header
    Out-ResultHeader

    foreach ($proc in $processes) {
        Write-Output (Format-ProcessOutput -Process $proc)
    }

    # Extract process IDs for batch killing
    $processIds = $processes | ForEach-Object { $_.ProcessId }
    if ($processIds.Count -eq 0) {
        Out-KeyMessage -Message "No matching process to terminate." -Type "warning"
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
                Out-KeyMessage "Failed to terminate process $processId ($procName) - process still running." -Type "warning"
            }
        }

        Write-Debug "Batch termination result: $succeededCount/$($processIds.Count) processes terminated successfully."
        if ($failedCount -gt 0) {
            Out-KeyMessage -Message "Remains $failedCount processes could not be terminated (may be protected or have dependencies)." -Type "warning"
        }
        else {
            Out-KeyMessage -Message "Successfully terminated $($processIds.Count) processes." -Type "success"
        }
    }
    catch {
        Out-KeyMessage -Message "Batch termination failed: $($_.Exception.Message) This may be due to insufficient permissions, protected processes, or process dependencies." -Type "failed"
    }
}

# Main execution
try {
    switch ($Action) {
        "Find" {
            Find-Processes
        }
        "Stop" {
            Stop-Processes
        }
    }
    exit $script:MatchedProcessCount
}
catch {
    Write-Error "Error executing action '$Action': $($_.Exception.Message)"
    exit -1
}
