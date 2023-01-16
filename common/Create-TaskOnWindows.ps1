
<#
.DESCRIPTION
    Create a task scheduler on Windows, or update a task if exists with same task path + name (Safe to re-run, overwrite existing task).

.Parameter ExeOrScript
    EXE(cmd/powershell) of script file path. If it's an built-in tool like cmd.exe, can use 'cmd'.

.Parameter Argument
    Argument for the EXE/script. Enter powershell environment and use double/single quotes for complicate arguments.

.Parameter RepeatInterval
    Must be a parsable duration by [TimeSpan]::Parse() like '00:10:00' (10 minutes).

.Parameter StartAtTime
    Must be a parsable date time by [DateTime]::Parse().

.Parameter UseSystemAccount
    This is good if need admin role and don't require user related(like environment variables) config/value/permission.

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
    [switch] $UseSystemAccount,
    [switch] $RunNow
)

Import-Module "$PSScriptRoot/CommonUtils.psm1"

if ([string]::IsNullOrWhiteSpace($Description)) {
    $Description = "$($ExeOrScript) $($Argument)"
}

if ([string]::IsNullOrWhiteSpace($TaskName)) {
    $TaskName = if ($ExeOrScript -imatch 'PowerShell') {
        $Argument -replace '^.*?[/\\]([^/\\]+?).ps1\s+.*', '$1'
    }
    else {
        Get-ValidFileName $([IO.Path]::GetFileNameWithoutExtension($ExeOrScript))
    }
}

Show-Message "Will check existing task $($TaskName) in $($TaskPath)"
Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName 2>$null

$taskSettings = New-ScheduledTaskSettingsSet -Hidden -ExecutionTimeLimit $([TimeSpan]::MaxValue) -AllowStartIfOnBatteries -DisallowHardTerminate -StartWhenAvailable
$taskSettings.CimInstanceProperties['ExecutionTimeLimit'].Value = 'PT0S'
$taskSettings.CimInstanceProperties['StopIfGoingOnBatteries'].Value = $false
$taskSettings.ExecutionTimeLimit = 'PT0S'
$taskSettings.StopIfGoingOnBatteries = $false
$taskSettings.Hidden = $HideWindow

$principal = if ($UseSystemAccount) {
    New-ScheduledTaskPrincipal -RunLevel Highest -LogonType ServiceAccount -UserId 'NT AUTHORITY\SYSTEM'
}
else {
    New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U
}

$interval = [TimeSpan]::Parse($RepeatInterval)
$startTime = [DateTime]::Parse($StartAtTime)
$trigger = New-ScheduledTaskTrigger -Once -At $startTime -RepetitionInterval $interval
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
