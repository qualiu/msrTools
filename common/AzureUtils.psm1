Import-Module "$PSScriptRoot/BasicOsUtils.psm1"
Import-Module "$PSScriptRoot/LogUtils.psm1"
Import-Module "$PSScriptRoot/CommonUtils.psm1"

$ParseSubscriptionGroupRegex = New-Object System.Text.RegularExpressions.Regex("^/?(?<Subscription>[^/]+)" + "/" + "(?<ResourceGroup>[^/]+)" + "/?")

# Solve Azure CLI color bug for all scripts.
[System.Console]::ResetColor()

$Script:LogToken = ""
$Script:LastGetTokenTime = [DateTime]::Now.AddDays(-1)
function Get-AzureAuthToken {
    param (
        [int] $refreshIntervalSeconds = 500
    )

    $elapse = $([DateTime]::Now - $Script:LastGetTokenTime).TotalSeconds
    if ($elapse -gt $refreshIntervalSeconds -or [string]::IsNullOrWhitespace($Script:LogToken)) {
        try {
            $Script:LogToken = $(az account get-access-token | ConvertFrom-Json).accessToken.ToString().Trim()
        }
        catch {
            Show-ExceptionThrow $_
        }

        $Script:LastGetTokenTime = [DateTime]::Now
        [Console]::ResetColor()
    }

    return $Script:LogToken
}

function Set-NoPromptingForAzureCli {
    param (
        [bool] $TipLogin = $true
    )

    $tip = "Azure-CLI must has been installed (run 'az login' if not login or expired)."
    if ($TipLogin) {
        Show-Message $tip
    }
    Test-ToolExistsThrowError "az" $tip
    Invoke-CommandLine "az config set extension.use_dynamic_install=yes_without_prompt" -NotWriteLog
}

function Get-KeyVaultSecret {
    param(
        [Parameter(Mandatory = $true)] [string] $KeyVaultName,
        [Parameter(Mandatory = $true)] [string] $SecretName,
        [string] $DefaultValue = '',
        [bool] $ShowInfo = $true
    )

    if ($ShowInfo) {
        Show-Message "Will fetch secret value of $($SecretName) from keyVault $($KeyVaultName)"
    }

    $result = (az keyvault secret show --vault-name $KeyVaultName -n $SecretName | ConvertFrom-Json).value
    if ([string]::IsNullOrEmpty($result)) {
        return $DefaultValue
    }
    else {
        return $result
    }
}

function Test-SetLocalAppInsightsValue {
    param (
        [string] $AppInsightsConnection,
        [bool] $ForceUpdate = $false
    )

    if ([string]::IsNullOrWhiteSpace($AppInsightsConnection)) {
        return
    }

    $currentValue = [System.Environment]::GetEnvironmentVariable($LocalAppInsightsEnvName)
    if ($ForceUpdate -or $([string]::IsNullOrWhiteSpace($currentValue))) {
        [System.Environment]::SetEnvironmentVariable($LocalAppInsightsEnvName, $AppInsightsConnection, [System.EnvironmentVariableTarget]::User)
    }
}

function Test-SetLocalAppInsightsValueFromKeyVault {
    param (
        [Parameter(Mandatory = $true)] [string] $KeyVaultName,
        [Parameter(Mandatory = $true)] [string] $SecretName,
        [bool] $SkipNonNullEnvValue = $true,
        [bool] $ForceUpdate = $false
    )

    if (-not $(Test-ToolExistsByName az)) {
        $command = if ($IsWindowsOS) { "where az" } else { "which az" }
        Show-Warning "Azure-CLI not found, checking by command: $($command)"
        return
    }

    $currentValue = [System.Environment]::GetEnvironmentVariable($LocalAppInsightsEnvName)
    if ($SkipNonNullEnvValue -and -not [string]::IsNullOrWhiteSpace($currentValue)) {
        return
    }

    $value = Get-KeyVaultSecret $KeyVaultName $SecretName
    Test-SetLocalAppInsightsValue $value $ForceUpdate
}

function Set-SecretsToEnvironmentVariables {
    param(
        [ref] [string[]] $NonNullSecretNames,
        [Parameter(Mandatory = $true)] [string] $SourceFile,
        [Parameter(Mandatory = $true)] [string] $KeyVaultName,
        [string] $SearchPattern = "^\s*\w+\S*\s*=\s*\$\{(\w+)\}",
        [bool] $SkipExistingEnvValues = $true
    )

    $secretNames = nin $SourceFile nul $SearchPattern -PAC -u
    if ([string]::IsNullOrEmpty($secretNames)) {
        return
    }

    Show-Info "Will fetch $($secretNames.Count) secrets in $($SourceFile) from key vault $($KeyVaultName)"
    msr -p $SourceFile -t $SearchPattern -M
    $failures = 0
    foreach ($secretName in $secretNames) {
        $existingValue = [Environment]::GetEnvironmentVariable($secretName)
        if (-not [string]::IsNullOrEmpty($existingValue)) {
            if ($SkipExistingEnvValues) {
                Show-MessageLog "Skip fetching/setting $($secretName) as found non-null environment value."
                $NonNullSecretNames.Value += $secretName
                continue
            }
        }

        $secretValue = Get-KeyVaultSecret $KeyVaultName $secretName
        if ([string]::IsNullOrEmpty($secretValue)) {
            $failures += 1
        }
        else {
            [Environment]::SetEnvironmentVariable($secretName, $secretValue)
            $NonNullSecretNames.Value += $secretName
        }
    }

    $setCount = $secretNames.Count - $failures
    # $foreColor = if ($failures -gt 0) { [System.ConsoleColor]::Yellow } else { [System.ConsoleColor]::Green }
    Show-ErrorOrInfo "Set $($setCount) secrets to environment variables with $($failures) failures, secrets in file $($SourceFile)" -IsError $($failures -gt 0)
    if ($failures -gt 0) {
        Show-Error "Please check if you have permission of $($KeyVaultName) or logged in Azure by 'az login'."
    }
}

function Get-AzureObjectName {
    param (
        $Resource
    )

    if ($Resource.tags) {
        $nameFromTag = $Resource.tags.'hidden-title'
        if (-not [string]::IsNullOrWhiteSpace($nameFromTag)) {
            return $nameFromTag
        }
    }


    if ($(-not [string]::IsNullOrWhiteSpace($Resource.name)) -and $($Resource.name -notmatch '^\w+-\w+-\w+-[\w-]+$')) {
        return $Resource.name
    }

    if ($Resource.properties -and $(-not [string]::IsNullOrWhiteSpace($Resource.properties.displayName))) {
        return $Resource.properties.displayName
    }

    return ''
}

function Test-IsValidRealObjectName {
    param (
        [string] $Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    if ($Name -match '^\w+-\w+-\w+-[\w-]+$') {
        return $false
    }

    return $true
}

function Test-ShouldSkipObjectByNameMatching {
    param(
        [string] $Name,
        [string] $MatchPattern,
        [string] $SkipPattern,
        [switch] $IgnoreCase
    )

    if (-not $(Test-IsValidRealObjectName $Name)) {
        return $false
    }

    $flag = if ($IgnoreCase) { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase } else { [System.Text.RegularExpressions.RegexOptions]::None }
    if (-not [string]::IsNullOrWhiteSpace($MatchPattern)) {
        if (-not [regex]::IsMatch($Name, $MatchPattern, $flag)) {
            return $true
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($SkipPattern)) {
        if ([regex]::IsMatch($Name, $SkipPattern, $flag)) {
            return $true
        }
    }

    return $false
}

function Test-ShouldSkipObjectByPropertyNames {
    param(
        [string[]] $Names,
        [string] $MatchPattern,
        [string] $SkipPattern,
        [switch] $IgnoreCase
    )

    foreach ($name in $Names) {
        if (Test-ShouldSkipObjectByNameMatching $name $MatchPattern $SkipPattern $IgnoreCase) {
            return $true
        }
    }

    return $false
}

function Get-AlertRuleByName {
    param(
        [Parameter(Mandatory = $true)] [string] $Subscription,
        [Parameter(Mandatory = $true)] [string] $ResourceGroup,
        [Parameter(Mandatory = $true)] [string] $Name,
        [string] $ResourceType = 'microsoft.insights/scheduledQueryRules'
    )

    $text = az resource show --subscription $Subscription --resource-group $ResourceGroup --name $Name --resource-type $ResourceType
    $obj = $text | ConvertFrom-Json
    return $obj
}


function Get-AlertRuleUrlById {
    param(
        [Parameter(Mandatory = $true)] $Id,
        [string] $Head = "https://ms.portal.azure.com/#blade/Microsoft_Azure_Monitoring/UpdateLogSearchV2AlertRuleViewModel/alertId/"
    )

    $url = $Head + [uri]::EscapeDataString($Id)
    return $url
}

function Get-AzureObjectUrl {
    param (
        [Parameter(Mandatory = $true)] $obj
    )

    # PowerShell-Bug: icontains bad case of id: /subscriptions/xxx/providers/microsoft.insights/workbooks/5718a2de-5047-41f1-8c6b-71a1abd8109d
    $url = if ($($obj.type -ieq 'microsoft.insights/scheduledQueryRules') -or $($obj.id -imatch '/microsoft.insights/scheduledQueryRules/')) {
        "https://ms.portal.azure.com/#blade/Microsoft_Azure_Monitoring/UpdateLogSearchV2AlertRuleViewModel/alertId/" + [uri]::EscapeDataString($obj.id)
    }
    elseif ($($obj.type -ieq 'microsoft.insights/workbooks') -or $($obj.id -imatch '/microsoft.insights/workbooks/')) {
        "https://ms.portal.azure.com/#blade/AppInsightsExtension/UsageNotebookBlade/ComponentId/" + [uri]::EscapeDataString($obj.properties.sourceId) `
            + "/ConfigurationId/" + [uri]::EscapeDataString($obj.id) + "/Type/workbook/WorkbookTemplateName/" + [Uri]::EscapeDataString($obj.properties.displayName)
    }
    else {
        Show-CallStackThrowError "Unsupported URL getting for type = $($obj.type) , id = $($obj.id)"
    }

    return $url
}

# Auto generated exports by Update-PowerShell-Module-Exports.ps1
Export-ModuleMember -Variable ParseSubscriptionGroupRegex
Export-ModuleMember -Function Get-AzureAuthToken
Export-ModuleMember -Function Set-NoPromptingForAzureCli
Export-ModuleMember -Function Get-KeyVaultSecret
Export-ModuleMember -Function Test-SetLocalAppInsightsValue
Export-ModuleMember -Function Test-SetLocalAppInsightsValueFromKeyVault
Export-ModuleMember -Function Set-SecretsToEnvironmentVariables
Export-ModuleMember -Function Get-AzureObjectName
Export-ModuleMember -Function Test-IsValidRealObjectName
Export-ModuleMember -Function Test-ShouldSkipObjectByNameMatching
Export-ModuleMember -Function Test-ShouldSkipObjectByPropertyNames
Export-ModuleMember -Function Get-AlertRuleByName
Export-ModuleMember -Function Get-AlertRuleUrlById
Export-ModuleMember -Function Get-AzureObjectUrl
