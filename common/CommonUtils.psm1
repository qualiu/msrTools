Import-Module "$PSScriptRoot/Check-Tools.psm1"

$ShouldQuoteArgRegex = if ($IsWindowsOS) {
    New-Object System.Text.RegularExpressions.Regex('[\s&>\|]')
} else {
    New-Object System.Text.RegularExpressions.Regex('[\s&>\|\\]' + '|' + '\$[\$\?\d\{]')
}

# Solve Azure CLI color bug for all scripts.
# [System.Console]::ResetColor()

function Get-NowText {
    param (
      [string] $Format = "yyyy-MM-dd HH:mm:ss.fff zzz"
    )

    return [DateTime]::Now.ToString($Format)
}

function Get-GitRepoName {
    param (
        [string] $RepoFolder
    )

    Push-Location $RepoFolder
    $repoName = $(git remote -v) -ireplace ".*/([^/]+?)(\.git)?\s+.*", '$1' | Select-Object -First 1
    Pop-Location
    return $repoName
}

function Show-MessageToHost {
    param (
        [string] $Message,
        [System.ConsoleColor] $ForegroundColor = [System.ConsoleColor]::Black,
        [System.ConsoleColor] $BackgroundColor = [System.ConsoleColor]::Black
    )

    $timeMessage = if ([string]::IsNullOrWhiteSpace($Message)) { $Message } else { "$(Get-NowText) $Message" }
    if ($ForegroundColor -ne [System.ConsoleColor]::Black -and $BackgroundColor -ne [System.ConsoleColor]::Black) {
        Write-Host $timeMessage -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
    } elseif ($ForegroundColor -ne [System.ConsoleColor]::Black) {
        Write-Host $timeMessage -ForegroundColor $foreGroundColor
    } elseif ($BackgroundColor -ne [System.ConsoleColor]::Black) {
        Write-Host $timeMessage -BackgroundColor $foreGroundColor
    } else {
        Write-Host $timeMessage
    }
}

function Show-Message {
    param (
        [string] $Message
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        Write-Output $Message
    } else {
        Write-Output "$(Get-NowText) $Message"
    }
}

function Show-Info {
    param (
        [string] $Message,
        [System.ConsoleColor] $ForegroundColor = [System.ConsoleColor]::Green,
        [System.ConsoleColor] $BackgroundColor = [System.ConsoleColor]::Black
    )

    Show-MessageToHost $Message $ForegroundColor $BackgroundColor
}

function Show-Warning {
    param (
        [string] $Message,
        [System.ConsoleColor] $ForegroundColor = [System.ConsoleColor]::Yellow,
        [System.ConsoleColor] $BackgroundColor = [System.ConsoleColor]::Black
    )

    Show-MessageToHost $Message $ForegroundColor $BackgroundColor
}

function Show-Error {
    param (
        [string] $Message,
        [System.ConsoleColor] $ForegroundColor = [System.ConsoleColor]::Red,
        [System.ConsoleColor] $BackgroundColor = [System.ConsoleColor]::Black
    )

    # [console]::Error.WriteLine($Message)
    Show-MessageToHost $Message $ForegroundColor $BackgroundColor
}

function Save-TextToFileUtf8NoBOM {
    param (
      [string] $FilePath,
      [string] $AllText
    )

    [IO.File]::WriteAllText($FilePath, $AllText, $Utf8NoBomEncoding)
  }

function Save-FileToUtf8NoBOM {
    param (
      [string] $FilePath
    )

    $lines = [IO.File]::ReadAllLines($FilePath)
    [IO.File]::WriteAllLines($FilePath, $lines, $Utf8NoBomEncoding)
}

function Save-OutputToFileUtf8NoBOM {
    param (
      [Parameter(Mandatory = $true)] [string] $FilePath,
      [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
      [string] $line
    )

    begin {
      $AllLines = @()
    }

    process {
      $AllLines += $line
    }

    end {
        [IO.File]::WriteAllLines($FilePath, $AllLines, $Utf8NoBomEncoding)
    }
}

function Get-QuotedArg {
    param (
        [string] $Path,
        [string] $Quote = '"'
    )

    # $quote = '"' # if ($IsWindowsOS) { '"' } else { "'" }
    if ($ShouldQuoteArgRegex.IsMatch($Path)) {
        return $Quote + $Path + $Quote
    } else {
        return $Path
    }
}

function Join-CommandArgs {
    param (
        [string[]] $ArgArray
    )

    $cmdArgs = @()
    foreach ($arg in $ArgArray) {
        if (-not [string]::IsNullOrEmpty(($arg))) {
            $cmdArgs += Get-QuotedArg $arg
        }
    }

    return [string]::Join(' ', $cmdArgs)
}

function Test-CreateDirectory {
    param (
        [string] $folder
    )

    if (-not [IO.Directory]::Exists($folder)) {
        [void] [IO.Directory]::CreateDirectory($folder)
    }
}

function Test-DeleteFiles {
    param (
        [string[]] $Files
    )

    foreach ($file in $Files) {
        if ([IO.File]::Exists($file)) {
           [void] [IO.File]::Delete($file)
        }
    }
}

function Show-ExceptionDetail {
    param(
      [Parameter(Mandatory = $true)] [Exception] $ex,
      [int] $level = 1
    )

    # $errorTitle = if (($env:isVsoAgent -eq 'true') -and $showErrorOnPortal) { "##vso[task.logissue type=error]" } else { "" }
    $errorInfo = if ($ex.StatusCode -and ($ex.GetType().ToString() -ne "System.Exception")) { "Exception[$level]: Type = $($ex.GetType()) , StatusCode = $($ex.StatusCode) , Message = $($ex.Message)" } else { $ex.Message }
    Write-Host -ForegroundColor Red $errorInfo $ex.StackTrace
    Write-Host ""
    if ($ex.InnerException) {
      Show-ExceptionDetail $ex.InnerException $($level + 1)
    }
}

function Trace-PathOccupation {
    param(
        [Parameter(Position = 0, Mandatory = $true)] [string] $path
    )

    if (-not $IsWindowsOS) {
        return
    }

    $handlePath = $(Get-Command handle.exe 2>$null).Source
    if ([string]::IsNullOrEmpty($handlePath)) {
        Get-FileFromUrl "https://download.sysinternals.com/files/Handle.zip" "$env:TEMP\Handle.zip"
        Expand-ZipFile "$env:TEMP\Handle.zip" -DestinationPath "$env:TEMP"
        $handlePath = "$env:TEMP\handle.exe"
    }

    $output = & $handlePath $path -NoBanner
    Show-MessageToHost -ForegroundColor Red "File occupation of $path as below:`n$output"
}

function Invoke-CommandLine {
    param(
        [string] $CommandLine,
        [bool] $ExitIfFailed = $true,
        [int] $SuccessReturn = 0,
        [string] $SuccessReturnRegex = "",
        [int] $TryTimes = 1,
        [int] $CurrentTryNumber = 1,
        [int] $SleepSeconds = 5,
        [string] $Tip = "",
        [bool] $HideCommand = $false,
        [bool] $HideReturn = $false,
        [bool] $HideAll = $false,
        [string] $ErrorActionCommand = '',
        [switch] $NoThrow
    )

    $tryInfo = if ($TryTimes -ne 1) { "Try[$CurrentTryNumber]-${TryTimes}: " } else { "" }
    $canThrow = $($CurrentTryNumber -eq $TryTimes) -and $(-not $NoThrow)
    # $beginTime = [DateTime]::Now
    $isRobocopy = $CommandLine -imatch "\bROBOCOPY\s+"
    if ($HideAll) {
        Write-Output $CommandLine | msr -XA
    }
    elseif ($isRobocopy -or $HideReturn) {
        Write-Output $CommandLine | msr -XMI
    }
    elseif ($HideCommand) {
        Write-Output $CommandLine | msr -XP
    }
    else {
        Write-Output $CommandLine | msr -XM
    }

    $returnValue = $LASTEXITCODE
    # $elapse = [DateTime]::Now - $beginTime
    # Write-Host "TimeCost = $($elapse.TotalSeconds.ToString('F3')) s, ReturnValue = $returnValue, CommandLine = $CommandLine"

    $hasMatchedValue = $false
    $reason = ""
    if ([string]::IsNullOrWhiteSpace($SuccessReturnRegex)) {
        $hasMatchedValue = $returnValue -eq $SuccessReturn
        $reason = "Expected return value = $SuccessReturn"
    }
    else {
        $hasMatchedValue = "$returnValue" -match $SuccessReturnRegex
        $reason = "Expected return value should match Regex: $SuccessReturnRegex"
    }

    $isFailed = if ($isRobocopy) { $returnValue -gt 7 }  else { $(-not $hasMatchedValue) }

    # Trace file occupation root cause:
    if ($($returnValue -ne 0) -and $($CommandLine -imatch "\brd(\s+/[qs])+ (.+)")) {
        $deletionPath = $CommandLine -ireplace '.*\brd(\s+/[qs])+ (.+)', '$2'
        if (-not $(Test-Path $deletionPath)) {
            Show-Warning "${TryInfo}Command return = ${returnValue}, but deleted and not found ${deletionPath} : ${CommandLine}"
        }
        else {
            Trace-PathOccupation $deletionPath
        }
    }

    if ($returnValue -lt 0 -or $($isFailed -and $ExitIfFailed)) {
        $errorText = "${TryInfo}Command failed with return value ${returnValue}($reason): ${CommandLine}"
        if (-not [string]::IsNullOrWhiteSpace($Tip)) {
            $errorText += "`n" + $Tip
        }

        if ($canThrow) {
            if (-not [string]::IsNullOrWhiteSpace($ErrorActionCommand)) {
                Invoke-Expression $ErrorActionCommand
            }
            throw $errorText
        }
        else {
            Show-Error $errorText # [console]::Error.WriteLine($errorText)
        }

        if ($CurrentTryNumber -lt $TryTimes) {
            $CurrentTryNumber += 1
            Show-Warning "Will try times-$CurrentTryNumber of $TryTimes ..."
            Start-Sleep -Seconds $SleepSeconds
            Invoke-CommandLine $CommandLine $ExitIfFailed $SuccessReturn $SuccessReturnRegex $TryTimes $CurrentTryNumber $HideCommand $HideCommand $HideAll
        }
    }
}

function Invoke-CommandLineDirectly {
    param(
        [string] $CommandLine,
        [bool] $ExitIfFailed = $true,
        [int] $SuccessReturn = 0,
        [string] $SuccessReturnRegex = "",
        [int] $TryTimes = 1,
        [int] $CurrentTryNumber = 1,
        [int] $SleepSeconds = 5,
        [string] $Tip = "",
        [bool] $HideCommand = $false,
        [bool] $HideReturn = $false,
        [bool] $HideAll = $false,
        [string] $ErrorActionCommand = '',
        [switch] $NoThrow
    )

    $tryInfo = if ($TryTimes -ne 1) { "Try[$CurrentTryNumber]-${TryTimes}: " } else { "" }
    $canThrow = $($CurrentTryNumber -eq $TryTimes) -and $(-not $NoThrow)
    $beginTime = [DateTime]::Now
    $isRobocopy = $CommandLine -imatch "\bROBOCOPY\s+"
    if (-not $HideCommand) {
        Show-Info $("Run Command: " + $CommandLine) -BackgroundColor White -ForegroundColor Blue
    }

    try {
        Invoke-Expression $CommandLine
        $returnValue = $LASTEXITCODE # if ($?) { 0 } else { $LASTEXITCODE }
        $hasMatchedValue = $false
        $reason = ""
        if ([string]::IsNullOrWhiteSpace($SuccessReturnRegex)) {
            $hasMatchedValue = $returnValue -eq $SuccessReturn
            $reason = "Expected return value = $SuccessReturn"
        } else {
            $hasMatchedValue = "$returnValue" -match $SuccessReturnRegex
            $reason = "Expected return value should match Regex: $SuccessReturnRegex"
        }
        $isFailed = if ($isRobocopy) { $returnValue -gt 7 } else { $(-not $hasMatchedValue) }
        $elapse = [DateTime]::Now - $beginTime
        if (-not $HideReturn) {
            $foreColor = if ($isFailed) { [System.ConsoleColor]::Red } else { [System.ConsoleColor]::Blue }
            Show-Info $("Used " + $elapse.TotalSeconds.ToString("F3") + " s, return value = $returnValue, LASTEXITCODE = $LASTEXITCODE, Command = $CommandLine") -ForegroundColor $foreColor -BackgroundColor White
        }
    } catch {
        $isFailed = $true
        $elapse = [DateTime]::Now - $beginTime
        if (-not [string]::IsNullOrWhiteSpace($Tip)) {
            [System.Console]::Error.WriteLine($Tip)
        }

        Show-ExceptionDetail $_.Exception $throwError | Write-Host -ForegroundColor Red
        if ($throwError) {
            if (-not [string]::IsNullOrWhiteSpace($ErrorActionCommand)) {
                Invoke-Expression $ErrorActionCommand
            }
            throw $_.Exception
        }
    }

    $elapse = [DateTime]::Now - $beginTime
    # Write-Host "TimeCost = $($elapse.TotalSeconds.ToString('F3')) s, ReturnValue = $returnValue, CommandLine = $CommandLine"

    if ($returnValue -lt 0 -or $($isFailed -and $ExitIfFailed)) {
        $errorText = "${TryInfo}Command failed with return value ${returnValue}($reason): ${CommandLine}"
        if (-not [string]::IsNullOrWhiteSpace($Tip)) {
            $errorText += "`n" + $Tip
        }

        if ($canThrow) {
            if (-not [string]::IsNullOrWhiteSpace($ErrorActionCommand)) {
                Invoke-Expression $ErrorActionCommand
            }
            throw $errorText
        }
        else {
            Write-Host -ForegroundColor Red $errorText # [console]::Error.WriteLine($errorText)
        }

        if ($CurrentTryNumber -lt $TryTimes) {
            $CurrentTryNumber += 1
            [console]::Error.WriteLine("Will try times-$CurrentTryNumber of $TryTimes ...")
            Start-Sleep -Seconds $SleepSeconds
            Invoke-CommandLineDirectly $CommandLine $ExitIfFailed $SuccessReturn $SuccessReturnRegex $TryTimes $CurrentTryNumber $HideCommand $HideCommand $HideAll
        }
    }
}

function Install-AppByNames {
    param (
        [string] $AppNames,
        [bool] $UpdateAtFirst = $false
    )

    if ($UpdateAtFirst -and -not [string]::IsNullOrWhiteSpace($SudoUpdateCmd)) {
        Invoke-CommandLine $SudoUpdateCmd
    }

    $CommandLine = $SudoInstallCmd + ' ' + $AppNames
    Invoke-CommandLine $CommandLine
}

function Get-OutputFilePath {
    param (
        [Parameter(Mandatory = $true)] [string] $InputFile,
        [string] $SavePath = '',
        [string] $ExtraSubNameMark = '',
        [string] $OutExtension = '',
        [bool] $AutoCreateSaveFolder = $true,
        [bool] $AllowSamePath = $false
    )

    if ([string]::IsNullOrEmpty($OutExtension)) {
        $OutExtension = [IO.Path]::GetExtension($SavePath).TrimStart('.')
        if ([string]::IsNullOrEmpty($OutExtension)) {
            $OutExtension = [IO.Path]::GetExtension($InputFile).TrimStart('.')
        }
    }

    $outputFileName = [IO.Path]::GetFileNameWithoutExtension($InputFile) + $ExtraSubNameMark + '.' + $OutExtension
    $inputFolder = [IO.Path]::GetDirectoryName($(Resolve-Path $InputFile))
    if ([string]::IsNullOrWhiteSpace($SavePath)) {
        $SavePath = Join-Path $inputFolder $outputFileName
    } if ([IO.Directory]::Exists($SavePath) -or $SavePath.EndsWith('\') -or $SavePath.EndsWith('/')) {
        $SavePath = Join-Path $SavePath $outputFileName
    }

    if ([string]::IsNullOrWhiteSpace($SavePath)) {
        throw "Failed to get save path, input file = $InputFile, ExtraSubNameMark = $ExtraSubNameMark, OutExtension = $OutExtension"
    }

    if (-not $AllowSamePath -and $InputFile -ieq $SavePath) {
        throw "SavePath is same with InputFile = $InputFile, ExtraSubNameMark = $ExtraSubNameMark, OutExtension = $OutExtension"
    }

    if ($AutoCreateSaveFolder) {
        $saveFolder = [IO.Path]::GetDirectoryName($SavePath)
        Test-CreateDirectory $saveFolder
    }

    return $SavePath
}

function Get-BytesFromSizeUnit {
    param(
      [string] $sizeUnitText
    )

    $SizeUnits = @{
      "B"  = 1;
      "KB" = 1024;
      "MB" = 1024 * 1024;
      "GB" = 1024 * 1024 * 1024;
      "TB" = 1024 * 1024 * 1024 * 1024;
      "PB" = 1024 * 1024 * 1024 * 1024 * 1024;
      "EB" = 1024 * 1024 * 1024 * 1024 * 1024 * 1024;
      "ZB" = 1024 * 1024 * 1024 * 1024 * 1024 * 1024 * 1024;
      "YB" = 1024 * 1024 * 1024 * 1024 * 1024 * 1024 * 1024 * 1024
    }

    $m = [regex]::Match($sizeUnitText, "(\d+(?:\.\d+)?)\s*([KMGTPEZY]?B)", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $($m.Success)) {
      throw "Failed to parse size unit text: $sizeUnitText"
    }

    $number = $m.Groups[1].Value -as [double]
    $unit = $m.Groups[2].Value
    $unitValue = $SizeUnits[$unit] -as [double]
    [double]$bytes = $number * $unitValue
    return $bytes
}

function Get-SizeAndUnit {
    param(
      [uint64] $Bytes,
      [int] $DecimalCount = 3,
      [string] $Separator = ' '
    )

    $units = @("B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB")
    [double] $number = $Bytes
    $k = 0
    for (; $number -ge 1024 -and $k -lt $units.Length; $k+=1) {
        $number /= 1024.0
    }

    $k = [Math]::Min($k, $units.Length - 1)
    return [Math]::Round($number, $DecimalCount).ToString() + $Separator + $units[$k]
}

# Auto generated exports by Update-PowerShell-Module-Exports.ps1
Export-ModuleMember -Variable ShouldQuoteArgRegex
Export-ModuleMember -Function Get-NowText
Export-ModuleMember -Function Get-GitRepoName
Export-ModuleMember -Function Show-MessageToHost
Export-ModuleMember -Function Show-Message
Export-ModuleMember -Function Show-Info
Export-ModuleMember -Function Show-Warning
Export-ModuleMember -Function Show-Error
Export-ModuleMember -Function Save-TextToFileUtf8NoBOM
Export-ModuleMember -Function Save-FileToUtf8NoBOM
Export-ModuleMember -Function Save-OutputToFileUtf8NoBOM
Export-ModuleMember -Function Get-QuotedArg
Export-ModuleMember -Function Join-CommandArgs
Export-ModuleMember -Function Test-CreateDirectory
Export-ModuleMember -Function Test-DeleteFiles
Export-ModuleMember -Function Show-ExceptionDetail
Export-ModuleMember -Function Trace-PathOccupation
Export-ModuleMember -Function Invoke-CommandLine
Export-ModuleMember -Function Invoke-CommandLineDirectly
Export-ModuleMember -Function Install-AppByNames
Export-ModuleMember -Function Get-OutputFilePath
Export-ModuleMember -Function Get-BytesFromSizeUnit
Export-ModuleMember -Function Get-SizeAndUnit
