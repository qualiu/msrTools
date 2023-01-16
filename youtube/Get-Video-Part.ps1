<#
.SYNOPSIS
    Extract parital video.

.DESCRIPTION

.PARAMETER InputFile
    Source video file.

.PARAMETER BeginTime
    Begin time format like '00:00:00'.

.PARAMETER Duration
    Duration format like '00:10:00'.

.PARAMETER SavePath
    Save path of result audio file.

.PARAMETER OutType
    Output type/format like 'mp4'.

.PARAMETER OtherArgs
    Other args for ffmpeg.

.EXAMPLE
    ./Get-Video-Parts.ps1  sutra.mp4  -ss 00:03:05
    ./Get-Video-Parts.ps1  sutra.mp4  -t 00:00:45.0
    ./Get-Video-Parts.ps1  sutra.mp4  -ss 00:03:05 -t 00:00:45.0
    ./Get-Video-Parts.ps1  sutra.mp4  -ss 00:03:05 -t 00:00:45.0  sutra-part.mp4
    ./Get-Video-Parts.ps1  sutra.mp4  -force_key_frames 00:03:05,00:00:45
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $InputFile,
    [string] $BeginTime = '00:00:00',
    [string] $EndTime = '',
    [string] $SavePath = '',
    [string] $OutType = 'mp4',
    [Parameter(ValueFromRemainingArguments)] [string[]] $OtherArgs = @('-codec', 'copy', '-avoid_negative_ts', '1')
)

Import-Module "$PSScriptRoot/../common/BasicOsUtils.psm1"
Import-Module "$PSScriptRoot/../common/CommonUtils.psm1"
Import-Module "$PSScriptRoot/MediaUtils.psm1"

if ($MyInvocation.Line -imatch '\s+-+help') {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    return
}

if (-not [IO.File]::Exists($InputFile)) {
    throw "Not exist input file: $InputFile"
}

$fmArgs = Get-BeginEndTimeInfoForFFMPEG $MyInvocation.Line $BeginTime $EndTime
$OutVideoFile = Get-OutputFilePath $InputFile $SavePath $fmArgs.TimeMark $OutType

$commandArgs = $fmArgs.Args + $OtherArgs
if (-not $OtherArgs.Contains('-codec')) {
    $commandArgs += @('-codec', 'copy')
}

if (-not $OtherArgs.Contains('-avoid_negative_ts')) {
    $commandArgs += @('-avoid_negative_ts', '1')
}

$commandArgs += $OutVideoFile
$commandArgs += @('-accurate_seek', '-i', $InputFile)
$command = Join-CommandArgs $commandArgs

Invoke-CommandLineDirectly $command.Trim() -ErrorActionCommand "$DeleteFileCmd ""$OutVideoFile"""
if ($? -and $LASTEXITCODE -eq 0) {
    Show-InputOutputFileInfo $InputFile $OutVideoFile
}
