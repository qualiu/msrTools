Import-Module "$PSScriptRoot/BasicOsUtils.psm1"
Import-Module "$PSScriptRoot/LogUtils.psm1"

$ShouldQuoteArgRegex = if ($IsWindowsOS) {
    New-Object System.Text.RegularExpressions.Regex('[\s&=;>\|]')
}
else {
    New-Object System.Text.RegularExpressions.Regex('[\s&=;:>\|\\]' + '|' + '\$[\$\?\d\{]')
}

$CommonJunkFolderPattern = "^([\.\$]|(Release|Debug|objd?|bin|node_modules|(Js)?Packages|\w+-packages?|static|dist|target|build)$|__pycache__)"
function Add-JunkFolderPattern {
    param(
        [string] $Pattern,
        [bool] $IsFullMatch
    )
    if ($IsFullMatch) {
        return $CommonJunkFolderPattern.Replace('|Debug|', "|Debug|$($Pattern)|")
    }
    else {
        return $CommonJunkFolderPattern.Insert($CommonJunkFolderPattern.Length - 1, $Pattern)
    }
}

$Global:HasLoadedNewtonJson = $false
$Global:DefaultNewtonJsonSettings = $null

function Install-JsonNewtonDll {
    param(
        [switch] $ThrowError
    )

    # TODO for Linux
    if (-not $IsWindowsOS) {
        return
    }

    Install-ToolByUrlIfNotFound "nuget" "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe"
    $packageFolder = Join-Path $TmpToolPackageFolder "Newtonsoft.Json"
    $jsonDll = msr -rp $packageFolder -f "^Newtonsoft.Json.dll$" -l -k 4 -d "^net\D*4" -T 1 -PAC 2>$null
    if (-not [IO.File]::Exists($jsonDll)) {
        [Console]::Error.WriteLine("Will install Json package + Extract + Load DLLs in $($packageFolder)")
        Invoke-CommandLine "nuget.exe install Newtonsoft.Json -Source https://www.nuget.org/api/v2 -OutputDirectory $($packageFolder)" -NoThrow $(-not $ThrowError)
    }

    $jsonDll = msr -rp $packageFolder -f "^Newtonsoft.Json.dll$" -l -k 4 -d "^net\D*4" -T 1 -PAC
    if (-not [IO.File]::Exists($jsonDll)) {
        Show-Error "Not found dll: Newtonsoft.Json.dll in descendant folder of $($packageFolder)" -ThrowError $ThrowError
    }

    if (-not [Reflection.Assembly]::LoadFile($jsonDll)) {
        Show-Error "Failed to load dll: $($jsonDll) : Return = $? , LASTEXITCODE = $($LASTEXITCODE)" -ThrowError $ThrowError
    }

    $Global:HasLoadedNewtonJson = $true
    $settings = New-Object Newtonsoft.Json.JsonSerializerSettings # requires net4.x DLL of Newtonsoft.Json
    $settings.NullValueHandling = [Newtonsoft.Json.NullValueHandling]::Ignore
    $settings.ReferenceLoopHandling = [Newtonsoft.Json.ReferenceLoopHandling]::Ignore
    $settings.PreserveReferencesHandling = [Newtonsoft.Json.PreserveReferencesHandling]::None
    $settings.TypeNameHandling = [Newtonsoft.Json.TypeNameHandling]::None
    $settings.Formatting = [Newtonsoft.Json.Formatting]::Indented
    $settings.DateFormatHandling = [Newtonsoft.Json.DateFormatHandling]::IsoDateFormat
    # $settings.DateFormatString = "yyyy-MM-ddTHH:mm:ss.fffZ"
    # $settings.DateTimeZoneHandling = [Newtonsoft.Json.DateTimeZoneHandling]::Utc
    $Global:DefaultNewtonJsonSettings = $settings
}

function Convert-ToJsonBetter {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)] $Obj,
        [switch] $Force
    )

    $isPowerShellObject = $Obj -is [System.Management.Automation.PSCustomObject]
    $text = if ($Global:HasLoadedNewtonJson -and $(-not $isPowerShellObject -or $Force)) {
        [Newtonsoft.Json.JsonConvert]::SerializeObject($Obj, $Global:DefaultNewtonJsonSettings)
    }
    else {
        $Obj | ConvertTo-Json -Depth 100
    }

    return $text
}

function Convert-FromJsonBetter {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)] [string] $Text
    )

    $obj = if ($Global:HasLoadedNewtonJson) {
        [Newtonsoft.Json.JsonConvert]::DeserializeObject($Text, $Global:DefaultNewtonJsonSettings)
    }
    else {
        $Text | ConvertFrom-Json
    }
    return $obj
}

function Get-NowText {
    param (
        [string] $Format = "yyyy-MM-dd HH:mm:ss.fff zzz"
    )

    return [DateTimeOffset]::Now.ToString($Format)
}

function Get-NowForFileName {
    param (
        [bool] $AsVarName = $false
    )

    $text = [DateTimeOffset]::Now.ToString('yyyy-MM-dd__HH_mm_ss_zzz').Replace(':', '_').Replace('+', "_")
    if ($AsVarName) {
        return $text.replace('-', '_')
    }
    else {
        return $text
    }
}


function Add-CommonLogInfo {
    param (
        [Parameter(Mandatory = $true)] $NameValueMap
    )

    foreach ($key in $NameValueMap.Keys) {
        $Global:CommonMetricsProperties[$key] = $NameValueMap[$key]
    }
}

function Add-GitRepoInfo {
    param (
        [Parameter(Mandatory = $true)] $GitRepoRootOrFullSubPath,
        [bool] $ForceUseHttpRepoUrl = $False
    )

    $repoInfo = New-GitRepoInfo $GitRepoRootOrFullSubPath $ForceUseHttpRepoUrl
    $map = @{ "GitBranch" = $repoInfo.BranchName; "GitCommit" = $repoInfo.CommitId; "GitTime" = $repoInfo.CommitTime; "GitRepoName" = $repoInfo.RepoName; }
    Add-CommonLogInfo $map
    return $repoInfo
}

function Get-ValidFileName {
    param (
        [string] $Name,
        [switch] $AddTime,
        [switch] $AsVarName,
        [switch] $NoSpace
    )

    if ($AddTime) {
        $head = [IO.Path]::GetFileNameWithoutExtension($Name)
        $extension = [IO.Path]::GetExtension($Name)
        $Name = $head + "-at-" + $(Get-NowForFileName) + $extension
    }

    if ($NoSpace) {
        $Name = [regex]::Replace($Name, '\s', '_')
    }

    if ($AsVarName) {
        return [regex]::Replace($Name, "\W", "_")
    }

    return [regex]::Replace($Name, "[^\w\. -]", "_")
}

function Add-TimeToFilePath {
    param (
        [string] $FilePath
    )
    $folder = [IO.Path]::GetDirectoryName($FilePath)
    $name = [IO.Path]::GetFileName($FilePath)
    $newName = Get-ValidFileName $name -AddTime
    $FilePath = Join-Path $folder $newName
    return $FilePath
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


<#
.DESCRIPTION
Write time + message to stdout, will cause error if in a function that has return values.
#>
function Show-MessageToOut {
    param (
        [string] $Message,
        $PropertiesMap = @{},
        [switch] $WriteLog
    )
    if ([string]::IsNullOrWhiteSpace($Message)) {
        Write-Output $Message
    }
    else {
        Write-Output "$(Get-NowText) $($Message)"
    }

    if ($WriteLog) {
        Write-AppMessage $Message -PropertiesMap $PropertiesMap
    }
}

<#
.DESCRIPTION
Write time + message to stderr, safe for functions that has return values.
#>
function Show-Message {
    param (
        [string] $Message,
        [System.ConsoleColor] $ForegroundColor = [System.ConsoleColor]::Black,
        [System.ConsoleColor] $BackgroundColor = [System.ConsoleColor]::Black,
        $PropertiesMap = @{},
        [switch] $WriteLog
    )
    $timeMessage = if ([string]::IsNullOrWhiteSpace($Message)) { $Message } else { "$(Get-NowText) $($Message)" }
    if ($ForegroundColor -ne [System.ConsoleColor]::Black -and $BackgroundColor -ne [System.ConsoleColor]::Black) {
        Write-Host $timeMessage -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
    }
    elseif ($ForegroundColor -ne [System.ConsoleColor]::Black) {
        Write-Host $timeMessage -ForegroundColor $foreGroundColor
    }
    elseif ($BackgroundColor -ne [System.ConsoleColor]::Black) {
        Write-Host $timeMessage -BackgroundColor $foreGroundColor
    }
    else {
        Write-Host $timeMessage
    }

    if ($WriteLog) {
        Write-AppMessage $Message -PropertiesMap $PropertiesMap
    }
}

<#
.DESCRIPTION
Write time + message to stderr, safe for functions that has return values.
#>
function Show-MessageLog {
    param (
        [string] $Message,
        [System.ConsoleColor] $ForegroundColor = [System.ConsoleColor]::Black,
        [System.ConsoleColor] $BackgroundColor = [System.ConsoleColor]::Black,
        $PropertiesMap = @{}
    )
    Show-Message $Message $ForegroundColor $BackgroundColor -PropertiesMap $PropertiesMap -WriteLog
}

<#
.DESCRIPTION
Write time + message to stderr, safe for functions that has return values.
#>
function Show-Info {
    param (
        [string] $Message,
        [System.ConsoleColor] $ForegroundColor = [System.ConsoleColor]::Green,
        [System.ConsoleColor] $BackgroundColor = [System.ConsoleColor]::Black,
        $PropertiesMap = @{}
    )
    Show-Message $Message $ForegroundColor $BackgroundColor
    Write-AppInfo $Message -PropertiesMap $PropertiesMap
}

<#
.DESCRIPTION
Write time + message to stderr, safe for functions that has return values.
#>
function Show-Warning {
    param (
        [string] $Message,
        [System.ConsoleColor] $ForegroundColor = [System.ConsoleColor]::Yellow,
        [System.ConsoleColor] $BackgroundColor = [System.ConsoleColor]::Black,
        $PropertiesMap = @{}
    )
    Show-Message $Message $ForegroundColor $BackgroundColor
    Write-AppWarning $Message -PropertiesMap $PropertiesMap
}

<#
.DESCRIPTION
Write time + message to stderr, safe for functions that has return values.
#>
function Show-Error {
    param (
        $MessageOrException,
        [System.ConsoleColor] $ForegroundColor = [System.ConsoleColor]::Red,
        [System.ConsoleColor] $BackgroundColor = [System.ConsoleColor]::Black,
        $PropertiesMap = @{},
        [switch] $ThrowError
    )

    $message = if ($MessageOrException -is [System.Exception]) {
        $MessageOrException.Message
    }
    else {
        $MessageOrException
    }

    Show-Message $message $ForegroundColor $BackgroundColor
    # [console]::Error.WriteLine($message)
    if ($ThrowError) {
        Show-CallStackThrowError $MessageOrException -PropertiesMap $PropertiesMap
    }
    else {
        # Show-CallStack
        Write-AppError $MessageOrException -PropertiesMap $PropertiesMap
    }
}

<#
.DESCRIPTION
Write time + message to stderr, safe for functions that has return values.
#>
function Show-ErrorThrow {
    param (
        $MessageOrException,
        [System.ConsoleColor] $ForegroundColor = [System.ConsoleColor]::Red,
        [System.ConsoleColor] $BackgroundColor = [System.ConsoleColor]::Black,
        $PropertiesMap = @{}
    )
    Show-Error $MessageOrException $ForegroundColor $BackgroundColor -ThrowError -PropertiesMap $PropertiesMap
}

function Show-CallStackThrowError {
    param(
        $MessageOrException,
        $PropertiesMap = @{}
    )
    Write-AppError $MessageOrException -PropertiesMap $PropertiesMap
    Show-CallStack
    throw $MessageOrException
}

<#
.DESCRIPTION
Write time + message to stderr, safe for functions that has return values.
#>
function Show-WarningOrInfo {
    param (
        [string] $Message,
        [bool] $IsWarning = $false,
        $PropertiesMap = @{}
    )

    if ($IsWarning) {
        Show-Warning $Message -PropertiesMap $PropertiesMap
    }
    else {
        Show-Info $Message -PropertiesMap $PropertiesMap
    }
}

<#
.DESCRIPTION
    Write time + message to stderr, safe for functions that has return values.
#>
function Show-ErrorOrInfo {
    param (
        [string] $Message,
        [bool] $IsError = $false,
        $PropertiesMap = @{},
        [switch] $ThrowError
    )

    if ($IsError) {
        if ($ThrowError) {
            Show-ErrorThrow $Message -PropertiesMap $PropertiesMap
        }
        else {
            Show-Error $Message -PropertiesMap $PropertiesMap
        }
    }
    else {
        Show-Info $Message -PropertiesMap $PropertiesMap
    }
}

<#
.DESCRIPTION
Write time + message to stderr, safe for functions that has return values.
#>
function Show-InfoOrMessage {
    param (
        [string] $Message,
        [bool] $IsInfo = $false,
        $PropertiesMap = @{}
    )

    if ($IsInfo) {
        Show-Info $Message -PropertiesMap $PropertiesMap
    }
    else {
        Show-MessageLog $Message -PropertiesMap $PropertiesMap
    }
}

<#
.DESCRIPTION
Write time + message to stderr, safe for functions that has return values.
#>
function Show-ErrorOrWarning {
    param (
        [string] $Message,
        [bool] $IsError = $false,
        $PropertiesMap = @{},
        [switch] $ThrowError
    )

    if ($IsError) {
        if ($ThrowError) {
            Show-ErrorThrow $Message -PropertiesMap $PropertiesMap
        }
        else {
            Show-Error $Message -PropertiesMap $PropertiesMap
        }
    }
    else {
        Show-Warning $Message -PropertiesMap $PropertiesMap
    }
}

<#
.DESCRIPTION
Write time + message to stderr, safe for functions that has return values.
#>
function Show-WarningOrMessage {
    param (
        [string] $Message,
        [bool] $IsWarning = $false,
        $PropertiesMap = @{}
    )

    if ($IsWarning) {
        Show-Warning $Message -PropertiesMap $PropertiesMap
    }
    else {
        Show-MessageLog $Message -PropertiesMap $PropertiesMap
    }
}

<#
.DESCRIPTION
Write time + message to stderr, safe for functions that has return values.
#>
function Show-ErrorOrMessage {
    param (
        [string] $Message,
        [bool] $IsError = $false,
        $PropertiesMap = @{},
        [switch] $ThrowError
    )

    if ($IsError) {
        if ($ThrowError) {
            Show-ErrorThrow $Message -PropertiesMap $PropertiesMap
        }
        else {
            Show-Error $Message -PropertiesMap $PropertiesMap
        }
    }
    else {
        Show-MessageLog $Message -PropertiesMap $PropertiesMap
    }
}

<#
.DESCRIPTION
Write time + message to stderr, safe for functions that has return values.
#>
function Show-ErrorWarnInfoMessage {
    param (
        [string] $Message,
        [bool] $IsError = $false,
        [bool] $IsWarning = $false,
        [bool] $IsInfo = $false,
        $PropertiesMap = @{},
        [switch] $ThrowError
    )

    if ($IsError) {
        if ($ThrowError) {
            Show-ErrorThrow $Message -PropertiesMap $PropertiesMap
        }
        else {
            Show-Error $Message -PropertiesMap $PropertiesMap
        }
    }
    elseif ($IsWarning) {
        Show-Warning $Message -PropertiesMap $PropertiesMap
    }
    elseif ($IsInfo) {
        Show-Info $Message -PropertiesMap $PropertiesMap
    }
    else {
        Show-MessageLog $Message -PropertiesMap $PropertiesMap
    }
}

<#
.DESCRIPTION
Write time + message to stderr, safe for functions that has return values.
#>
function Show-ErrorWarnInfo {
    param (
        [string] $Message,
        [bool] $IsError = $false,
        [bool] $IsWarning = $false,
        $PropertiesMap = @{},
        [switch] $ThrowError
    )

    if ($IsError) {
        if ($ThrowError) {
            Show-ErrorThrow $Message -PropertiesMap $PropertiesMap
        }
        else {
            Show-Error $Message -PropertiesMap $PropertiesMap
        }
    }
    elseif ($IsWarning) {
        Show-Warning $Message -PropertiesMap $PropertiesMap
    }
    else {
        Show-Info $Message -PropertiesMap $PropertiesMap
    }
}

function Save-TextToFileUtf8NoBOM {
    param (
        [Parameter(Mandatory = $true)] [string] $FilePath,
        [string] $AllText,
        [bool] $ShowMessage = $false,
        [bool] $IsAppend = $false,
        [bool] $SetTailOneNewLine = $false
    )

    if ($IsAppend) {
        [IO.File]::AppendAllText($FilePath, $AllText, $Utf8NoBomEncoding)
    }
    else {
        [IO.File]::WriteAllText($FilePath, $AllText, $Utf8NoBomEncoding)
    }

    if ($SetTailOneNewLine) {
        Set-FileEndWithOneNewLine $FilePath
    }

    if ($ShowMessage) {
        Write-Host -ForegroundColor Green "$(Get-NowText) Saved to file: $($FilePath)"
    }
}

function Save-FileToUtf8NoBOM {
    param (
        [Parameter(Mandatory = $true)] [string] $FilePath,
        [bool] $SetTailOneNewLine = $true
    )

    $lines = [IO.File]::ReadAllLines($FilePath)
    [IO.File]::WriteAllLines($FilePath, $lines, $Utf8NoBomEncoding)
    if ($SetTailOneNewLine) {
        Set-FileEndWithOneNewLine $FilePath
    }
}

function Save-OutputToFileUtf8NoBOM {
    param (
        [Parameter(Mandatory = $true)] [string] $FilePath,
        [bool] $SetTailOneNewLine = $true,
        [Parameter(ValueFromPipeline = $true)] [string] $line
    )

    begin {
        $AllLines = @()
    }

    process {
        $AllLines += $line
    }

    end {
        # [IO.File]::WriteAllLines($FilePath, $AllLines, $Utf8NoBomEncoding) # Avoid no overload of Object[]
        $allText = [string]::Join([System.Environment]::NewLine, $AllLines)
        [IO.File]::WriteAllText($FilePath, $allText, $Utf8NoBomEncoding)
        if ($SetTailOneNewLine) {
            Set-FileEndWithOneNewLine $FilePath
        }
    }
}

function Save-OutputAppendToFileUtf8NoBOM {
    param (
        [Parameter(Mandatory = $true)] [string] $FilePath,
        [bool] $SetTailOneNewLine = $true,
        [Parameter(ValueFromPipeline = $true)] [string] $line
    )

    begin {
        $AllLines = @()
    }

    process {
        $AllLines += $line
    }

    end {
        # [IO.File]::AppendAllLines($FilePath, $AllLines, $Utf8NoBomEncoding) # Avoid no overload of Object[]
        $allText = [string]::Join([System.Environment]::NewLine, $AllLines)
        [IO.File]::AppendAllText($FilePath, $allText, $Utf8NoBomEncoding)
        if ($SetTailOneNewLine) {
            Set-FileEndWithOneNewLine $FilePath
        }
    }
}

function Set-FileEndWithOneNewLine {
    param (
        [Parameter(Mandatory = $true)] [string] $FilePath,
        [string] $ExtraAppend = ""
    )
    msr -p $FilePath -S -t "(\S+)\s*$" -o "\1\n" -R -M -T 0 -H 0
    if (-not [string]::IsNullOrEmpty($ExtraAppend)) {
        [IO.File]::AppendAllText($FilePath, $ExtraAppend)
    }
}

function Backup-ObjectToFile {
    param (
        [Parameter(Mandatory = $true)] $Obj,
        [Parameter(Mandatory = $true)] [string] $SavePath,
        [string] $MessageHead = "Wrote backup file:"
    )

    Write-ObjectToFile $Obj $SavePath $MessageHead
}

function Write-ObjectToFile {
    param (
        [Parameter(Mandatory = $true)] $Obj,
        [Parameter(Mandatory = $true)] [string] $SavePath,
        [string] $MessageHead = "Saved to file:"
    )

    $json = $Obj | ConvertTo-Json -Depth 100
    Save-TextToFileUtf8NoBOM $SavePath $json
    Show-Info "$($MessageHead) $($SavePath)"
}

function Compare-TextInPromptWindow {
    param (
        [string] $Name,
        [string] $OldText,
        [string] $NewText,
        [string] $OldSuffix = "old",
        [string] $NewSuffix = "new",
        [string] $Extension = ".txt"
    )

    $tmpOldFile = Join-Path $SysTmpFolder $(Get-ValidFileName $($Name + "--" + $OldSuffix + $Extension))
    $tmpNewFile = Join-Path $SysTmpFolder $(Get-ValidFileName $($Name + '--' + $NewSuffix + $Extension))
    Save-TextToFileUtf8NoBOM $tmpOldFile $OldText
    Save-TextToFileUtf8NoBOM $tmpNewFile $NewText
    BCompare $tmpOldFile $tmpNewFile
}

function Get-QuotedArg {
    param (
        [string] $Path,
        [string] $Quote = '"'
    )

    # $quote = '"' # if ($IsWindowsOS) { '"' } else { "'" }
    if ($ShouldQuoteArgRegex.IsMatch($Path)) {
        return $Quote + $Path + $Quote
    }
    else {
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

function Show-ExceptionDetails {
    param(
        [Parameter(Mandatory = $true)] $err,
        [int] $level = 1
    )

    if ($err.ErrorDetails -and $(-not [string]::IsNullOrWhiteSpace($err.ErrorDetails.Message))) {
        Show-Error $err.ErrorDetails.Message
    }

    $ex = if ($err.Exception) { $err.Exception } else { $err }
    $errorInfo = if ($ex.StatusCode -and ($ex.GetType().ToString() -ne "System.Exception")) {
        "Exception[$($level)]: Type = $($ex.GetType()) , StatusCode = $($ex.StatusCode) , Message = $($ex.Message)"
    }
    else {
        $ex.Message
    }
    Show-Error $errorInfo
    Show-Error $ex.StackTrace
    Write-Host ""
    if ($ex.InnerException) {
        Show-ExceptionDetails $ex.InnerException $($level + 1)
    }
}

function Show-Exception {
    param (
        $err,
        [System.ConsoleColor] $ForegroundColor = [System.ConsoleColor]::Red,
        [System.ConsoleColor] $BackgroundColor = [System.ConsoleColor]::Black,
        [switch] $ThrowError
    )
    # [console]::Error.WriteLine($Message)
    Show-ExceptionDetails $err $ForegroundColor $BackgroundColor
    Write-AppException $err
    if ($ThrowError) {
        throw $err
    }
}

function Show-ExceptionThrow {
    param (
        $err,
        [System.ConsoleColor] $ForegroundColor = [System.ConsoleColor]::Red,
        [System.ConsoleColor] $BackgroundColor = [System.ConsoleColor]::Black
    )
    Show-Exception $err $ForegroundColor $BackgroundColor -ThrowError
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
        $tmpSave = Join-Path $SysTmpFolder "Handle.zip"
        Get-FileFromUrl "https://download.sysinternals.com/files/Handle.zip" $tmpSave
        Expand-ZipFile $tmpSave -DestinationPath $SysTmpFolder
        $handlePath = Join-Path $SysTmpFolder "handle.exe"
    }

    $output = & $handlePath $path -NoBanner
    Show-Warning "File occupation of $($path) as below:`n$($output)"
}

<#
.DESCRIPTION
Running a command in a temp call, thus protect current environment(variables) from any possible changes by the command.
#>
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
        [switch] $NoThrow,
        [switch] $NotWriteLog
    )

    $tryInfo = if ($TryTimes -ne 1) { "Try[$($CurrentTryNumber)]-$($TryTimes): " } else { "" }
    $canThrow = $($CurrentTryNumber -eq $TryTimes) -and $(-not $NoThrow)
    $beginTime = [DateTime]::Now
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

    $elapse = [DateTime]::Now - $beginTime
    $returnValue = $LASTEXITCODE
    $infoMap = @{ "Action" = "Execute" ; "CommandLine" = $CommandLine; "ReturnValue" = $returnValue; "TimeCost" = $elapse.ToString(); "TimeCostSeconds" = $elapse.TotalSeconds }
    $eventName = [regex]::Replace($CommandLine, "^((PowerShell|pwsh|call|start)\s+)?\S*[\\/]([^\s/\\]+).*", '$2', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $hasMatchedValue = $false
    $reason = ""
    if ([string]::IsNullOrWhiteSpace($SuccessReturnRegex)) {
        $hasMatchedValue = $returnValue -eq $SuccessReturn
        $reason = "Expected return value = $($SuccessReturn)"
    }
    else {
        $hasMatchedValue = "$($returnValue)" -match $SuccessReturnRegex
        $reason = "Expected return value should match Regex: $($SuccessReturnRegex)"
    }

    $isFailed = if ($isRobocopy) { $returnValue -gt 7 }  else { $(-not $hasMatchedValue) }
    if ($(-not $NotWriteLog) -or $isFailed) {
        if (-not [string]::IsNullOrEmpty($eventName)) {
            Write-AppEvent $eventName $infoMap
        }
        elseif ($HideReturn) {
            Write-AppMessage "TimeCost = $($elapse.TotalSeconds.ToString('F3')) s, ReturnValue = $($returnValue), CommandLine = $($CommandLine)"
        }
    }

    # Trace file occupation root cause:
    if ($($returnValue -ne 0) -and $($CommandLine -imatch "\brd(\s+/[qs])+ (.+)")) {
        $deletionPath = $CommandLine -ireplace '.*\brd(\s+/[qs])+ (.+)', '$2'
        if (-not $(Test-Path $deletionPath)) {
            Show-Warning "$($TryInfo)Command return = $($returnValue), but deleted and not found $($deletionPath) : $($CommandLine)"
        }
        else {
            Trace-PathOccupation $deletionPath
        }
    }

    if ($returnValue -lt 0 -or $($isFailed -and $ExitIfFailed)) {
        $errorText = "$($TryInfo)Command failed with return value $($returnValue)($($reason)): $($CommandLine)"
        if (-not [string]::IsNullOrWhiteSpace($Tip)) {
            $errorText += "`n" + $Tip
        }

        if ($canThrow) {
            if (-not [string]::IsNullOrWhiteSpace($ErrorActionCommand)) {
                Invoke-Expression $ErrorActionCommand
            }
            Show-CallStackThrowError $errorText
        }
        else {
            Show-Error $errorText # [console]::Error.WriteLine($errorText)
        }

        if ($CurrentTryNumber -lt $TryTimes) {
            $CurrentTryNumber += 1
            Show-Warning "Will try times-$($CurrentTryNumber) of $($TryTimes) ..."
            Start-Sleep -Seconds $SleepSeconds
            Invoke-CommandLine $CommandLine $ExitIfFailed $SuccessReturn $SuccessReturnRegex $TryTimes $CurrentTryNumber $HideCommand $HideCommand $HideAll
        }
    }
}

<#
.DESCRIPTION
Running a command directly, current environment(variables) may be changed by the command.
#>
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
        [switch] $NoThrow,
        [switch] $NotWriteLog
    )
    $tryInfo = if ($TryTimes -ne 1) { "Try[$($CurrentTryNumber)]-$($TryTimes): " } else { "" }
    $canThrow = $($CurrentTryNumber -eq $TryTimes) -and $(-not $NoThrow)
    $beginTime = [DateTime]::Now
    $isRobocopy = $CommandLine -imatch "\bROBOCOPY\s+"
    if (-not $HideCommand) {
        Show-Info "Run Command: $($CommandLine)" -BackgroundColor White -ForegroundColor Blue
    }

    try {
        Invoke-Expression $CommandLine
        $returnValue = $LASTEXITCODE # if ($?) { 0 } else { $LASTEXITCODE }
        $hasMatchedValue = $false
        $reason = ""
        if ([string]::IsNullOrWhiteSpace($SuccessReturnRegex)) {
            $hasMatchedValue = $returnValue -eq $SuccessReturn
            $reason = "Expected return value = $($SuccessReturn)"
        }
        else {
            $hasMatchedValue = "$($returnValue)" -match $SuccessReturnRegex
            $reason = "Expected return value should match Regex: $($SuccessReturnRegex)"
        }
        $isFailed = if ($isRobocopy) { $returnValue -gt 7 } else { $(-not $hasMatchedValue) }
        $elapse = [DateTime]::Now - $beginTime
        $infoMap = @{ "Action" = "Execute" ; "CommandLine" = $CommandLine; "ReturnValue" = $returnValue; "TimeCost" = $elapse.ToString(); "TimeCostSeconds" = $elapse.TotalSeconds }
        $eventName = [regex]::Replace($CommandLine, "^((PowerShell|pwsh|call|start)\s+)?\S*[\\/]([^\s/\\]+).*", '$2', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        if (-not [string]::IsNullOrEmpty($eventName)) {
            if ($(-not $NotWriteLog) -or $isFailed) {
                Write-AppEvent $eventName $infoMap
            }
        }
        elseif ($HideReturn) {
            if ($(-not $NotWriteLog) -or $isFailed) {
                Write-AppMessage "TimeCost = $($elapse.TotalSeconds.ToString('F3')) s, ReturnValue = $($returnValue), LASTEXITCODE = $($LASTEXITCODE), CommandLine = $($CommandLine)"
            }
        }
        else {
            $foreColor = if ($isFailed) { [System.ConsoleColor]::Red } else { [System.ConsoleColor]::Blue }
            if ($(-not $NotWriteLog) -or $isFailed) {
                Show-ErrorOrInfo $("Used " + $elapse.TotalSeconds.ToString("F3") + " s, return value = $($returnValue), LASTEXITCODE = $($LASTEXITCODE), Command = $($CommandLine)") -IsError $isFailed -ForegroundColor $foreColor -BackgroundColor White
            }
        }
    }
    catch {
        $isFailed = $true
        $elapse = [DateTime]::Now - $beginTime
        $infoMap = @{ "Action" = "Execute" ; "CommandLine" = $CommandLine; "ReturnValue" = $returnValue; "LastExitCode" = $LASTEXITCODE; "TimeCost" = $elapse.ToString(); "TimeCostSeconds" = $elapse.TotalSeconds }
        Write-AppException $_.Exception $infoMap
        if (-not [string]::IsNullOrWhiteSpace($Tip)) {
            [System.Console]::Error.WriteLine($Tip)
        }

        Show-ExceptionDetails $_ $throwError | Write-Host -ForegroundColor Red
        if ($throwError) {
            if (-not [string]::IsNullOrWhiteSpace($ErrorActionCommand)) {
                Invoke-Expression $ErrorActionCommand
            }
            Show-CallStackThrowError $_.Exception
        }
    }

    $elapse = [DateTime]::Now - $beginTime
    # Write-Host "TimeCost = $($elapse.TotalSeconds.ToString('F3')) s, ReturnValue = $returnValue, CommandLine = $CommandLine"

    if ($returnValue -lt 0 -or $($isFailed -and $ExitIfFailed)) {
        $errorText = "$($TryInfo)Command failed with return value $($returnValue)($($reason)): $($CommandLine)"
        if (-not [string]::IsNullOrWhiteSpace($Tip)) {
            $errorText += "`n" + $Tip
        }

        if ($canThrow) {
            if (-not [string]::IsNullOrWhiteSpace($ErrorActionCommand)) {
                Invoke-Expression $ErrorActionCommand
            }
            Show-CallStackThrowError $errorText
        }
        else {
            Show-Error $errorText # [console]::Error.WriteLine($errorText)
        }

        if ($CurrentTryNumber -lt $TryTimes) {
            $CurrentTryNumber += 1
            [console]::Error.WriteLine("Will try times-$($CurrentTryNumber) of $($TryTimes) ...")
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
        Show-CallStackThrowError "Failed to get save path, input file = $($InputFile), ExtraSubNameMark = $($ExtraSubNameMark), OutExtension = $($OutExtension)"
    }

    if (-not $AllowSamePath -and $InputFile -ieq $SavePath) {
        Show-CallStackThrowError "SavePath is same with InputFile = $($InputFile), ExtraSubNameMark = $($ExtraSubNameMark), OutExtension = $($OutExtension)"
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
        Show-CallStackThrowError "Failed to parse size unit text: $($sizeUnitText)"
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
    for (; $number -ge 1024 -and $k -lt $units.Length; $k += 1) {
        $number /= 1024.0
    }

    $k = [Math]::Min($k, $units.Length - 1)
    return [Math]::Round($number, $DecimalCount).ToString() + $Separator + $units[$k]
}

function Copy-FilesFromMachine {
    param (
        [Parameter(Mandatory = $true)] [string] $SourceMachine,
        [Parameter(Mandatory = $true)] [string] $SourcePath,
        [Parameter(Mandatory = $true)] [string] $LocalSavePath,
        [bool] $IsRecursive = $true
    )

    $sshArgs = if ($IsWindowsOS) {
        $sshConfig = [IO.Path]::Combine($env:HOME, '.ssh', 'config')
        $sshKey = [IO.Path]::Combine($env:HOME, '.ssh', 'id_rsa')
        '-e "ssh -i ' + $sshKey + ' -F ' + $sshConfig + '"' # + " -W ${SourceMachine}:22"""
    }
    else {
        ""
    }

    $recursiveArg = if ($IsRecursive) { '-r' } else { '' }
    $rsyncArgs = $($recursiveArg + ' -a -p -u -z -v').Trim() -replace '\s+-(\w)\b', '$1'
    $scpArgs = $($recursiveArg + ' -p').Trim() -replace '\s+-(\w)\b', '$1'

    if ($IsWindowsOS) {
        $LocalSavePath = $LocalSavePath.Replace('/', '\')
        # TODO: rsync got error if need ssh config/auth, so use scp instead, please check/change in future.
        # Invoke-CommandLine "$($PushFolderCmd) $($LocalSavePath) && rsync $($sshArgs) $($rsyncArgs) $($SourceMachine):$($SourcePath)/* ."
        Invoke-CommandLine "scp $($scpArgs) $($SourceMachine):$($SourcePath) $($LocalSavePath)"
    }
    else {
        Invoke-CommandLine "rsync $($rsyncArgs) $($SourceMachine):$($SourcePath) $($LocalSavePath)"
    }
}

function Get-HtmlLinkText {
    param (
        [Parameter(Mandatory = $true)] [string] $Text,
        [Parameter(Mandatory = $true)] [string] $LinkUrl
    )

    return "<a href=`"$($LinkUrl)`" target=`"_blank`">$($Text)</a>"
}

function Complete-MailAddress {
    param (
        [Parameter(Mandatory = $true)] [string] $address,
        [string] $DefaultMailBoxSuffix = "@microsoft.com"
    )

    if ([String]::IsNullOrWhitespace($address)) {
        return $address
    }

    if ($address.Contains("@")) {
        return $address
    }

    return $address + $DefaultMailBoxSuffix
}

<#
.DESCRIPTION
This function need to be run as user(employee) role on user machine, not in a scheduled task.
#>
function Send-MailByUser {
    param(
        [Parameter(Mandatory = $true)] [string] $Subject,
        [Parameter(Mandatory = $true)] [string] $Body,
        [Parameter(Mandatory = $true)] [string] $To, # Use ',' or ';' to separate if multiple aliases or addresses.
        [string] $CopyTo = "", # Use ',' or ';' to separate if multiple aliases or addresses.
        [string] $From = "$($env:USERNAME)@microsoft.com",
        [string] $BlindCarbonCopyTo = "",
        [string] $SmtpServer = "smtphost.corp.microsoft.com",
        [string] $Attachments = "", # File paths separated by ',' or ';'
        [string] $DefaultMailBoxSuffix = "@microsoft.com",
        [bool] $IsBodyHtml = $False
    )

    $message = New-Object System.Net.Mail.MailMessage
    $message.From = New-Object System.Net.Mail.MailAddress($(Complete-MailAddress $From $DefaultMailBoxSuffix))
    foreach ($address in [Regex]::Split($To, "\s*[,;]\s*") ) {
        if ( -not [String]::IsNullOrWhitespace($address)) {
            $message.To.Add($(Complete-MailAddress $address $DefaultMailBoxSuffix))
        }
    }

    foreach ($address in [Regex]::Split($CopyTo, "\s*[,;]\s*") ) {
        if ( -not [String]::IsNullOrWhitespace($address)) {
            $message.CC.Add($(Complete-MailAddress $address $DefaultMailBoxSuffix))
        }
    }

    foreach ($address in [Regex]::Split($BlindCarbonCopyTo, "\s*[,;]\s*") ) {
        if ( -not [String]::IsNullOrWhitespace($address)) {
            $message.Bcc.Add($(Complete-MailAddress $address $DefaultMailBoxSuffix))
        }
    }

    foreach ($file in [Regex]::Split($Attachments, "\s*[,;]\s*") ) {
        if ( -not [String]::IsNullOrWhitespace($file)) {
            if (Test-Path $file) {
                $message.Attachments.Add($(New-Object System.Net.Mail.Attachment($file)))
            }
            else {
                Write-Error "Not exist attachment file : $($file)"
            }
        }
    }

    $message.Subject = $Subject
    $message.Body = $Body
    $message.IsBodyHtml = $IsBodyHtml
    try {
        $client = New-Object System.Net.Mail.SmtpClient($SmtpServer)
        $client.Credentials = [System.Net.CredentialCache]::DefaultCredentials
        $client.Send($message)
    }
    catch {
        Show-Error "Failed to send mail: $($_.Exception.Message)"
        Show-Exception $_
    }
}

function Expand-MatchedText {
    param (
        [Parameter(Mandatory = $true)] [string] $Text,
        [Parameter(Mandatory = $true)][int] $MatchedIndex,
        [Parameter(Mandatory = $true)][int] $MatchedLength,
        [bool] $TruncateAtNewLines = $true,
        [bool] $ShowFullQueryBody = $false,
        [int] $MaxHeadChars = 30,
        [int] $MaxTailChars = 260
    )

    if ($ShowFullQueryBody) {
        try {
            $boardObject = $Text | ConvertFrom-Json
            if ($boardObject) {
                if (-not [string]::IsNullOrWhiteSpace($boardObject.queryText)) {
                    return $boardObject.queryText
                }
                if ($boardObject.content -and -not [string]::IsNullOrWhiteSpace($boardObject.content.query)) {
                    return $boardObject.content.query
                }
            }
        }
        catch {
            return $Text
        }
    }

    $beginIndex = [Math]::Max(0, $MatchedIndex - 15)
    $stopBeginIndex = [Math]::Max(0, $MatchedIndex - $MaxHeadChars)
    if ($TruncateAtNewLines) {
        $newLineIndex = $Text.LastIndexOf("`n", $MatchedIndex, [Math]::Min($MaxHeadChars, $MatchedIndex))
        if ($newLineIndex -lt 0) {
            $newLineIndex = $Text.LastIndexOf("\\n", $beginIndex, $beginIndex - $stopBeginIndex + 1)
        }
        $beginIndex = if ($newLineIndex -ge 0) { $newLineIndex + 1 } else { $stopBeginIndex } # $Text.LastIndexOf("`n", $beginIndex, $MatchedIndex - $beginIndex + 1)
    }
    else {
        $beginIndex = $stopBeginIndex
    }

    $endIndex = [Math]::Min($Text.Length - 1, $MatchedIndex + $MatchedLength + 15)
    $stopEndIndex = [Math]::Min($Text.Length - 1, $endIndex + $MaxTailChars)
    if ($TruncateAtNewLines) {
        $newLineIndex = $Text.IndexOf("`n", $MatchedIndex + $MatchedLength, [Math]::Min($MaxTailChars, $Text.Length - $($MatchedIndex + $MatchedLength)))
        if ($newLineIndex -lt 0) {
            $newLineIndex = $Text.IndexOf("\\n", $endIndex, $stopEndIndex - $endIndex + 1)
        }
        $endIndex = if ($newLineIndex -ge 0) { $newLineIndex - 1 } else { $stopEndIndex }
    }
    else {
        $endIndex = $stopEndIndex
    }

    $expandedText = $Text.Substring($beginIndex, $endIndex - $beginIndex + 1)
    return $expandedText
}

function Get-TextMd5Hash {
    param (
        [string] $Text
    )

    $md5 = New-Object System.Security.Cryptography.MD5CryptoServiceProvider
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hashBytes = $md5.ComputeHash($bytes)
    $md5Value = [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLower()
    return $md5Value;
}

function Test-InstallApp {
    param (
        [Parameter(Mandatory = $true)] [string] $CheckName,
        [string] $InstallAppName,
        [string] $ExtraArgs = '',
        [bool] $ShowInfo = $true,
        [bool] $NoThrow = $false
    )

    if ([string]::IsNullOrWhiteSpace($InstallAppName)) {
        $InstallAppName = $CheckName
    }

    if ($ShowInfo) {
        Show-Message "Will check $($CheckName) and install $($InstallAppName) ..."
    }

    Get-Command $CheckName 2>$null
    if (-not $?) {
        Invoke-CommandLine "$($SudoInstallCmd) $($InstallAppName) $($ExtraArgs)" -NoThrow $NoThrow
    }
}

function Start-CommandAsync {
    param (
        [string] $CommandLine,
        [string] $WorkingDirectory = ''
    )
    if ($IsWindowsOS) {
        Show-MessageLog $CommandLine -ForegroundColor Green
        if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $WorkingDirectory = [IO.Directory]::GetCurrentDirectory()
        }

        Start-Process cmd -ArgumentList @('/c', $CommandLine) -WorkingDirectory $WorkingDirectory
    }
    else {
        if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            Invoke-CommandLine "$($CommandLine) &"
        }
        else {
            Invoke-CommandLine "$($PushFolderCmd) $($WorkingDirectory) && $($CommandLine) &"
        }
    }
}

<#
.DESCRIPTION
Get args for psall.bat + pskill.bat on Windows.
#>
function Get-CallArgsForPsBatch {
    param (
        [string] $MatchPattern,
        [string] $MatchPlainText = "",
        [string] $ExcludePattern = "",
        [string] $ExcludePlainText = "",
        [bool] $IgnoreCase = $false
    )

    if ([string]::IsNullOrWhiteSpace($MatchPattern + $MatchPlainText + $ExcludePattern + $ExcludePlainText)) {
        Show-ErrorThrow "You must provide at least 1 process command line matching parameter."
    }

    $callArgs = @()
    if ($IgnoreCase) {
        $callArgs += @("-i")
    }
    if (-not [string]::IsNullOrWhiteSpace($MatchPattern)) {
        $callArgs += @("-t", $MatchPattern)
    }
    if (-not [string]::IsNullOrWhiteSpace($MatchPlainText)) {
        $callArgs += @("-x", $MatchPlainText)
    }
    if (-not [string]::IsNullOrWhiteSpace($ExcludePattern)) {
        $callArgs += @("--nt", $ExcludePattern)
    }
    if (-not [string]::IsNullOrWhiteSpace($ExcludePlainText)) {
        $callArgs += @("--nx", $ExcludePlainText)
    }

    return $callArgs
}

function Get-ProcessByFilter {
    param (
        [string] $MatchPattern,
        [string] $MatchPlainText = "",
        [string] $ExcludePattern = "\bmsr\s+-+\w+",
        [string] $ExcludePlainText = "",
        [bool] $IgnoreCase = $false,
        [string[]] $ExtraArgs = @("-PM")
    )

    $callArgs = Get-CallArgsForPsBatch $MatchPattern $MatchPlainText $ExcludePattern $ExcludePlainText $IgnoreCase
    if ($IsWindowsOS) {
        $argText = $($(Join-CommandArgs $callArgs) + " " + $ExtraArgs).Trim()
        Invoke-CommandLine $("psall.bat " + $argText) -HideReturn $true -SuccessReturnRegex .
        return
    }

    $callArgs += $ExtraArgs
    ps -ef | msr $callArgs
}


function Stop-ProcessByFilter {
    param (
        [string] $MatchPattern,
        [string] $MatchPlainText = "",
        [string] $ExcludePattern = "\bmsr\s+-+\w+",
        [string] $ExcludePlainText = "",
        [bool] $IgnoreCase = $false,
        [string[]] $ExtraArgs = @("-PM")
    )

    $callArgs = Get-CallArgsForPsBatch $MatchPattern $MatchPlainText $ExcludePattern $ExcludePlainText $IgnoreCase
    $callArgs += $ExtraArgs
    if ($IsWindowsOS) {
        $argText = Join-CommandArgs $callArgs # $($(Join-CommandArgs $callArgs) + " " + $ExtraArgs).Trim()
        # pskill.bat $callArgs # Start-Process -FilePath $(Get-Command pskill.bat).Source -ArgumentList $callArgs
        Invoke-CommandLine $("pskill.bat " + $argText) -HideReturn $true -SuccessReturnRegex .
        return
    }

    ps -ef | msr $callArgs
    $pureArgs = Get-AddableMsrArgs $callArgs @("-P", "-A", "-C")
    ps -ef | msr $callArgs $pureArgs | msr -t "^\s*\d+\s+(\d+).*" -o "\1" -PAC | msr -S -t "\s+(\d+)" -o " \1" -PAC `
    | msr -t "(.+)" -o "kill \1" -XM
}

$msrShortCmdToLongNameMap = @{}
$msrLongCmdToShortNameMap = @{}
foreach ($text in $(msr -h -C | msr -q "^\s*-h" -it "^\s*(-[a-z])\s+\[\s*(--\w+[\w-]+)\s*\].*" -o "\1 \2" -PAC)) {
    $a = $text -split ' '
    $msrShortCmdToLongNameMap[$a[0]] = $a[1]
    $msrLongCmdToShortNameMap[$a[1]] = $a[0]
}

function Get-AddableMsrArgs {
    param (
        $ExistingArgs,
        [string[]] $ToAddArgs
    )
    $addableArgs = @()
    $existingLongNames = msr -z test $ExistingArgs --verbose 2>&1 | msr -t "^(-+\w+[\w-]+)\s*=.*" -o "\1" -PAC
    $existingShortNames = @()
    foreach ($longName in $existingLongNames) {
        $existingShortNames += $msrLongCmdToShortNameMap[$longName]
    }

    foreach ($argName in $ToAddArgs) {
        if ($existingLongNames.Contains($argName) -or $existingShortNames.Contains($argName)) {
            continue
        }
        $addableArgs += $argName
    }
    return $addableArgs
}

class BeginEndLogger : System.IDisposable {
    [System.DateTimeOffset] $BeginTime
    [String] $CommandLine
    [string] $EventName
    [bool] $ShowFinalTimeCost
    BeginEndLogger([System.DateTimeOffset] $BeginTime, [string] $CommandLine, [string] $EventName, [bool] $ShowFinalTimeCost) {
        $this.BeginTime = $BeginTime
        $this.CommandLine = $CommandLine
        $this.EventName = $EventName
        $this.ShowFinalTimeCost = $ShowFinalTimeCost
        $this.WriteBeginLog()
    }

    BeginEndLogger([string] $CommandLine, [string] $EventName, [bool] $ShowFinalTimeCost) {
        $this.BeginTime = [System.DateTimeOffset]::Now
        $this.CommandLine = $CommandLine
        $this.EventName = $EventName
        $this.ShowFinalTimeCost = $ShowFinalTimeCost
        $this.WriteBeginLog()
    }

    [void] WriteBeginLog() {
        Write-AppEvent $this.EventName @{ "Action" = "Begin" ; "CommandLine" = $this.CommandLine }
    }

    <#
    .DESCRIPTION
    This method is supposed to be auto-called but current PowerShell cannot support this.
    #>
    [void] Dispose() {
        if ($this.ShowFinalTimeCost) {
            $elapse = [System.DateTimeOffset]::Now - $this.BeginTime
            Write-Host "TimeCost = $([regex]::Replace($elapse.ToString(), '(\.\d{3})\d*', '$1')): $($this.CommandLine)"
        }
        Write-AppEvent $this.EventName @{ "Action" = "End" ; "CommandLine" = $this.CommandLine ; } -BeginTime $this.BeginTime
    }
}

function New-BeginEndLogger {
    param (
        [Parameter(Mandatory = $true)] $invocation,
        [bool] $ShowCommandLine = $true,
        [bool] $ShowFinalTimeCost = $true
    )
    $command = Get-QuotedArg $invocation.MyCommand.Source
    foreach ($key in $invocation.BoundParameters.Keys) {
        $value = $invocation.BoundParameters[$key]
        $valueTypeName = $value.GetType().Name
        if ($($valueTypeName -imatch 'switch')) {
            if ($value.IsPresent) {
                $command += " -$($key)"
            }
        }
        elseif ($valueTypeName -imatch 'bool') {
            # if ($IsWindowsOS) {
            #     $command += " -$($key) $" + $value
            # }
            # else {
            if ($value) {
                $command += " -$($key) 1"
            }
            else {
                $command += " -$($key) 0"
            }
            # }
        }
        else {
            $command += " -$($key) " + $(Get-QuotedArg $value -Quote "'")
        }
    }
    $scriptPath = $invocation.MyCommand.Source
    $name = [IO.Path]::GetFileName($scriptPath)
    $logger = New-Object BeginEndLogger($command, $name, $ShowFinalTimeCost)
    if ($ShowCommandLine) {
        Show-Message $command
    }
    # Register-EngineEvent PowerShell.Exiting -Action { $logger.WriteEndLog() } | Out-Null
    return $logger
}

# Install-JsonNewtonDll -ThrowError $false

# Auto generated exports by Update-PowerShell-Module-Exports.ps1
Export-ModuleMember -Variable ShouldQuoteArgRegex
Export-ModuleMember -Variable CommonJunkFolderPattern
Export-ModuleMember -Function Add-JunkFolderPattern
Export-ModuleMember -Function Install-JsonNewtonDll
Export-ModuleMember -Function Convert-ToJsonBetter
Export-ModuleMember -Function Convert-FromJsonBetter
Export-ModuleMember -Function Get-NowText
Export-ModuleMember -Function Get-NowForFileName
Export-ModuleMember -Function Add-CommonLogInfo
Export-ModuleMember -Function Add-GitRepoInfo
Export-ModuleMember -Function Get-ValidFileName
Export-ModuleMember -Function Add-TimeToFilePath
Export-ModuleMember -Function Get-GitRepoName
Export-ModuleMember -Function Show-MessageToOut
Export-ModuleMember -Function Show-Message
Export-ModuleMember -Function Show-MessageLog
Export-ModuleMember -Function Show-Info
Export-ModuleMember -Function Show-Warning
Export-ModuleMember -Function Show-Error
Export-ModuleMember -Function Show-ErrorThrow
Export-ModuleMember -Function Show-CallStackThrowError
Export-ModuleMember -Function Show-WarningOrInfo
Export-ModuleMember -Function Show-ErrorOrInfo
Export-ModuleMember -Function Show-InfoOrMessage
Export-ModuleMember -Function Show-ErrorOrWarning
Export-ModuleMember -Function Show-WarningOrMessage
Export-ModuleMember -Function Show-ErrorOrMessage
Export-ModuleMember -Function Show-ErrorWarnInfoMessage
Export-ModuleMember -Function Show-ErrorWarnInfo
Export-ModuleMember -Function Save-TextToFileUtf8NoBOM
Export-ModuleMember -Function Save-FileToUtf8NoBOM
Export-ModuleMember -Function Save-OutputToFileUtf8NoBOM
Export-ModuleMember -Function Save-OutputAppendToFileUtf8NoBOM
Export-ModuleMember -Function Set-FileEndWithOneNewLine
Export-ModuleMember -Function Backup-ObjectToFile
Export-ModuleMember -Function Write-ObjectToFile
Export-ModuleMember -Function Compare-TextInPromptWindow
Export-ModuleMember -Function Get-QuotedArg
Export-ModuleMember -Function Join-CommandArgs
Export-ModuleMember -Function Show-ExceptionDetails
Export-ModuleMember -Function Show-Exception
Export-ModuleMember -Function Show-ExceptionThrow
Export-ModuleMember -Function Trace-PathOccupation
Export-ModuleMember -Function Invoke-CommandLine
Export-ModuleMember -Function Invoke-CommandLineDirectly
Export-ModuleMember -Function Install-AppByNames
Export-ModuleMember -Function Get-OutputFilePath
Export-ModuleMember -Function Get-BytesFromSizeUnit
Export-ModuleMember -Function Get-SizeAndUnit
Export-ModuleMember -Function Copy-FilesFromMachine
Export-ModuleMember -Function Get-HtmlLinkText
Export-ModuleMember -Function Complete-MailAddress
Export-ModuleMember -Function Send-MailByUser
Export-ModuleMember -Function Expand-MatchedText
Export-ModuleMember -Function Get-TextMd5Hash
Export-ModuleMember -Function Test-InstallApp
Export-ModuleMember -Function Start-CommandAsync
Export-ModuleMember -Function Get-CallArgsForPsBatch
Export-ModuleMember -Function Get-ProcessByFilter
Export-ModuleMember -Function Stop-ProcessByFilter
Export-ModuleMember -Function Get-AddableMsrArgs
Export-ModuleMember -Function New-BeginEndLogger
