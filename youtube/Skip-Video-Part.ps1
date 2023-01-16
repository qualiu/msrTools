<#
.SYNOPSIS
    Remove a slice in a video file.

.DESCRIPTION

.PARAMETER InputFile
    Source video file.

.PARAMETER BeginTime
    Begin time format like '00:00:00'.

.PARAMETER EndTime
    End time format like '00:10:00'.

.PARAMETER SavePath
    Save path of result audio file.

.PARAMETER OutType
    Output type/format like 'mp4'.

.EXAMPLE
    ./Skip-Video-Part.ps1 sutra.mp4 00:15 00:18
    ./Skip-Video-Part.ps1 sutra.mp4 00:15 00:18 sutra-2.mp4
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $InputFile,
    [string] $BeginTime = '',
    [Parameter(Mandatory = $true)] [string] $EndTime,
    [string] $SavePath = '',
    [string] $OutType = ''
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

if ($BeginTime -match '^[0\.:]*$') {
    $command = "$PSScriptRoot/Get-Video-Part.ps1 "
    $command += Get-QuotedArg $InputFile
    $command += " -BeginTime $EndTime"
    if (-not [string]::IsNullOrWhiteSpace($SavePath)) {
        $command += ' -SavePath ' + $SavePath
    }

    if (-not [string]::IsNullOrWhiteSpace($OutType)) {
        $command += ' -OutType ' + $OutType
    }

    Invoke-CommandLineDirectly $command
    return
}

if ([string]::IsNullOrWhiteSpace($OutType)) {
    $OutType = [IO.Path]::GetExtension($InputFile).TrimStart('.')
    if ([string]::IsNullOrEmpty($OutType)) {
        $OutType = 'mp4'
    }
}

$timeMark = '--skip-' + $($BeginTime + '-to-' + $EndTime).Replace(':', '_')
$outFile1 = "part1.$OutType"
$outFile2 = "part2.$OutType"
$InputFileName = [IO.Path]::GetFileNameWithoutExtension($InputFile)
$OutVideoFile = Get-OutputFilePath $InputFile $SavePath $timeMark $OutType

$SaveFolder = [IO.Path]::GetDirectoryName($OutVideoFile)
Push-Location $SaveFolder
$mergeInputFile = $($InputFileName -replace '\.\w+', '') + ".merge.txt"
$mergeInputFullPath = Join-Path $SaveFolder $mergeInputFile
Save-TextToFileUtf8NoBOM $mergeInputFullPath $("file $outFile1" + [System.Environment]::NewLine + "file $outFile2")
Test-DeleteFiles @($outFile1, $outFile2, $OutVideoFile)

# -vcodec copy -acodec copy
Invoke-CommandLineDirectly "ffmpeg -y -t $BeginTime -accurate_seek -i ""$InputFile"" -codec copy ""$outFile1"""
Invoke-CommandLineDirectly "ffmpeg -y -ss $EndTime -accurate_seek -i ""$InputFile"" -codec copy ""$outFile2"""

#ffmpeg -i "concat:%outFile1%|%outFile2%" %OutVideoFile% -c copy %CopyOption% -y && del %outFile1% %outFile2%
$OutVideoFileName = [IO.Path]::GetFileName($OutVideoFile)
Invoke-CommandLineDirectly "ffmpeg -f concat -i ""$mergeInputFile"" -codec copy -avoid_negative_ts 1 ""$OutVideoFileName""" -NoThrow
$isSucceeded = $? -and $LASTEXITCODE -eq 0
Pop-Location

Test-DeleteFiles @(
    Join-Path $SaveFolder $outFile1
    Join-Path $SaveFolder $outFile2
    Join-Path $SaveFolder $mergeInputFile
)

if ($isSucceeded) {
    Show-InputOutputFileInfo $InputFile $OutVideoFile
}
