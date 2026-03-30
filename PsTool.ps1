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

.PARAMETER ShowDescendants
    Whether to show descendant processes (default: "false"). Accepts "1", "0", "true", or "false". When true, shows child/grandchild processes in DarkGray below the matched processes. Default is false because descendants often outnumber matched processes (e.g. 200+ vs 30), adding noise to typical searches. Alias: -SD.

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
    [Alias("SD")]
    [string]$ShowDescendants = "false",
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
    if ($Ids -notmatch '^\d+[\d, ]*\d+$' -and $Ids -notmatch '^\d+$') {
        throw "Invalid Ids format: '$Ids'. Expected format: '123,456,789' or '123' (comma-separated list of integers)."
    }
    $ProcessIdList = "$Ids" -split '[,\s]+' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ }
}

$IgnoreCaseBool = $IgnoreCase -imatch "1|true|yes|on"
$ShowDescendantsBool = $ShowDescendants -imatch "1|true|yes|on"
$NoHeaderBool = $NoHeader -imatch "1|true|yes|on"
$NoSummaryBool = $NoSummary -imatch "1|true|yes|on"
$OutToStderrForHeaderSummaryBool = $OutToStderrForHeaderSummary -imatch "1|true|yes|on"

$script:MatchedProcessCount = 0

# Define global string comparison type based on IgnoreCase setting
$ComparisonType = if ($IgnoreCaseBool) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }

function New-RegexObject {
    param (
        [string]$Pattern,
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

$ProcessNameRegex = New-RegexObject -Pattern $ProcessNamePattern -IgnoreCase $IgnoreCaseBool
$CommandLineRegex = New-RegexObject -Pattern $CommandLinePattern -IgnoreCase $IgnoreCaseBool
$ExcludeProcessNameRegex = New-RegexObject -Pattern $ExcludeProcessNamePattern -IgnoreCase $IgnoreCaseBool
$ExcludeCommandLineRegex = New-RegexObject -Pattern $ExcludeCommandLinePattern -IgnoreCase $IgnoreCaseBool
$MatchAllRegex = New-RegexObject -Pattern $MatchAllPattern -IgnoreCase $IgnoreCaseBool
$ExcludeAllRegex = New-RegexObject -Pattern $ExcludeAllPattern -IgnoreCase $IgnoreCaseBool

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

# Function to get parent/self processes that should be excluded from results.
# Walks up the ancestor chain from CurrentPid:
#   - Unconditionally excludes the immediate parent (level 0, e.g. cmd.exe running "call pwsh PsTool.ps1")
#   - For higher ancestors, excludes only if Test-ShouldExcludeSelfProcess returns true
#     (e.g. cmd.exe /c "psall.bat ...", msr.exe, PowerShell running PsTool.ps1)
#   - At each excluded ancestor, also excludes its other tool-process children (siblings)
#   - Stops when a non-tool ancestor is found (the user's terminal)
function Get-ExcludedSelfProcessIds {
    param(
        [array]$AllProcesses,
        [int]$CurrentPid
    )

    $excludePIDs = [System.Collections.Generic.HashSet[int]]::new()
    [void]$excludePIDs.Add($CurrentPid)

    $currentId = $CurrentPid
    $isFirstLevel = $true
    $maxLevels = 6  # Safety limit to prevent infinite loops

    for ($level = 0; $level -lt $maxLevels; $level++) {
        $proc = $AllProcesses | Where-Object { $_.ProcessId -eq $currentId } | Select-Object -First 1
        if (-not $proc -or $proc.ParentProcessId -le 0) { break }

        $parentId = $proc.ParentProcessId
        $parentProc = $AllProcesses | Where-Object { $_.ProcessId -eq $parentId } | Select-Object -First 1
        if (-not $parentProc) { break }

        # Immediate parent is always excluded; higher ancestors only if they are tool processes
        $shouldExcludeParent = $isFirstLevel -or (Test-ShouldExcludeSelfProcess -Process $parentProc)

        if ($shouldExcludeParent) {
            [void]$excludePIDs.Add($parentId)

            # Exclude siblings (other children of parent) that are tool processes
            $AllProcesses | Where-Object { $_.ParentProcessId -eq $parentId -and $_.ProcessId -ne $currentId } | ForEach-Object {
                if (Test-ShouldExcludeSelfProcess -Process $_) {
                    [void]$excludePIDs.Add($_.ProcessId)
                }
            }

            $currentId = $parentId
            $isFirstLevel = $false
        }
        else {
            # Non-tool ancestor found: exclude its tool-process children (e.g. cmd.exe /c "psall.bat"), then stop
            $AllProcesses | Where-Object { $_.ParentProcessId -eq $parentId } | ForEach-Object {
                if (Test-ShouldExcludeSelfProcess -Process $_) {
                    [void]$excludePIDs.Add($_.ProcessId)
                }
            }
            break
        }
    }

    return @($excludePIDs | Sort-Object -Unique)
}

# Function to get all processes with normalized structure
function Get-AllProcesses {
    try {
        # Try CIM first (newer), fallback to Get-Process
        $processes = $null

        if ($IsWindows) {
            try {
                $processes = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue
            }
            catch {
                Write-Debug "CIM query failed, falling back to Get-Process"
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

# Function to get descendant processes in BFS level order (parent -> child -> grandchild).
# Returns an ordered array of process objects for display purposes.
function Get-DescendantProcessesOrdered {
    param(
        [array]$AllProcesses,
        [int[]]$RootIds
    )
    $visited = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($id in $RootIds) { [void]$visited.Add($id) }

    $ordered = [System.Collections.Generic.List[object]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new()
    foreach ($id in $RootIds) { $queue.Enqueue($id) }

    while ($queue.Count -gt 0) {
        $currentId = $queue.Dequeue()
        $children = $AllProcesses | Where-Object {
            $_.ParentProcessId -eq $currentId -and (-not $visited.Contains($_.ProcessId))
        } | Sort-Object ProcessId
        foreach ($child in $children) {
            [void]$visited.Add($child.ProcessId)
            $ordered.Add($child)
            $queue.Enqueue($child.ProcessId)
        }
    }
    return $ordered
}

# Output descendant processes in DarkGray if ShowDescendants is enabled.
# Returns the list of descendant process objects (empty array if disabled).
# Accepts either pre-computed descendants or AllProcesses+RootIds to compute them.
function Out-DescendantProcesses {
    param(
        [array]$AllProcesses = @(),
        [int[]]$RootIds = @(),
        [array]$Descendants = $null
    )
    if (-not $ShowDescendantsBool) { return @() }
    $descendantProcs = if ($null -ne $Descendants) { $Descendants } else { Get-DescendantProcessesOrdered -AllProcesses $AllProcesses -RootIds $RootIds }
    foreach ($proc in $descendantProcs) {
        Out-StderrMessage -Message (Format-ProcessOutput -Process $proc) -Color "DarkGray"
    }
    return $descendantProcs
}

# Output summary message with optional descendant count info.
function Out-ProcessSummary {
    param(
        [string]$Verb,           # e.g. "Found" or "Successfully terminated"
        [int]$MatchedCount,
        [int]$DescendantCount = 0
    )
    $matchedWord = if ($MatchedCount -eq 1) { "process" } else { "processes" }
    if ($DescendantCount -gt 0) {
        $descendantWord = if ($DescendantCount -eq 1) { "descendant" } else { "descendants" }
        $hint = if (-not $ShowDescendantsBool) { " (Use -SD to show all)" } else { "" }
        Out-KeyMessage -Message "$Verb $MatchedCount matched $matchedWord with $DescendantCount $descendantWord.$hint" -Type "success"
    }
    else {
        Out-KeyMessage -Message "$Verb $MatchedCount matched $matchedWord." -Type "success"
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
        $hasMatch = ($processIdStr.IndexOf($Text, $ComparisonType) -ge 0) -or
        ($parentProcessIdStr.IndexOf($Text, $ComparisonType) -ge 0) -or
        (-not [string]::IsNullOrEmpty($Process.Name) -and $Process.Name.IndexOf($Text, $ComparisonType) -ge 0) -or
        (-not [string]::IsNullOrEmpty($Process.CommandLine) -and $Process.CommandLine.IndexOf($Text, $ComparisonType) -ge 0)
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
    param(
        $AllProcessesRef = $null
    )
    try {
        # Get all processes with normalized structure (single snapshot for entire operation)
        $allProcesses = Get-AllProcesses
        if ($null -ne $AllProcessesRef -and $AllProcessesRef -is [ref]) {
            $AllProcessesRef.Value = $allProcesses
        }
        $processes = $allProcesses

        if ($ProcessIdList.Count -gt 0) {
            $processes = $processes | Where-Object { $_.ProcessId -in $ProcessIdList }
        }

        # Filter by plain process name (case-sensitive or case-insensitive based on IgnoreCaseBool parameter)
        if (-not [string]::IsNullOrEmpty($ProcessName)) {
            $processes = $processes | Where-Object {
                -not [string]::IsNullOrEmpty($_.Name) -and (
                    $_.Name.IndexOf($ProcessName, $ComparisonType) -ge 0
                )
            }
        }

        # Filter by plain command line text (case-sensitive or case-insensitive based on IgnoreCaseBool parameter)
        if (-not [string]::IsNullOrEmpty($CommandLine)) {
            $processes = $processes | Where-Object {
                -not [string]::IsNullOrEmpty($_.CommandLine) -and (
                    $_.CommandLine.IndexOf($CommandLine, $ComparisonType) -ge 0
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
        $excludePIDs = Get-ExcludedSelfProcessIds -AllProcesses $allProcesses -CurrentPid $PID

        # Filter out excluded processes
        $processes = $processes | Where-Object {
            $_.ProcessId -notin $excludePIDs
        }

        # Exclude by plain process name (case-sensitive or case-insensitive based on IgnoreCaseBool parameter)
        if (-not [string]::IsNullOrEmpty($ExcludeProcessName)) {
            $processes = $processes | Where-Object {
                [string]::IsNullOrEmpty($_.Name) -or -not ($_.Name.IndexOf($ExcludeProcessName, $ComparisonType) -ge 0)
            }
        }

        # Exclude by plain command line text (case-sensitive or case-insensitive based on IgnoreCaseBool parameter)
        if (-not [string]::IsNullOrEmpty($ExcludeCommandLine)) {
            $processes = $processes | Where-Object {
                [string]::IsNullOrEmpty($_.CommandLine) -or -not ($_.CommandLine.IndexOf($ExcludeCommandLine, $ComparisonType) -ge 0)
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
    $allProcessesSnapshot = $null
    $processes = Get-MatchedProcesses -AllProcessesRef ([ref]$allProcessesSnapshot)
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

    # Show descendant processes in BFS order (parent -> child -> grandchild, DarkGray)
    # so users can trace the process tree and preview the full kill impact.
    $processIds = @($outputProcesses.ProcessId)
    $descendantProcs = Get-DescendantProcessesOrdered -AllProcesses $allProcessesSnapshot -RootIds $processIds
    Out-DescendantProcesses -Descendants $descendantProcs | Out-Null
    Out-ProcessSummary -Verb "Found" -MatchedCount $processes.Count -DescendantCount $descendantProcs.Count
}

function Stop-Processes {
    # Use [ref] to get the same allProcesses snapshot used for matching,
    # avoiding a second Get-AllProcesses call that could produce an inconsistent snapshot.
    $allProcessesSnapshot = $null
    $processes = Get-MatchedProcesses -AllProcessesRef ([ref]$allProcessesSnapshot)
    $script:MatchedProcessCount = $processes.Count

    if ($processes.Count -eq 0) {
        Out-KeyMessage -Message "No matching processes found to terminate." -Type "warning"
        return
    }

    # Sort processes by ProcessId for consistent output
    $processes = $processes | Sort-Object ProcessId | Where-Object { $_.ProcessId -gt 0 }

    # Extract process IDs for batch killing
    $processIds = @($processes.ProcessId)
    if ($processIds.Count -eq 0) {
        Out-KeyMessage -Message "No matching process to terminate." -Type "warning"
        return
    }

    # Find all descendant processes using the SAME snapshot (prevents orphans).
    # Reusing $allProcessesSnapshot avoids a second Get-AllProcesses call whose results could
    # differ from the first (race condition: new child processes spawned between two calls would
    # be missed, becoming orphans after the parent is killed).
    # NOTE: display is deferred — we show descendants after the alive-check below,
    # but we need $descendantIds now to build $allIdsToKill for the alive-check itself.
    $descendantProcs = Get-DescendantProcessesOrdered -AllProcesses $allProcessesSnapshot -RootIds $processIds
    $descendantIds = @($descendantProcs.ProcessId)
    $childCount = $descendantIds.Count

    # Always kill descendants together with matched roots on Windows.
    # On Windows, killing a parent does NOT auto-terminate children — they become orphan processes
    # that continue consuming resources with no parent to manage them.
    # Unlike Linux (where init adopts orphans), Windows has no automatic orphan cleanup.
    # If the user wants to kill only specific PIDs, they should use -Ids to target them directly.
    $allIdsToKill = (@($processIds) + @($descendantIds)) | Sort-Object -Unique
    # Kill order: reverse-BFS (deepest descendants first), then matched roots last.
    # PID value does NOT reflect tree depth — a parent may have a larger PID than its child.
    # Using reverse-BFS guarantees children are always terminated before their parents,
    # preventing orphan processes during the brief window between individual kills.
    [array]$reversedDescendantIds = @($descendantIds)
    [array]::Reverse($reversedDescendantIds)
    $killOrderIds = $reversedDescendantIds + @($processIds | Sort-Object -Descending)

    # Use batch termination with Stop-Process
    Write-Debug "Attempting to terminate $($allIdsToKill.Count) processes ($($processIds.Count) matched + $childCount descendants)..."

    try {
        # Filter out PIDs that no longer exist (child processes may have already exited)
        $aliveIds = @($allIdsToKill | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($aliveIds.Count -eq 0) {
            Out-KeyMessage -Message "All $($allIdsToKill.Count) target processes already exited before termination." -Type "info"
            return
        }

        # Output header and matched process list AFTER confirming processes are still alive,
        # to avoid showing a process list followed by "already exited" (contradictory output).
        Out-ResultHeader
        foreach ($proc in $processes) {
            Write-Output (Format-ProcessOutput -Process $proc)
        }

        # Show descendant processes in BFS order (parent -> child -> grandchild, DarkGray)
        # consistent with Find mode, so users can trace the process tree top-down.
        Out-DescendantProcesses -Descendants $descendantProcs | Out-Null

        # Kill in reverse-BFS order: deepest descendants first, then matched roots last.
        # PID value does NOT reflect tree depth — a parent may have a larger PID than its child.
        # Using reverse-BFS guarantees children are always terminated before their parents.
        $aliveIdsSet = [System.Collections.Generic.HashSet[int]]::new([int[]]$aliveIds)
        $aliveIds = @($killOrderIds | Where-Object { $aliveIdsSet.Contains($_) })

        # Use Stop-Process for batch termination.
        # Use SilentlyContinue (not Stop) so that a process that exits between the alive-check
        # and Stop-Process call does not abort the entire batch and leave other processes alive.
        Stop-Process -Id $aliveIds -Force -ErrorAction SilentlyContinue

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
            Out-ProcessSummary -Verb "Successfully terminated" -MatchedCount $processIds.Count -DescendantCount $childCount
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
