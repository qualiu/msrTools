Import-Module "$PSScriptRoot/../common/Check-Tools.psm1"
Import-Module "$PSScriptRoot/../common/CommonUtils.psm1"

function Show-AudioTips {
    $tips = @(
        "Compress-Ratio-at-Same-Quality: aac > ogg > mp3/wma > ape > flac > wav",
        "Highest Quality: wav=flac=ape > aac > ogg > mp3 > wma",
        "MP3 Player Support: mp3 > wma > wav > flac > ape aac ogg",
        "Mobile Phone: mp3 > wma > aac wav > flac ogg > ape",
        "Overall Quality + Size: aac > ogg > flac ape > mp3 > wav wma"
    )

    foreach ($tip in $tips) {
        msr -x ">" -ie "flac|ape|wav|mp3|aac|ogg|wma" -t "^.+?:" -aPA -z $tip
    }
}

class FFMPEG_Args {
    [string[]] $Args = @('ffmpeg')
    [string] $BeginTime = ''
    [string] $EndTime = ''
    [string] $TimeMark = ''

    FFMPEG_Args([string[]] $cmdArgs, [string] $TimeMark, [string] $BeginTime = '', [string] $EndTime = '') {
      $this.Args = $cmdArgs
      $this.TimeMark = $TimeMark
      $this.BeginTime = $BeginTime
      $this.EndTime = $EndTime
    }
  }

function Get-BeginEndTimeInfoForFFMPEG {
    param (
        [Parameter(Mandatory=$true)] [string] $ScriptCommandLine,
        [string] $BeginTime = '',
        [string] $EndTime = ''
    )

    $BeginTime = $BeginTime.Trim('"', "'")
    $EndTime = $EndTime.Trim('"', "'")

    $commandArgs = @('ffmpeg')
    $beginTimeMark = ''
    if (-not [string]::IsNullOrWhiteSpace($BeginTime)) {
        if ($BeginTime -notmatch '^00:00:00\.?0*$') {
            if ($BeginTime -notmatch '\d+:\d+:\d+') {
                $BeginTime = '00:' + $BeginTime
            }
            $commandArgs += @('-ss', $BeginTime)
        }
    } else {
        $BeginTime = '00:00:00'
        $matchBegin = [regex]::Match($ScriptCommandLine, '\s+-ss\s+(\S+)')
        if ($matchBegin.Success) {
            $BeginTime = $matchBegin.Groups[1].Value -ireplace "[""']", ""
            if ($BeginTime -notmatch '\d+:\d+:\d+') {
                $BeginTime = '00:' + $BeginTime
            }
        }
    }

    if ($BeginTime -notmatch '^00:00:00\.?0*$') {
        $beginTimeMark = '--from-' + $BeginTime
    }

    $endTimeMark = ''
    if (-not [string]::IsNullOrWhiteSpace($EndTime)) {
        $duration = [TimeSpan]::Parse($EndTime) - [TimeSpan]::Parse($BeginTime)
        $commandArgs += @('-t', $duration.ToString())
        $endTimeMark = '-to-' + $EndTime
    } else {
        $matchDuration = [regex]::Match($ScriptCommandLine, '\s+-t\s+(\S+)')
        if ($matchDuration.Success) {
            $durationValue = $matchDuration.Groups[1].Value -ireplace "[""']", ""
            if ($durationValue -match '^\d+(\.\d+)?$') {
                $durationValue = [TimeSpan]::FromSeconds($durationValue)
            } else {
                if ($durationValue -notmatch '\d+:\d+:\d+') {
                    $durationValue = '00:' + $durationValue
                }
            }
            $EndTime = [TimeSpan]::Parse($BeginTime) + [TimeSpan]::Parse($durationValue)
            $endTimeMark = '-to-' + $EndTime
        } else {
            $matchStopTime = [regex]::Match($ScriptCommandLine, '\s+-to\s+(\S+)')
            if ($matchStopTime.Success) {
                $EndTime = $matchStopTime.Groups[1].Value -ireplace "[""']", ""
                if ($EndTime -notmatch '\d+:\d+:\d+') {
                    $EndTime = '00:' + $durationValue
                }
                $endTimeMark = '-to-' + $EndTime
            }
        }
    }

    $timeMark = $($beginTimeMark + $endTimeMark) -replace ':', '_'
    $result = [FFMPEG_Args]::new($commandArgs, $timeMark, $BeginTime, $EndTime)
    return $result
}

function Show-InputOutputFileInfo {
    param (
        [string] $InputFile,
        [string] $OutputFile
    )

    $inputSizeUnit = Get-SizeAndUnit $(Get-Item $InputFile).Length
    $outFileSizeUnit = Get-SizeAndUnit $(Get-Item $OutputFile).Length
    Show-Info "SourceFileSize = $inputSizeUnit , SourceFile = $InputFile"
    Show-Info "OutputFileSize = $outFileSizeUnit , OutputFile = $OutputFile"
}

# Auto generated exports by Update-PowerShell-Module-Exports.ps1
Export-ModuleMember -Function Show-AudioTips
Export-ModuleMember -Function Get-BeginEndTimeInfoForFFMPEG
Export-ModuleMember -Function Show-InputOutputFileInfo
