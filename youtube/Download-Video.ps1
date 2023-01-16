<#
.SYNOPSIS
    Download a youtube video.

.DESCRIPTION

.PARAMETER Url
    Source URL or a youtube video to download.

.PARAMETER SaveFolder
    Save folder for the video. Auto create if not exists.

.PARAMETER ExtractAudio
    Extract audio after downloaded the video.

.PARAMETER VideoFormat
    Video format to save (like mp4).

.PARAMETER AudioFormat
    Audio format like aac/mp3.

.PARAMETER DeleteVideo
    Delete video after extracted audio.

.PARAMETER OtherArgs
    Other arguments for downloading tool.

.EXAMPLE
    ./Download-Video.ps1 'https://www.youtube.com/watch?v=qlqhYVd37jk'
    ./Download-Video.ps1 'https://www.youtube.com/watch?v=qlqhYVd37jk' -BeginTime 00:00:00 -EndTime 00:00:32
    ./Download-Video.ps1 'https://www.youtube.com/watch?v=qlqhYVd37jk' -OtherArgs --embed-thumbnail --ignore-errors
    ./Download-Video.ps1 'https://www.youtube.com/watch?v=qlqhYVd37jk' -ExtractAudio $true
    ./Download-Video.ps1 'https://www.youtube.com/watch?v=qlqhYVd37jk' -ExtractAudio 1 -AudioFormat aac -DeleteVideo 1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Url,
    [string] $SaveFolder = '.',
    [bool] $ExtractAudio = $false,
    [string] $VideoFormat = 'mp4',
    [string] $AudioFormat = 'aac',
    [bool] $DeleteVideo = $false,
    [string] $BeginTime = "",
    [string] $EndTime = "",
    [bool] $AddTimeRangeToName = $true,
    [Parameter(ValueFromRemainingArguments)] [string[]] $OtherArgs = @('-o', '"%(title)s.%(ext)s"') # --embed-thumbnail --ignore-errors
)

Import-Module "$PSScriptRoot/../common/BasicOsUtils.psm1"
Import-Module "$PSScriptRoot/../common/CommonUtils.psm1"
Import-Module "$PSScriptRoot/MediaUtils.psm1"

if ($MyInvocation.Line -imatch '\s+-+help') {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    Show-AudioTips
    return
}

$ToolArgs = @('--format', $VideoFormat)
if ($ExtractAudio) {
    $ToolArgs += @('--extract-audio', '--audio-format', $AudioFormat)
    if (-not $DeleteVideo) {
        $ToolArgs += '--keep-video'
    }
}

$PostTimeArgs = ""
$VideoTimeRangeArgs = ""
if (-not [string]::IsNullOrWhiteSpace($BeginTime + $EndTime)) {
    if (-not [string]::IsNullOrWhiteSpace($BeginTime)) {
        $VideoTimeRangeArgs += "-ss $($BeginTime)"
    }

    if (-not [string]::IsNullOrWhiteSpace($EndTime)) {
        $VideoTimeRangeArgs += " -to $($EndTime)"
    }

    # $PostTimeArgs = '--postprocessor-args "' + $VideoTimeRangeArgs.Trim() + '"'
    $PostTimeArgs = '--external-downloader ffmpeg --external-downloader-args "' + $VideoTimeRangeArgs.Trim() + '"'
}

if (-not [string]::IsNullOrWhiteSpace($OtherArgs)) {
    $ToolArgs += $OtherArgs
}

if (-not $ToolArgs.Contains('-o')) {
    $ToolArgs += @('-o', '"%(title)s.%(ext)s"')
}

$timeRangeForName = $VideoTimeRangeArgs.Trim().Replace('-ss', '-from').Replace(' -to ', '-to-') -replace '[^\w\.-]', '_'
$outputName = '%(title)s' + $timeRangeForName
if ($AddTimeRangeToName) {
    $ToolArgs = "$($ToolArgs)".Replace('%(title)s', $outputName)
}

$LogFile = Join-Path $SysTmpFolder 'download-url.log'
[IO.File]::AppendAllText($LogFile, $MyInvocation.Line, $Utf8NoBomEncoding)

Test-CreateDirectory $SaveFolder
$cmdHead = "youtube-dl $($PostTimeArgs)".Trim()
Push-Location $SaveFolder
$commandLine = "$($cmdHead) ""$($Url)"" $($ToolArgs)".Trim()
Invoke-CommandLineDirectly $commandLine # -ErrorActionCommand 'Pop-Location'
Pop-Location
Test-CreateDirectory $SysTmpFolder
$logFile = Join-Path $SysTmpFolder 'download-video-command.log'
[IO.File]::AppendAllText($logFile, "$(Get-NowText)`n$($commandLine)", $Utf8NoBomEncoding)
$OutputFileInfo = Get-ChildItem -File $SaveFolder | Where-Object { $_.Name -inotmatch '\.(part|log|txt|py|html|bat|zip|psm?1)' } | Sort-Object LastWriteTime | Select-Object -Last 1
$outFileSizeUnit = Get-SizeAndUnit $OutputFileInfo.Length
Show-Info "OutputFileSize = $($outFileSizeUnit) , OutputFile = $($OutputFileInfo.FullName)"
