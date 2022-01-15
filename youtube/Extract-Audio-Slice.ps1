<#
.SYNOPSIS
    Extract audio slice from a video or audio file.

.DESCRIPTION

.PARAMETER InputFile
    Source video or audio file.

.PARAMETER BeginTime
    Begin time format like '00:01'.

.PARAMETER Duration
    Duration format like '00:10:00' or '600' (seconds).

.PARAMETER SavePath
    Save path of result audio file.

.PARAMETER OutType
    Output type/format like 'aac' / 'm4a' / 'mp3'.

.PARAMETER OtherArgs
    Other args for ffmpeg.

.EXAMPLE
    ./Extract-Audio-Slice.ps1 sutra.mp4 "00:53"
    ./Extract-Audio-Slice.ps1 sutra.mp4 "00:53" 600
    ./Extract-Audio-Slice.ps1 sutra.aac "00:00:05" "00:10:00.0"
    ./Extract-Audio-Slice.ps1 sutra.mp4 -Duration 00:02:00 -y
    ./Extract-Audio-Slice.ps1 sutra.mp4  -SavePath ./audio.mp3  -y -vn -acodec libmp3lame -q:a 5
    ./Extract-Audio-Slice.ps1 sutra.mp4  -SavePath ./audio.mp3  -vn -c:a aac -ss 00:03:05 -t 00:00:45.0 -accurate_seek -i
    ./Extract-Audio-Slice.ps1 sutra.mp4  -SavePath ./audio.mp3  -vn -c:a aac -ss 0 -t 45
    ./Extract-Audio-Slice.ps1 sutra.aac  -SavePath ./ -vn -c:a aac -ss 0 -t 600
    ./Extract-Audio-Slice.ps1 sutra.aac  -SavePath .  -ss 0 -t 600 -vn -c:a aac
    ./Extract-Audio-Slice.ps1 sutra.mp4  -SavePath ./audio.falc -vn -acodec flac -bits_per_raw_sample 16 -ar 44100
    ./Extract-Audio-Slice.ps1 sutra.mp4  -SavePath ./audio.flac -vn -acodec copy
    ./Extract-Audio-Slice.ps1 sutra.mp4  -SavePath ./audio.flac -c:a flac
    ./Extract-Audio-Slice.ps1 sutra.mp4  -SavePath ./audio.flac -c:a flac -compression_level 12
    ./Extract-Audio-Slice.ps1 sutra.mp4  -SavePath ./audio.mp3  -vn -f mp3 -ab 192000
    ./Extract-Audio-Slice.ps1 sutra.mp4  -SavePath ./audio.mp3  -vn -f mp3 -ab 192K
    ./Extract-Audio-Slice.ps1 sutra.mp4  -SavePath ./audio.mp3  -vn -acodec mp3 -ab 320k -ar 44100 -ac 2
    ./Extract-Audio-Slice.ps1 sutra.mp4  -SavePath ./audio.wav  -vn -acodec pcm_s16le -ar 44100 -ac 2
    ./Extract-Audio-Slice.ps1 sutra.mp4  -SavePath ./audio.aac  -vn -acodec copy
    ./Extract-Audio-Slice.ps1 sutra.mp4  -SavePath ./audio.aac  -vn -c:a copy
    ./Extract-Audio-Slice.ps1 sutra.mp4  -SavePath ./audio.m4a  -vn -c:a copy
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $InputFile,
    [string] $SavePath = '',
    [string] $BeginTime = '00:00:00',
    [string] $EndTime = '',
    [string] $OutType = 'aac',
    [Parameter(ValueFromRemainingArguments)] [string[]] $OtherArgs = @('-accurate_seek') #, '-codec', 'copy', '-avoid_negative_ts', '1')
)

Import-Module "$PSScriptRoot/../common/Check-Tools.psm1"
Import-Module "$PSScriptRoot/../common/CommonUtils.psm1"
Import-Module "$PSScriptRoot/MediaUtils.psm1"

if ($MyInvocation.Line -imatch '\s+-+help') {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    Show-AudioTips
    return
}

if (-not [IO.File]::Exists($InputFile)) {
    throw "Not exist input file: $InputFile"
}

if ([string]::IsNullOrWhiteSpace($OutType)) {
    $OutType = $MyInvocation.Line -ireplace ".*\b(flac|ape|wav|mp3|aac|ogg|wma|m4a)\b.*", '$1'
    if ($OutType -eq $MyInvocation.Line) {
        $OutType = 'aac'
    }
}

$fmArgs = Get-BeginEndTimeInfoForFFMPEG $MyInvocation.Line $BeginTime $EndTime
$OutAudioFile = Get-OutputFilePath $InputFile $SavePath $fmArgs.TimeMark $OutType

$commandArgs = $fmArgs.Args + $OtherArgs
$commandArgs += @('-i', $InputFile, $OutAudioFile)
$command = Join-CommandArgs $commandArgs

Invoke-CommandLineDirectly $command.Trim() -ErrorActionCommand "$DeleteFileCmd ""$OutAudioFile"""
if ($? -and $LASTEXITCODE -eq 0) {
    Show-InputOutputFileInfo $InputFile $OutAudioFile
}
