
<#
.DESCRIPTION
    Create a task scheduler on Windows, or update a task if exists with same task path + name (Safe to re-run, overwrite existing task).

.Parameter ExeOrScript
    EXE(cmd/powershell) of script file path. If it's an built-in tool like cmd.exe, can use 'cmd'.

.Parameter Argument
    Argument for the EXE/script. Enter powershell environment and use double/single quotes for complicate arguments.

.Parameter RepeatInterval
    Must be a parsable duration by [TimeSpan]::Parse() like '00:10:00' (10 minutes).
    Ignored when -TriggerType is 'AtStartup' or 'AtLogOn'.

.Parameter StartAtTime
    Must be a parsable date time by [DateTime]::Parse().
    Ignored when -TriggerType is 'AtStartup' or 'AtLogOn'.

.Parameter TriggerType
    'Once' (default): repeats every -RepeatInterval starting at -StartAtTime.
    'AtStartup'     : fires once at machine boot. Best for long-running daemons that
                      handle their own scheduling internally -- only one CMD console
                      flash per boot instead of one per interval.
    'AtLogOn'       : fires when the current user signs in.

.Parameter UseSystemAccount
    This is good if need admin role and don't require user related(like environment variables) config/value/permission.

.Parameter LogonType
    Task Scheduler logon type. When empty (default) the script auto-detects via dsregcmd:
    - S4U (Service for User) is recommended and used by default if supported - it allows the task to run whether the user is signed in or not.
    - Interactive is used as a fallback if the OS doesn't support S4U.
    Pass an explicit value ('S4U', 'Interactive', 'Password', 'ServiceAccount', ...) to override.

.Parameter TaskName
    Will use EXE/script name (except powershell) if empty.

.Parameter Description
    Will use the full command line if empty.

.Parameter RunNow
    Start the task after creation immediately (asynchronism).

.EXAMPLE
    ./Create-TaskOnWindows.ps1 EXE-or-Bat-Cmd 'arg1 arg2 arg3'
    ./Create-TaskOnWindows.ps1 powershell 'c:/my-script.ps1 arg1 arg2 arg3'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ExeOrScript,
    [string] $Argument,
    [string] $RepeatInterval = "00:05:00",
    [string] $StartAtTime = [DateTime]::Now.ToString(),
    [string] $TaskPath = '\My-Tasks\',
    [string] $TaskName = '',
    [string] $Description = '',
    [bool] $HideWindow = $true,
    [string] $LogonType,
    [string] $TriggerType = 'Once',
    [string] $RestartOnFailureInterval = '00:05:00',
    [int] $RestartOnFailureCount = 999,
    [switch] $UseSystemAccount,
    [switch] $RunNow
)

Import-Module "$PSScriptRoot/CommonUtils.psm1"

if ([string]::IsNullOrWhiteSpace($Description)) {
    $Description = "$($ExeOrScript) $($Argument)"
}

if ([string]::IsNullOrWhiteSpace($TaskName)) {
    $TaskName = if ($ExeOrScript -imatch '(^|[/\\])(powershell|pwsh|cmd)(\.exe)?$' -and $Argument -imatch '\.ps1\b') {
        $Argument -replace '^.*?[/\\]([^/\\]+?)\.ps1\b.*', '$1'
    }
    else {
        Get-ValidFileName $([IO.Path]::GetFileNameWithoutExtension($ExeOrScript))
    }
}

Show-Message "Will check existing task $($TaskName) in $($TaskPath)"
Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName 2>$null

$restartInterval = [TimeSpan]::Parse($RestartOnFailureInterval)
$taskSettings = New-ScheduledTaskSettingsSet -Hidden -ExecutionTimeLimit $([TimeSpan]::MaxValue) -AllowStartIfOnBatteries -DisallowHardTerminate -StartWhenAvailable -RestartCount $RestartOnFailureCount -RestartInterval $restartInterval
$taskSettings.CimInstanceProperties['ExecutionTimeLimit'].Value = 'PT0S'
$taskSettings.CimInstanceProperties['StopIfGoingOnBatteries'].Value = $false
$taskSettings.ExecutionTimeLimit = 'PT0S'
$taskSettings.StopIfGoingOnBatteries = $false
$taskSettings.Hidden = $HideWindow

function Get-RecommendedLogonType {
    # Default S4U so the task runs whether the user is signed in or not (the usual reason to schedule
    # a background task). Only fall back to Interactive when the OS itself rejects S4U.
    try {
        $status = (dsregcmd /status | Out-String)
        $aadJoined = $status -match '(?im)^\s*AzureAdJoined\s*:\s*YES\s*$'
        $domainJoined = $status -match '(?im)^\s*DomainJoined\s*:\s*YES\s*$'
        if ($aadJoined -and (-not $domainJoined)) { return 'Interactive' }
    }
    catch { }
    return 'S4U'
}

function Resolve-ExePath {
    param([string] $Exe)
    if ([string]::IsNullOrWhiteSpace($Exe)) { return $Exe }
    # Already an absolute / qualified path -- keep as-is.
    if ($Exe -match '[\\/]' -or [System.IO.Path]::IsPathRooted($Exe)) { return $Exe }
    try {
        $cmd = Get-Command $Exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
        if ($cmd -and $cmd.Source) {
            Show-Message "Resolved '$Exe' -> '$($cmd.Source)' (Task Scheduler PATH may differ from interactive shell)"
            return $cmd.Source
        }
    }
    catch { }
    return $Exe
}

$ExeOrScript = Resolve-ExePath $ExeOrScript

$principal = if ($UseSystemAccount) {
    New-ScheduledTaskPrincipal -RunLevel Highest -LogonType ServiceAccount -UserId 'NT AUTHORITY\SYSTEM'
}
else {
    $lt = if ($LogonType) { $LogonType } else { Get-RecommendedLogonType }
    Show-Message "Using LogonType = $($lt) (explicit=$([bool]$LogonType))"
    New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType $lt -RunLevel Highest
}

$interval = [TimeSpan]::Parse($RepeatInterval)
$startTime = [DateTime]::Parse($StartAtTime)
$trigger = switch -Regex ($TriggerType) {
    '^(?i)AtStartup$' { New-ScheduledTaskTrigger -AtStartup }
    '^(?i)AtLogOn$'   { New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME }
    default           { New-ScheduledTaskTrigger -Once -At $startTime -RepetitionInterval $interval }
}
$action = if ([string]::IsNullOrWhiteSpace($Argument)) {
    New-ScheduledTaskAction -Execute $ExeOrScript
}
else {
    New-ScheduledTaskAction -Execute $ExeOrScript -Argument $Argument
}

$task = Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Description $Description -Trigger $trigger -Action $action -Principal $principal -Settings $taskSettings -Force
Show-Info "Created task: $($TaskName) at $($TaskPath), interval = $($interval.ToString()), start at $($startTime.ToString('o'))"
$task
if ($RunNow) {
    Show-Info "Will start task: $($TaskName)"
    Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName
}
