
Import-Module "$PSScriptRoot/BasicOsUtils.psm1"
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding

# [CredentialProvider]DeviceFlow: https://ossmsft.pkgs.visualstudio.com/_packaging/OSS_All/nuget/v3/index.json
# [CredentialProvider]ATTENTION: User interaction required.
# To sign in, use a web browser to open the page https://microsoft.com/devicelogin and enter the code A4EJQLSE5 to authenticate.
$IsInCompanyDomains = $SysDnsDomain -imatch "CORP.MICROSOFT.COM"
$IsAdmin = if ($IsWindowsOS) {
    $securityPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $securityPrincipal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}
else {
    $(whoami) -eq "root"
}

$LocalAppInsightsEnvName = "LocalBoxAppInsightsConnection"
$_LogClient = $null

$thisToolRepoInfo = New-GitRepoInfo $PSScriptRoot
$invokingStack = Get-PSCallStack | Where-Object { $_.Command -imatch '^\w+' } | Select-Object -Last 1
$Global:CommonMetricsProperties = @{
    "User"               = $SysUserName
    "Domain"             = "$($SysDomainName)".ToLower()
    "Host"               = "$($SysHostName)".ToLower()
    "IsAdmin"            = $IsAdmin
    "ToolBranch"         = $thisToolRepoInfo.BranchName
    "ToolCommit"         = $thisToolRepoInfo.CommitId
    "ToolGitTime"        = $thisToolRepoInfo.CommitTime
    "ToolRepoName"       = $thisToolRepoInfo.RepoName
    "IsInCompanyDomains" = $IsInCompanyDomains
    "Command"            = if (-not $invokingStack) { '' } else { $invokingStack.Command }
    "InvokeTime"         = [DateTimeOffset]::Now.ToString('o')
}

function Init_AppInsightComponent {
    # Powershell way need confirmation + Administrator privilege
    # if (-not $(Get-InstalledModule -Name Az.ApplicationInsights -ErrorAction SilentlyContinue)) {
    #     Install-Module -Name Az.ApplicationInsights -Confirm:$false -Force -AllowClobber
    # }

    az extension list | msr -t "`"application-insights`"" >$null
    if ($LASTEXITCODE -ne 1) {
        msr -XM -z "az extension add -n application-insights"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install application-insights."
        }
    }
}

function Get-MetricsPropertyKey($KeyName) {
    # return [Char]::ToLower($KeyName[0]) + $KeyName.Substring(1)
    return $KeyName
}

# Installing nuget on MacOS is very slow.
function Install-Nuget {
    if ($IsWindowsOS) {
        Install-ToolByUrlIfNotFound "nuget" "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe"
    }
    else {
        $nugetPath = which nuget
        if ([string]::IsNullOrEmpty($nugetPath)) {
            msr -XM -z "$($SudoInstallCmd) nuget"
        }
    }
}

function Install_AppInsightPackageAndLoadDLL {
    $packageFolder = Join-Path $TmpToolPackageFolder "AppInsights"
    $dllFolder = Join-Path $packageFolder "DLLs"
    Test-CreateDirectory $dllFolder
    if (-not $IsWindowsOS) {
        $dllPath = msr -rp $dllFolder -l -f "Microsoft.ApplicationInsights.dll" -d "net\d+" -W -PAC -T 1
        if ([string]::IsNullOrEmpty($dllPath)) {
            $url = 'https://www.nuget.org/packages/Microsoft.ApplicationInsights/'
            $packageUrl = curl --silent --show-error --fail $url | msr -c -it "^.*? href=\`"(.+?)\`".*?Download.*package.*" -o "\1" -PAC
            if ([string]::IsNullOrEmpty($packageUrl)) {
                Write-Error "Failed to get ApplicationInsights package URL from $($url)"
            }
            $downloadUrl = curl --silent --show-error --fail $packageUrl | msr -it "^.*? href=\`"(.+?\.nupkg)\`".*" -o "\1" -PAC
            $downloadFileName = [IO.Path]::GetFileName($downloadUrl)
            $savePackagePath = Join-Path $packageFolder $downloadFileName
            curl --silent --show-error --fail $downloadUrl -o $savePackagePath
            # 7z x $savePackagePath -o$dllFolder
            tar xf $savePackagePath -C $dllFolder
            $dllPath = msr -rp $dllFolder -l -f "Microsoft.ApplicationInsights.dll" -d "net\d+" -W -PAC -T 1
        }
        if (-not [string]::IsNullOrEmpty($dllPath)) {
            if (-not [Reflection.Assembly]::LoadFile($dllPath)) {
                throw "Failed to load dll: $($dllPath) : Return = $? , LASTEXITCODE = $($LASTEXITCODE)"
            }
        }
        return
    }

    Install-Nuget
    # TODO for Linux
    $packageName = 'Microsoft.ApplicationInsights.WorkerService'
    $dllName = $packageName + ".dll"
    $sourceDllPath = msr -rp $packageFolder -f "^$($dllName)$" -l -k 4 -d "^net\w*\d+" -T 1 -PAC 2>$null
    if (-not [IO.File]::Exists($sourceDllPath)) {
        [console]::Error.WriteLine("Will download AppInsights package + Extract + Load DLLs in $($packageFolder)")
        msr -XM -z "nuget.exe install $($packageName) -Source https://www.nuget.org/api/v2 -OutputDirectory $($packageFolder)"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install nuget."
        }
        $sourceDllPath = msr -rp $packageFolder -f "^$($dllName)$" -l -k 4 -d "^net\w*\d+" -T 1 -PAC 2>$null
    }

    # Roughly extract DLLs into one folder to enable loading dependencies.
    $dllPattern = "^Microsoft.ApplicationInsights(.WorkerService)?.dll$"
    $dllPaths = msr -rp $dllFolder -f $dllPattern -l -PAC 2>$null
    if (-not $dllPaths) {
        $folderNameMustHas = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($sourceDllPath))
        $folderPattern = '^' + $folderNameMustHas + '$'
        $pathPattern = '\\lib\\' + $folderNameMustHas + '\\'
        $dllFolder2Slashes = $dllFolder.Replace('\', '\\')
        msr -rp $packageFolder -f "\.dll$" -l -d $folderPattern --pp $pathPattern -PAC | msr -t "(.+)" -o "copy /y \1 $dllFolder2Slashes\\" -X -M -I -V ne0
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract DLLs to $($dllFolder)"
        }

        $dllPaths = msr -rp $dllFolder -f $dllPattern -l -PAC 2>$null
    }

    if ($dllPaths.Count -lt 1) {
        throw "Failed to find DLLs: msr -l -rp $($dllFolder) -f `"$($dllPattern)`""
    }

    foreach ($dllPath in $dllPaths) {
        if (-not [Reflection.Assembly]::LoadFile($dllPath)) {
            throw "Failed to load dll: $($dllPath) : Return = $? , LASTEXITCODE = $($LASTEXITCODE)"
        }
    }
}

function ConvertTo_Dictionary {
    param (
        $Map = @{},
        $ValueType = 'string'
    )

    $dictionary = New-Object "System.Collections.Generic.Dictionary[[string],[$($ValueType)]]"
    foreach ($key in $Map.Keys) {
        $dictionary[$(Get-MetricsPropertyKey $key)] = $Map[$key]
    }

    return $dictionary
}

function Add_CommonProperties {
    param (
        $PropertiesMap = @{}
    )

    $Map = ConvertTo_Dictionary $PropertiesMap
    $Map[$(Get-MetricsPropertyKey "TimeUtc")] = [DateTimeOffset]::UtcNow.ToString('o')
    foreach ($key in $Global:CommonMetricsProperties.Keys) {
        $Map[$(Get-MetricsPropertyKey $key)] = $Global:CommonMetricsProperties[$key]
    }

    return $Map
}

function Write-AppEvent {
    param (
        [Parameter(Mandatory = $true)][string] $EventName,
        $PropertiesMap = @{}, # IDictionary<string, string>
        $MetricsMap = @{}, # IDictionary<string, double>
        [System.DateTimeOffset] $BeginTime = [System.DateTimeOffset]::MinValue
    )

    if (-not $_LogClient) {
        return
    }

    $PropertiesMap = Add_CommonProperties $PropertiesMap
    if ($BeginTime -ne [DateTimeOffset]::MinValue) {
        $cost = [DateTimeOffset]::Now - $BeginTime
        $PropertiesMap['TimeCost'] = $cost.ToString()
        $PropertiesMap['TimeCostSeconds'] = $cost.TotalSeconds
    }

    $_LogClient.TrackEvent($EventName, $PropertiesMap, $(ConvertTo_Dictionary $MetricsMap 'double'))
    $_LogClient.Flush()

    # TODO: duplicate message due to not found event table currently, skip in future.
    $action = if ($PropertiesMap -and $PropertiesMap.ContainsKey("Action")) { $PropertiesMap["Action"] } else { "" }
    Write-AppInfo "$($EventName) $($action)".Trim() $PropertiesMap
}

function Write-AppMessage {
    param (
        [Parameter(Mandatory = $true)][string] $Message,
        $PropertiesMap = @{},
        $Level = $null
    )

    if (-not $_LogClient) {
        return
    }

    if (-not $Level) {
        $Level = [Microsoft.ApplicationInsights.DataContracts.SeverityLevel]::Verbose
    }
    $PropertiesMap = Add_CommonProperties $PropertiesMap
    $_LogClient.TrackTrace($Message, $Level, $PropertiesMap)
    $_LogClient.Flush()
}

function Write-AppInfo {
    param (
        [Parameter(Mandatory = $true)][string] $Message,
        $PropertiesMap = @{}
    )

    if (-not $_LogClient) {
        return
    }
    $level = [Microsoft.ApplicationInsights.DataContracts.SeverityLevel]::Information
    Write-AppMessage $Message $PropertiesMap $level
}

function Write-AppWarning {
    param (
        [Parameter(Mandatory = $true)][string] $Message,
        $PropertiesMap = @{}
    )

    if (-not $_LogClient) {
        return
    }
    $level = [Microsoft.ApplicationInsights.DataContracts.SeverityLevel]::Warning
    Write-AppMessage $Message $PropertiesMap $level
}

function Write-AppError {
    param (
        [Parameter(Mandatory = $true)] $MessageOrException,
        $PropertiesMap = @{} # IDictionary<string, string>
    )

    if (-not $_LogClient) {
        return
    }

    if ($MessageOrException -is [System.Exception]) {
        Write-AppException $MessageOrException -PropertiesMap $PropertiesMap
        return
    }

    $level = [Microsoft.ApplicationInsights.DataContracts.SeverityLevel]::Error
    Write-AppMessage $MessageOrException $PropertiesMap $level
}

function Write-AppException {
    param (
        [Parameter(Mandatory = $true)][System.Exception] $Exception,
        $PropertiesMap = @{}, # IDictionary<string, string>
        $MetricsMap = @{} # IDictionary<string, double>
    )

    if (-not $_LogClient) {
        return
    }

    $PropertiesMap = Add_CommonProperties $PropertiesMap
    $_LogClient.TrackException($Exception, $PropertiesMap, $(ConvertTo_Dictionary $MetricsMap 'double'))
    $_LogClient.Flush()
}

if (-not $_LogClient) {
    $logKey = [System.Environment]::GetEnvironmentVariable($LocalAppInsightsEnvName)
    if ([string]::IsNullOrWhiteSpace($logKey)) {
        # Write-Warning "Not found environment variable: $($LocalAppInsightsEnvName)"
    }
    else {
        Install_AppInsightPackageAndLoadDLL
        $_LogClient = New-Object Microsoft.ApplicationInsights.TelemetryClient
        if (-not $_LogClient) {
            Write-Warning "Failed to initialize ApplicationInsights.TelemetryClient."
        }
        else {
            $_LogClient.InstrumentationKey = $logKey
        }
    }
}

# Auto generated exports by Update-PowerShell-Module-Exports.ps1
Export-ModuleMember -Variable IsInCompanyDomains
Export-ModuleMember -Variable IsAdmin
Export-ModuleMember -Variable LocalAppInsightsEnvName
Export-ModuleMember -Function Install-Nuget
Export-ModuleMember -Function Write-AppEvent
Export-ModuleMember -Function Write-AppMessage
Export-ModuleMember -Function Write-AppInfo
Export-ModuleMember -Function Write-AppWarning
Export-ModuleMember -Function Write-AppError
Export-ModuleMember -Function Write-AppException
