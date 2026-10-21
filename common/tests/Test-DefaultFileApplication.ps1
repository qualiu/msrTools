#requires -Version 7.0
[CmdletBinding()]
param([switch] $Live)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Set-DefaultFileApplication.ps1'
$script:FileExtsRegistryRoot = 'Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts'
$script:UserChoiceExperience = $null
$parseTokens = $null
$parseErrors = $null
$sourceAst = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref] $parseTokens, [ref] $parseErrors)
if (@($parseErrors).Count -ne 0) {
    throw 'The source script contains syntax errors.'
}
$functionDefinitions = @($sourceAst.FindAll({
    param($syntaxNode)
    $syntaxNode -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false) | ForEach-Object { $_.Extent.Text })
$summary = [pscustomobject]@{ Passed = 0; Failed = 0 }

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Throws {
    param([scriptblock] $Action, [string] $Pattern)
    $failure = $null
    try {
        $null = & $Action
    } catch {
        $failure = $_.Exception.Message
    }
    Assert-True ($null -ne $failure -and $failure -match $Pattern) "Expected error matching '$Pattern'; received '$failure'."
}

function Invoke-Case {
    param([string] $Name, [scriptblock] $Body)
    try {
        & {
            foreach ($definition in $functionDefinitions) {
                . ([scriptblock]::Create($definition))
            }
            & $Body
        }
        $summary.Passed++
        Write-Output "PASS: $Name"
    } catch {
        $summary.Failed++
        Write-Warning "FAIL: $Name -- $($_.Exception.Message)"
    }
}

function Invoke-AssociationScenario {
    param(
        [switch] $Preview,
        [switch] $Existing,
        [switch] $SameChoice,
        [switch] $MissingChoice,
        [switch] $FailRegistration,
        [switch] $FailWrite,
        [switch] $FailRestore,
        [switch] $FailCleanup,
        [switch] $ProgIdOnly,
        [switch] $WrongEffectiveChoice,
        [switch] $MissingNotifications,
        [switch] $FailNotifications
    )
    foreach ($definition in $functionDefinitions) {
        . ([scriptblock]::Create($definition))
    }
    $registration = [pscustomobject]@{
        ProgId = 'msrTools.FileAssociation.' + ('a' * 64)
        Exists = [bool] $Existing
        Created = $false
    }
    $previous = [pscustomobject]@{
        KeyPresent = -not $MissingChoice
        ProgId = if ($SameChoice) { $registration.ProgId } else { 'Example.Previous' }
        HashValid = -not $MissingChoice
        Values = @([pscustomobject]@{ Name = 'ExampleFlag'; Value = 7; Kind = [Microsoft.Win32.RegistryValueKind]::DWord })
    }
    $simulation = [pscustomobject]@{
        Events = [Collections.Generic.List[string]]::new()
        RestoredState = $null
        ForwardedValues = @()
        Result = $null
        Error = $null
        Registration = $registration
    }
    $notifications = [pscustomobject]@{ Values = @(if ($MissingNotifications) { [pscustomobject]@{ Applied = $false } }); Attempted = $false }
    function Get-AssociationNotificationRegistration { param($FileExtension, $TargetProgId) return $notifications }
    function Set-AssociationNotificationRegistration {
        param($Registration)
        $simulation.Events.Add('set-notifications')
        $Registration.Attempted = $true
        $Registration.Values[0].Applied = $true
        if ($FailNotifications) { throw 'Synthetic notification failure' }
    }
    function Restore-AssociationNotificationRegistration {
        param($Registration)
        if ($Registration.Attempted) { $simulation.Events.Add('restore-notifications') }
    }
    function Assert-ClassicUserChoiceSupported { param($FileExtension) }
    function Get-ProgIdOpenCommand { param($TargetProgId) 'synthetic open command' }
    function Get-ApplicationRegistration {
        param($TargetApplicationPath, $TargetApplicationArguments)
        $simulation.Events.Add('plan')
        return $simulation.Registration
    }
    function Get-UserChoiceState {
        param($FileExtension)
        $simulation.Events.Add('snapshot')
        return $previous
    }
    function Get-EffectiveFileAssociation {
        param($FileExtension)
        $target = if ($ProgIdOnly) { 'Example.New' } else { $registration.ProgId }
        $resolved = if ($WrongEffectiveChoice) { 'Example.Rejected' } elseif ($simulation.Events.Contains('write')) { $target } else { $previous.ProgId }
        return [pscustomobject]@{ ProgId = $resolved; Executable = 'C:\ExampleApps\viewer.exe' }
    }
    function Register-ApplicationProgId {
        param($Registration)
        $simulation.Events.Add('register')
        $Registration.Created = $true
        if ($FailRegistration) { throw 'Synthetic registration failure' }
    }
    function Set-UserChoiceValue {
        param($FileExtension, $TargetProgId, $AdditionalValues)
        $simulation.Events.Add('write')
        $simulation.ForwardedValues = @($AdditionalValues)
        if ($FailWrite) { throw 'Synthetic choice failure' }
        return [pscustomobject]@{ ProgId = $TargetProgId; HashValid = $true }
    }
    function Restore-UserChoiceState {
        param($FileExtension, $State)
        $simulation.Events.Add('restore-choice')
        $simulation.RestoredState = $State
        if ($FailRestore) { throw 'Synthetic restore failure' }
    }
    function Remove-ApplicationRegistration {
        param($Registration)
        $simulation.Events.Add('remove-registration')
        if ($FailCleanup) { throw 'Synthetic cleanup failure' }
        $Registration.Created = $false
    }
    function Send-AssociationChangeNotification { $simulation.Events.Add('notify') }
    $parameters = @{ FileExtension = '.xml'; WhatIf = [bool] $Preview; Confirm = $false }
    if ($ProgIdOnly) {
        $parameters.TargetProgId = 'Example.New'
    } else {
        $parameters.TargetApplicationPath = 'C:\ExampleApps\viewer.exe'
    }
    try {
        $simulation.Result = Set-FileAssociation @parameters
    } catch {
        $simulation.Error = $_.Exception.Message
    }
    return $simulation
}

Invoke-Case 'Comma lists and arrays normalize and deduplicate' {
    $extensions = @(ConvertTo-FileExtensions -Extensions @(' MD,.html', 'xml', '.MD'))
    Assert-True (($extensions -join ',') -ceq '.md,.html,.xml') 'Extension normalization failed.'
}

Invoke-Case 'Invalid comma-list entries fail before emitting any extensions' {
    $emitted = [Collections.Generic.List[string]]::new()
    Assert-Throws { ConvertTo-FileExtensions -Extensions 'md,../invalid' | ForEach-Object { $emitted.Add($_) } } 'Invalid file extension'
    Assert-True ($emitted.Count -eq 0) 'A partial extension list escaped validation.'
    Assert-Throws { ConvertTo-FileExtensions -Extensions 'md,' } 'Invalid file extension'
}

Invoke-Case 'Same executable names and different arguments receive distinct ProgIDs' {
    function Get-Item {
        param($LiteralPath)
        [pscustomobject]@{ FullName = $LiteralPath; PSIsContainer = $false; PSProvider = [pscustomobject]@{ Name = 'FileSystem' } }
    }
    $first = Get-ApplicationRegistration -TargetApplicationPath 'C:\ExampleApps\Alpha\viewer.exe' -TargetApplicationArguments '"%1"'
    $second = Get-ApplicationRegistration -TargetApplicationPath 'C:\ExampleApps\Beta\viewer.exe' -TargetApplicationArguments '"%1"'
    $differentArguments = Get-ApplicationRegistration -TargetApplicationPath 'C:\ExampleApps\Alpha\viewer.exe' -TargetApplicationArguments '--new-window "%1"'
    $repeated = Get-ApplicationRegistration -TargetApplicationPath 'C:\ExampleApps\Alpha\viewer.exe' -TargetApplicationArguments '"%1"'
    Assert-True ($first.ProgId -cne $second.ProgId) 'Different paths share a ProgID.'
    Assert-True ($first.ProgId -cne $differentArguments.ProgId) 'Different arguments share a ProgID.'
    Assert-True ($first.ProgId -ceq $repeated.ProgId) 'Registration identity is not stable.'
    Assert-True ($first.ProgId -cmatch '^msrTools\.FileAssociation\.[0-9a-f]{64}$') 'Registration escaped its private namespace.'
}

Invoke-Case 'An executable-named directory is rejected' {
    function Get-Item {
        param($LiteralPath)
        [pscustomobject]@{ FullName = $LiteralPath; PSIsContainer = $true; PSProvider = [pscustomobject]@{ Name = 'FileSystem' } }
    }
    Assert-Throws { Get-ApplicationRegistration -TargetApplicationPath 'C:\ExampleApps\directory.exe' -TargetApplicationArguments '"%1"' } 'executable file'
}

Invoke-Case 'Cleanup refuses registrations outside the dedicated namespace' {
    $foreignRegistration = [pscustomobject]@{ Created = $true; RelativePath = 'Software\Classes\Applications\viewer.exe' }
    Assert-Throws { Remove-ApplicationRegistration -Registration $foreignRegistration } 'outside the dedicated namespace'
}

Invoke-Case 'WhatIf does not register an application or change UserChoice' {
    $outcome = Invoke-AssociationScenario -Preview
    Assert-True ($null -eq $outcome.Error) "Unexpected error: $($outcome.Error)"
    Assert-True (($outcome.Events -join ',') -ceq 'plan,snapshot') 'WhatIf performed a write.'
    Assert-True (-not $outcome.Result.Changed) 'WhatIf reported an applied change.'
}

Invoke-Case 'A fully configured association is a genuine no-op' {
    $outcome = Invoke-AssociationScenario -Existing -SameChoice
    Assert-True ($null -eq $outcome.Error) "Unexpected error: $($outcome.Error)"
    Assert-True (($outcome.Events -join ',') -ceq 'plan,snapshot') 'A no-op performed a write.'
    Assert-True (-not $outcome.Result.Changed) 'A no-op reported a change.'
    Assert-True $outcome.Result.WindowsVerified 'A no-op did not verify Windows association resolution.'
}

Invoke-Case 'A matching hash cannot hide Windows rejecting the association' {
    $outcome = Invoke-AssociationScenario -Existing -SameChoice -WrongEffectiveChoice
    Assert-True ($outcome.Error -match 'Windows did not accept') 'A locally valid hash was mistaken for an effective Windows association.'
    Assert-True (($outcome.Events -join ',') -ceq 'plan,snapshot,write,notify,restore-choice,notify') 'An ineffective association skipped repair, rollback or notification.'
}

Invoke-Case 'Missing notification state is repaired even when Shell resolution and hash already match' {
    $outcome = Invoke-AssociationScenario -Existing -SameChoice -MissingNotifications
    Assert-True ($null -eq $outcome.Error -and $outcome.Result.NotificationsConfigured -and $outcome.Result.Changed) 'Notification repair was skipped.'
    Assert-True (($outcome.Events -join ',') -ceq 'plan,snapshot,set-notifications,write,notify') 'Notification repair ordering is incorrect.'
    $preview = Invoke-AssociationScenario -Existing -SameChoice -MissingNotifications -Preview
    Assert-True (($preview.Events -join ',') -ceq 'plan,snapshot' -and -not $preview.Result.NotificationsConfigured) 'Preview changed notification state.'
}

Invoke-Case 'Notification failure restores partial state before cleaning the new application' {
    $outcome = Invoke-AssociationScenario -MissingNotifications -FailNotifications
    Assert-True ($outcome.Error -match 'previous state was restored.*Synthetic notification failure') 'Notification failure was lost.'
    Assert-True (($outcome.Events -join ',') -ceq 'plan,snapshot,register,set-notifications,restore-notifications,remove-registration') 'Partial notification rollback is incorrect.'
    $outcome = Invoke-AssociationScenario -MissingNotifications -FailWrite
    Assert-True (($outcome.Events -join ',') -ceq 'plan,snapshot,register,set-notifications,write,restore-choice,restore-notifications,remove-registration') 'Rollback ordering is incorrect.'
}

Invoke-Case 'Missing registration is repaired even when UserChoice already matches' {
    $outcome = Invoke-AssociationScenario -SameChoice
    Assert-True ($null -eq $outcome.Error -and $outcome.Result.Changed) 'A missing registration was skipped.'
    Assert-True (($outcome.Events -join ',') -ceq 'plan,snapshot,register,write,notify') 'Write ordering is incorrect.'
    Assert-True ($outcome.ForwardedValues[0].Value -eq 7) 'Additional UserChoice values were not preserved.'
}

Invoke-Case 'Choice failure restores the snapshot and removes new registration' {
    $outcome = Invoke-AssociationScenario -FailWrite
    Assert-True ($outcome.Error -match 'previous state was restored.*Synthetic choice failure') 'The original failure was lost.'
    Assert-True (($outcome.Events -join ',') -ceq 'plan,snapshot,register,write,restore-choice,remove-registration') 'Rollback ordering is incorrect.'
    Assert-True (-not $outcome.Registration.Created) 'New application registration was retained.'
}

Invoke-Case 'Selecting an existing private registration does not rewrite it' {
    $outcome = Invoke-AssociationScenario -Existing
    Assert-True ($null -eq $outcome.Error -and $outcome.Result.Changed) 'Selecting an existing registration failed.'
    Assert-True (($outcome.Events -join ',') -ceq 'plan,snapshot,write,notify') 'Existing registration was rewritten.'
}

Invoke-Case 'Choice failure preserves a pre-existing application registration' {
    $outcome = Invoke-AssociationScenario -Existing -FailWrite
    Assert-True ($outcome.Error -match 'previous state was restored.*Synthetic choice failure') 'The original failure was lost.'
    Assert-True (($outcome.Events -join ',') -ceq 'plan,snapshot,write,restore-choice') 'A pre-existing registration was removed.'
}

Invoke-Case 'An originally absent UserChoice is restored as absent' {
    $outcome = Invoke-AssociationScenario -MissingChoice -FailWrite
    Assert-True ($null -ne $outcome.Error -and -not $outcome.RestoredState.KeyPresent) 'The absent-key snapshot was lost.'
}

Invoke-Case 'Partial registration failure cleans up without touching UserChoice' {
    $outcome = Invoke-AssociationScenario -FailRegistration
    Assert-True ($outcome.Error -match 'Synthetic registration failure') 'The registration failure was lost.'
    Assert-True (($outcome.Events -join ',') -ceq 'plan,snapshot,register,remove-registration') 'Partial registration cleanup is incorrect.'
}

Invoke-Case 'Choice restore failure still attempts application cleanup' {
    $outcome = Invoke-AssociationScenario -FailWrite -FailRestore
    Assert-True ($outcome.Error -match 'Synthetic choice failure.*Synthetic restore failure') 'Restore failure details were lost.'
    Assert-True (-not $outcome.Registration.Created) 'Application cleanup was skipped after restore failure.'
}

Invoke-Case 'Application cleanup failure is not reported as successful recovery' {
    $outcome = Invoke-AssociationScenario -FailWrite -FailCleanup
    Assert-True ($outcome.Error -match 'Restore errors:.*Synthetic cleanup failure') 'Cleanup failure was concealed.'
    Assert-True ($outcome.Error -notmatch 'previous state was restored') 'Incomplete recovery was reported as success.'
}

Invoke-Case 'Existing ProgID mode does not register an application' {
    $outcome = Invoke-AssociationScenario -ProgIdOnly
    Assert-True ($null -eq $outcome.Error -and $outcome.Result.CurrentProgId -ceq 'Example.New') 'Existing ProgID mode failed.'
    Assert-True (($outcome.Events -join ',') -ceq 'snapshot,write,notify') 'Existing ProgID mode changed application registration.'
}

Invoke-Case 'Documented pwsh -File comma-list invocation succeeds without writes' {
    $nativeOutput = @(pwsh -NoProfile -File $sourcePath -Extension '.md,.html,.xml,.json,.txt,.log' -ProgId MSEdgeHTM -WhatIf 2>&1)
    $nativeExitCode = $LASTEXITCODE
    if ($nativeExitCode -ne 0) {
        $nativeOutput | Write-Output
    }
    Assert-True ($nativeExitCode -eq 0) "The documented command failed with exit code $nativeExitCode."
    foreach ($extension in @('.md', '.html', '.xml', '.json', '.txt', '.log')) {
        Assert-True (($nativeOutput -join "`n").Contains($extension)) "Missing result for $extension."
    }
}

Invoke-Case 'Real executable preview leaves its private registration unchanged' {
    $notepadPath = Join-Path $env:WINDIR 'System32/notepad.exe'
    $before = Get-ApplicationRegistration -TargetApplicationPath $notepadPath -TargetApplicationArguments '"%1"'
    $preview = & $sourcePath -Extension .txt -ApplicationPath $notepadPath -WhatIf
    $after = Get-ApplicationRegistration -TargetApplicationPath $notepadPath -TargetApplicationArguments '"%1"'
    Assert-True (-not $preview.Changed -and $before.Exists -eq $after.Exists) 'Application preview changed registration.'
}

if ($Live) {
    Invoke-Case 'Live competing applications, notification idempotency, and exact rollback' {
        $extension = '.msrtools-test-' + [guid]::NewGuid().ToString('N')
        $extensionPath = "Software\Classes\$extension"
        $toastPath = 'Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts'
        $targetName = "Example.New_$extension"
        $previousName = "Example.Previous_$extension"
        $unrelatedName = "Example.Unrelated_$extension"
        $toastKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($toastPath, $true)
        try {
            $competitors = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$extensionPath\OpenWithProgids", $true)
            try { $competitors.SetValue('Example.Previous', [byte[]]@(), [Microsoft.Win32.RegistryValueKind]::None) } finally { $competitors.Dispose() }
            $toastKey.SetValue($previousName, 1, [Microsoft.Win32.RegistryValueKind]::DWord)
            $plan = Get-AssociationNotificationRegistration -FileExtension $extension -TargetProgId 'Example.New'
            Assert-True ($plan.Values.Count -eq 2) 'The target or competing application was omitted.'
            Set-AssociationNotificationRegistration -Registration $plan
            Assert-True ($toastKey.GetValue($targetName) -eq 0 -and $toastKey.GetValue($previousName) -eq 0) 'Notification values were not configured.'
            $repeated = Get-AssociationNotificationRegistration -FileExtension $extension -TargetProgId 'Example.New'
            Assert-True ($repeated.Values.Count -eq 0) 'Configured notification state was not a no-op.'
            $toastKey.SetValue($unrelatedName, 'preserve', [Microsoft.Win32.RegistryValueKind]::String)
            Restore-AssociationNotificationRegistration -Registration $plan
            Assert-True ($toastKey.GetValueNames() -notcontains $targetName) 'Rollback retained a newly created value.'
            Assert-True ($toastKey.GetValue($previousName) -eq 1) 'Rollback lost the previous notification setting.'
            Assert-True ($toastKey.GetValue($unrelatedName) -ceq 'preserve') 'Rollback changed an unrelated value.'
            $plan = Get-AssociationNotificationRegistration -FileExtension $extension -TargetProgId 'Example.New'
            Set-AssociationNotificationRegistration -Registration $plan
            $toastKey.SetValue($targetName, 2, [Microsoft.Win32.RegistryValueKind]::DWord)
            Assert-Throws { Restore-AssociationNotificationRegistration -Registration $plan } 'changed during recovery'
            Assert-True ($toastKey.GetValue($targetName) -eq 2) 'Recovery overwrote a concurrent change.'
        } finally {
            foreach ($name in @($targetName, $previousName, $unrelatedName)) { $toastKey.DeleteValue($name, $false) }
            $toastKey.Dispose()
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$extensionPath\OpenWithProgids", $true)
            if ($null -ne $key) {
                try {
                    $key.DeleteValue('Example.Previous', $false)
                    Assert-True ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) 'Preserving unexpected synthetic registration data.'
                } finally { $key.Dispose() }
                [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey("$extensionPath\OpenWithProgids", $false)
                [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($extensionPath, $false)
            }
        }
    }

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class DefaultApplicationTestProbe
{
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
    private static extern int AssocQueryString(uint flags, uint kind, string extension,
        string extra, StringBuilder output, ref uint length);
    public static string GetExecutable(string extension)
    {
        uint length = 32768;
        var output = new StringBuilder((int)length);
        int result = AssocQueryString(0, 2, extension, null, output, ref length);
        if (result != 0) Marshal.ThrowExceptionForHR(result);
        return output.ToString();
    }
}
"@

    function Remove-LiveTestArtifacts {
        param([string] $Extension, $Registration)
        if ($Extension -cnotmatch '^\.msrtools-test-[0-9a-f]{32}$') {
            throw 'Refusing to clean an extension outside the synthetic test scope.'
        }
        try {
            $toastPath = 'Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts'
            $toastKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($toastPath, $true)
            if ($null -ne $toastKey) {
                try { $toastKey.DeleteValue("$($Registration.ProgId)_$Extension", $false) } finally { $toastKey.Dispose() }
            }
            $relativePath = "$script:FileExtsRegistryRoot\$Extension"
            [DefaultAppAssociation.NativeMethods]::DeleteCurrentUserKey("$relativePath\UserChoice")
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($relativePath)
            if ($null -ne $key) {
                try {
                    Assert-True ($key.SubKeyCount -eq 0 -and $key.ValueCount -eq 0) 'The test extension contains unexpected data; preserving it.'
                } finally {
                    $key.Dispose()
                }
                [DefaultAppAssociation.NativeMethods]::DeleteCurrentUserKey($relativePath)
            }
        } finally {
            if (-not $Registration.Exists) {
                $Registration.Created = $true
                Remove-ApplicationRegistration -Registration $Registration
            }
        }
    }

    Invoke-Case 'Live application registration, native resolution, idempotency, and metadata preservation' {
        $extension = '.msrtools-test-' + [guid]::NewGuid().ToString('N')
        $notepadPath = Join-Path $env:WINDIR 'System32/notepad.exe'
        $registration = Get-ApplicationRegistration -TargetApplicationPath $notepadPath -TargetApplicationArguments '"%1"'
        $sharedPath = 'Software\Classes\Applications\notepad.exe\shell\open\command'
        $sharedKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sharedPath)
        $sharedCommand = if ($null -ne $sharedKey) { $sharedKey.GetValue('') } else { $null }
        if ($null -ne $sharedKey) { $sharedKey.Dispose() }
        try {
            $setting = & $sourcePath -Extension $extension -ApplicationPath $notepadPath -Confirm:$false
            Assert-True ($setting.Changed -and $setting.HashValid -and $setting.CurrentProgId -ceq $registration.ProgId) 'Live application registration failed.'
            Assert-True ($setting.WindowsVerified -and $setting.EffectiveProgId -ceq $registration.ProgId) 'Native Windows association verification was not reported.'
            $effectiveExecutable = [DefaultApplicationTestProbe]::GetExecutable($extension)
            Assert-True ($effectiveExecutable -ieq $notepadPath) "Windows resolved '$extension' to '$effectiveExecutable' instead of '$notepadPath'."
            $repeated = & $sourcePath -Extension $extension -ApplicationPath $notepadPath -Confirm:$false
            Assert-True (-not $repeated.Changed -and $repeated.HashValid) 'Repeated application setup was not a no-op.'
            $choicePath = "$script:FileExtsRegistryRoot\$extension\UserChoice"
            $choiceKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($choicePath, $true)
            try {
                $choiceKey.SetValue('ExampleFlag', 7, [Microsoft.Win32.RegistryValueKind]::DWord)
            } finally {
                $choiceKey.Dispose()
            }
            $forced = & $sourcePath -Extension $extension -ApplicationPath $notepadPath -Force -Confirm:$false
            $choiceKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($choicePath)
            try {
                Assert-True ($forced.HashValid -and $choiceKey.GetValue('ExampleFlag') -eq 7) 'UserChoice metadata was lost during an update.'
            } finally {
                $choiceKey.Dispose()
            }
            $sharedKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sharedPath)
            try {
                $currentSharedCommand = if ($null -ne $sharedKey) { $sharedKey.GetValue('') } else { $null }
                Assert-True ($sharedCommand -ceq $currentSharedCommand) 'The shared Applications registration was modified.'
            } finally {
                if ($null -ne $sharedKey) { $sharedKey.Dispose() }
            }
        } finally {
            Remove-LiveTestArtifacts -Extension $extension -Registration $registration
        }
    }

    Invoke-Case 'Live failure injection removes the new application registration' {
        $extension = '.msrtools-test-' + [guid]::NewGuid().ToString('N')
        $notepadPath = Join-Path $env:WINDIR 'System32/notepad.exe'
        $arguments = '"%1" --synthetic-failure-' + [guid]::NewGuid().ToString('N')
        $registration = Get-ApplicationRegistration -TargetApplicationPath $notepadPath -TargetApplicationArguments $arguments
        Assert-True (-not $registration.Exists) 'The failure-injection registration unexpectedly exists.'
        function Set-UserChoiceValue {
            param($FileExtension, $TargetProgId, $AdditionalValues)
            throw 'Synthetic live choice failure'
        }
        try {
            Assert-Throws {
                Set-FileAssociation -FileExtension $extension -TargetApplicationPath $notepadPath -TargetApplicationArguments $arguments -Confirm:$false
            } 'previous state was restored.*Synthetic live choice failure'
            $remainingKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registration.RelativePath)
            try {
                Assert-True ($null -eq $remainingKey) 'Failure left the private application registration behind.'
            } finally {
                if ($null -ne $remainingKey) { $remainingKey.Dispose() }
            }
            $choice = Get-UserChoiceState -FileExtension $extension
            Assert-True (-not $choice.KeyPresent) 'Failure created an unwanted UserChoice.'
        } finally {
            Remove-LiveTestArtifacts -Extension $extension -Registration $registration
        }
    }
}

Write-Output ("RESULT " + ($summary | ConvertTo-Json -Compress))
if ($summary.Failed -ne 0) {
    throw "$($summary.Failed) file-association regression test(s) failed."
}
