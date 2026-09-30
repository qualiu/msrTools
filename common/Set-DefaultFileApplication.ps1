#requires -Version 7.0
<#
MIT License

Copyright (c) 2022 Danysys

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
IN THE SOFTWARE.
#>

<#
.SYNOPSIS
Sets the current user's default application for one or more file extensions.

.DESCRIPTION
Associates file extensions with an existing Windows ProgID or an executable. The tool writes a valid, hash-protected UserChoice value used by Windows 10 and Windows 11,
verifies the live registry timestamp and hash, and notifies Windows Explorer without restarting it.

Use direct parameters for one or more extensions, or ConfigPath for a JSON file containing multiple mappings. Changes apply only to the current user.

.PARAMETER Extension
One or more file extensions to associate, with or without a leading period. Comma-separated lists are also accepted when using pwsh -File.

.PARAMETER ProgId
Existing Windows ProgID, such as MSEdgeHTM.

.PARAMETER ApplicationPath
Path to an executable file. A dedicated per-user ProgID is derived from its full path and arguments without overwriting shared Applications registrations.

.PARAMETER ApplicationArguments
Arguments appended to ApplicationPath. The default passes the selected file as "%1".

.PARAMETER ConfigPath
Path to a JSON file containing an associations array. Each entry accepts extensions and exactly one of progId or applicationPath.

.PARAMETER Force
Rewrites an association even when its current ProgID and UserChoice hash are already valid.

.EXAMPLE
pwsh -NoProfile -File Set-DefaultFileApplication.ps1 -Extension .md,.json -ProgId MSEdgeHTM

Sets Markdown and JSON files to open with Microsoft Edge.

.EXAMPLE
pwsh -NoProfile -File Set-DefaultFileApplication.ps1 -Extension .log -ApplicationPath C:/Windows/System32/notepad.exe

Registers Notepad for .log files and makes it the current user's default.

.EXAMPLE
pwsh -NoProfile -File Set-DefaultFileApplication.ps1 -ConfigPath ./DefaultFileApplications.json

Applies all file-to-application mappings in the JSON configuration file.

.EXAMPLE
pwsh -NoProfile -File Set-DefaultFileApplication.ps1 -Extension .md -ProgId MSEdgeHTM -WhatIf

Previews a mapping without changing the registry.

.NOTES
The classic UserChoice hash implementation is derived from PS-SFTA 1.2.0 and cross-checked against Mozilla's WindowsUserChoice implementation.
Windows installations using the newer UserChoiceLatest mechanism are detected and left unchanged because that mechanism uses a machine-specific hash.
Application registration and UserChoice changes share one confirmation and are restored if the operation fails.
Run tests/Test-DefaultFileApplication.ps1 for isolated regression checks; add -Live to validate temporary registry associations that are cleaned up afterward.
#>

[CmdletBinding(DefaultParameterSetName = 'ProgId', SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'ProgId')]
    [Parameter(Mandatory = $true, ParameterSetName = 'Application')]
    [ValidateNotNullOrEmpty()]
    [string[]] $Extension,

    [Parameter(Mandatory = $true, ParameterSetName = 'ProgId')]
    [string] $ProgId,

    [Parameter(Mandatory = $true, ParameterSetName = 'Application')]
    [string] $ApplicationPath,

    [Parameter(ParameterSetName = 'Application')]
    [string] $ApplicationArguments = '"%1"',

    [Parameter(Mandatory = $true, ParameterSetName = 'Config')]
    [string] $ConfigPath,

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'This tool supports Windows only.'
}

if (-not ('DefaultAppAssociation.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace DefaultAppAssociation
{
    public static class NativeMethods
    {
        private static readonly UIntPtr HkeyCurrentUser = new UIntPtr(0x80000001u);
        private const int KeyRead = 0x20019;
        private const int ErrorFileNotFound = 2;

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        private static extern int RegDeleteKey(UIntPtr hKey, string subKey);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        private static extern int RegOpenKeyEx(
            UIntPtr hKey,
            string subKey,
            int options,
            int desiredAccess,
            out IntPtr result);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        private static extern int RegQueryInfoKey(
            IntPtr hKey,
            IntPtr keyClass,
            IntPtr classLength,
            IntPtr reserved,
            IntPtr subKeyCount,
            IntPtr maximumSubKeyLength,
            IntPtr maximumClassLength,
            IntPtr valueCount,
            IntPtr maximumValueNameLength,
            IntPtr maximumValueLength,
            IntPtr securityDescriptorLength,
            out long lastWriteFileTime);

        [DllImport("advapi32.dll")]
        private static extern int RegCloseKey(IntPtr hKey);

        [DllImport("shell32.dll")]
        private static extern void SHChangeNotify(uint eventId, uint flags, IntPtr item1, IntPtr item2);

        public static void DeleteCurrentUserKey(string subKey)
        {
            int error = RegDeleteKey(HkeyCurrentUser, subKey);
            if (error != 0 && error != ErrorFileNotFound)
            {
                throw new Win32Exception(error, "Could not delete HKCU\\" + subKey);
            }
        }

        public static long GetCurrentUserKeyLastWriteFileTime(string subKey)
        {
            IntPtr key;
            int error = RegOpenKeyEx(HkeyCurrentUser, subKey, 0, KeyRead, out key);
            if (error != 0)
            {
                throw new Win32Exception(error, "Could not open HKCU\\" + subKey);
            }

            try
            {
                long fileTime;
                error = RegQueryInfoKey(
                    key,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    out fileTime);
                if (error != 0)
                {
                    throw new Win32Exception(error, "Could not query HKCU\\" + subKey);
                }

                return fileTime;
            }
            finally
            {
                RegCloseKey(key);
            }
        }

        public static void NotifyAssociationChanged()
        {
            const uint associationChanged = 0x08000000;
            const uint flush = 0x00001000;
            SHChangeNotify(associationChanged, flush, IntPtr.Zero, IntPtr.Zero);
        }
    }
}
'@
}

$script:UserChoiceExperience = $null
$script:FileExtsRegistryRoot = 'Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts'

function Convert-ToInt32 {
    param(
        [Parameter(Mandatory = $true)]
        [long] $Value
    )

    [byte[]] $bytes = [BitConverter]::GetBytes($Value)
    return [BitConverter]::ToInt32($bytes, 0)
}

function Get-ShiftRight {
    param(
        [Parameter(Mandatory = $true)]
        [long] $Value,

        [Parameter(Mandatory = $true)]
        [int] $Count
    )

    if ($Value -band 0x80000000) {
        return (($Value -shr $Count) -bxor 0xFFFF0000)
    }
    return ($Value -shr $Count)
}

function Get-Long {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]] $Bytes,

        [int] $Index = 0
    )

    return [BitConverter]::ToInt32($Bytes, $Index)
}

function Get-UserChoiceHash {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BaseInfo
    )

    [byte[]] $bytesBaseInfo = [Text.Encoding]::Unicode.GetBytes($BaseInfo)
    $bytesBaseInfo += [byte] 0, [byte] 0

    $md5 = [Security.Cryptography.MD5]::Create()
    try {
        [byte[]] $bytesMd5 = $md5.ComputeHash($bytesBaseInfo)
    } finally {
        $md5.Dispose()
    }

    $lengthBase = ($BaseInfo.Length * 2) + 2
    $length = (($lengthBase -band 4) -le 1) + (Get-ShiftRight -Value $lengthBase -Count 2) - 1
    if ($length -le 1) {
        throw 'UserChoice hash input is unexpectedly short.'
    }

    $cache = 0L
    $outHash1 = 0L
    $outHash2 = 0L
    $dataIndex = 0
    $md51 = [long] ((Get-Long -Bytes $bytesMd5) -bor 1) + 0x69FB0000L
    $md52 = [long] ((Get-Long -Bytes $bytesMd5 -Index 4) -bor 1) + 0x13DB0000L
    $index = Get-ShiftRight -Value ($length - 2) -Count 1
    $counter = $index + 1

    while ($counter) {
        $r0 = Convert-ToInt32 -Value ((Get-Long -Bytes $bytesBaseInfo -Index $dataIndex) + $outHash1)
        $r1 = Convert-ToInt32 -Value (Get-Long -Bytes $bytesBaseInfo -Index ($dataIndex + 4))
        $dataIndex += 8
        $r2a = Convert-ToInt32 -Value (($r0 * $md51) - (0x10FA9605L * (Get-ShiftRight -Value $r0 -Count 16)))
        $r2b = Convert-ToInt32 -Value ((0x79F8A395L * $r2a) + (0x689B6B9FL * (Get-ShiftRight -Value $r2a -Count 16)))
        $r3 = Convert-ToInt32 -Value ((0xEA970001L * $r2b) - (0x3C101569L * (Get-ShiftRight -Value $r2b -Count 16)))
        $r4a = Convert-ToInt32 -Value ($r3 + $r1)
        $r5a = Convert-ToInt32 -Value ($cache + $r3)
        $r6a = Convert-ToInt32 -Value (($r4a * $md52) - (0x3CE8EC25L * (Get-ShiftRight -Value $r4a -Count 16)))
        $r6b = Convert-ToInt32 -Value ((0x59C3AF2DL * $r6a) - (0x2232E0F1L * (Get-ShiftRight -Value $r6a -Count 16)))
        $outHash1 = Convert-ToInt32 -Value ((0x1EC90001L * $r6b) + (0x35BD1EC9L * (Get-ShiftRight -Value $r6b -Count 16)))
        $outHash2 = Convert-ToInt32 -Value ($r5a + $outHash1)
        $cache = $outHash2
        $counter--
    }

    [byte[]] $outHash = New-Object byte[] 16
    [byte[]] $buffer = [BitConverter]::GetBytes([int] $outHash1)
    $buffer.CopyTo($outHash, 0)
    $buffer = [BitConverter]::GetBytes([int] $outHash2)
    $buffer.CopyTo($outHash, 4)

    $cache = 0L
    $outHash1 = 0L
    $outHash2 = 0L
    $dataIndex = 0
    $md51 = [long] ((Get-Long -Bytes $bytesMd5) -bor 1)
    $md52 = [long] ((Get-Long -Bytes $bytesMd5 -Index 4) -bor 1)
    $counter = $index + 1

    while ($counter) {
        $r0 = Convert-ToInt32 -Value ((Get-Long -Bytes $bytesBaseInfo -Index $dataIndex) + $outHash1)
        $dataIndex += 8
        $r1a = Convert-ToInt32 -Value ($r0 * $md51)
        $r1b = Convert-ToInt32 -Value ((0xB1110000L * $r1a) - (0x30674EEFL * (Get-ShiftRight -Value $r1a -Count 16)))
        $r2a = Convert-ToInt32 -Value ((0x5B9F0000L * $r1b) - (0x78F7A461L * (Get-ShiftRight -Value $r1b -Count 16)))
        $r2b = Convert-ToInt32 -Value ((0x12CEB96DL * (Get-ShiftRight -Value $r2a -Count 16)) - (0x46930000L * $r2a))
        $r3 = Convert-ToInt32 -Value ((0x1D830000L * $r2b) + (0x257E1D83L * (Get-ShiftRight -Value $r2b -Count 16)))
        $r4a = Convert-ToInt32 -Value ($md52 * ($r3 + (Get-Long -Bytes $bytesBaseInfo -Index ($dataIndex - 4))))
        $r4b = Convert-ToInt32 -Value ((0x16F50000L * $r4a) - (0x5D8BE90BL * (Get-ShiftRight -Value $r4a -Count 16)))
        $r5a = Convert-ToInt32 -Value ((0x96FF0000L * $r4b) - (0x2C7C6901L * (Get-ShiftRight -Value $r4b -Count 16)))
        $r5b = Convert-ToInt32 -Value ((0x2B890000L * $r5a) + (0x7C932B89L * (Get-ShiftRight -Value $r5a -Count 16)))
        $outHash1 = Convert-ToInt32 -Value ((0x9F690000L * $r5b) - (0x405B6097L * (Get-ShiftRight -Value $r5b -Count 16)))
        $outHash2 = Convert-ToInt32 -Value ($outHash1 + $cache + $r3)
        $cache = $outHash2
        $counter--
    }

    $buffer = [BitConverter]::GetBytes([int] $outHash1)
    $buffer.CopyTo($outHash, 8)
    $buffer = [BitConverter]::GetBytes([int] $outHash2)
    $buffer.CopyTo($outHash, 12)

    [byte[]] $outHashBase = New-Object byte[] 8
    $hashValue1 = (Get-Long -Bytes $outHash -Index 8) -bxor (Get-Long -Bytes $outHash)
    $hashValue2 = (Get-Long -Bytes $outHash -Index 12) -bxor (Get-Long -Bytes $outHash -Index 4)
    $buffer = [BitConverter]::GetBytes($hashValue1)
    $buffer.CopyTo($outHashBase, 0)
    $buffer = [BitConverter]::GetBytes($hashValue2)
    $buffer.CopyTo($outHashBase, 4)

    return [Convert]::ToBase64String($outHashBase)
}

function Get-UserChoiceExperience {
    if ($script:UserChoiceExperience) {
        return $script:UserChoiceExperience
    }

    $fallback = 'User Choice set via Windows User Experience {D18B6DD5-6124-4341-9318-804003BAFA0B}'
    $stream = $null
    $reader = $null
    try {
        $shell32Path = [Environment]::GetFolderPath([Environment+SpecialFolder]::SystemX86) + '\Shell32.dll'
        $stream = [IO.File]::Open($shell32Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $reader = [IO.BinaryReader]::new($stream)
        [byte[]] $bytes = $reader.ReadBytes(5MB)
        $text = [Text.Encoding]::Unicode.GetString($bytes)
        $searchText = 'User Choice set via Windows User Experience'
        $start = $text.IndexOf($searchText, [StringComparison]::Ordinal)
        $finish = if ($start -ge 0) { $text.IndexOf('}', $start) } else { -1 }
        $script:UserChoiceExperience = if ($finish -gt $start) {
            $text.Substring($start, $finish - $start + 1)
        } else {
            $fallback
        }
    } catch {
        $script:UserChoiceExperience = $fallback
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        } elseif ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    return $script:UserChoiceExperience
}

function Get-CurrentMinute {
    $now = [DateTime]::Now
    return [DateTime]::new($now.Year, $now.Month, $now.Day, $now.Hour, $now.Minute, 0, [DateTimeKind]::Local)
}

function New-UserChoiceHash {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FileExtension,

        [Parameter(Mandatory = $true)]
        [string] $TargetProgId,

        [Parameter(Mandatory = $true)]
        [DateTime] $Minute
    )

    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value.ToLowerInvariant()
    $fileTime = $Minute.ToFileTime()
    $high = $fileTime -shr 32
    $low = $fileTime -band 0xFFFFFFFFL
    $dateTimeHex = ($high.ToString('X8') + $low.ToString('X8')).ToLowerInvariant()
    $experience = Get-UserChoiceExperience
    $baseInfo = "$FileExtension$sid$TargetProgId$dateTimeHex$experience".ToLowerInvariant()
    return Get-UserChoiceHash -BaseInfo $baseInfo
}

function Get-UserChoiceState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FileExtension
    )

    $relativeKey = "$script:FileExtsRegistryRoot\$FileExtension\UserChoice"
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($relativeKey)
    if ($null -eq $key) {
        return [pscustomobject]@{
            KeyPresent = $false
            ProgId = $null
            Hash = $null
            HashValid = $false
            LastWriteMinute = $null
            Values = @()
        }
    }

    try {
        $currentProgId = [string] $key.GetValue('ProgId')
        $storedHash = [string] $key.GetValue('Hash')
        $savedValues = @(
            foreach ($valueName in $key.GetValueNames()) {
                [pscustomobject]@{
                    Name = $valueName
                    Value = $key.GetValue($valueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    Kind = $key.GetValueKind($valueName)
                }
            }
        )
    } finally {
        $key.Dispose()
    }

    $lastWriteFileTime = [DefaultAppAssociation.NativeMethods]::GetCurrentUserKeyLastWriteFileTime($relativeKey)
    $lastWrite = [DateTime]::FromFileTimeUtc($lastWriteFileTime).ToLocalTime()
    $lastWriteMinute = [DateTime]::new(
        $lastWrite.Year,
        $lastWrite.Month,
        $lastWrite.Day,
        $lastWrite.Hour,
        $lastWrite.Minute,
        0,
        [DateTimeKind]::Local)

    $hashValid = $false
    if (-not [string]::IsNullOrWhiteSpace($currentProgId) -and -not [string]::IsNullOrWhiteSpace($storedHash)) {
        $expectedHash = New-UserChoiceHash -FileExtension $FileExtension -TargetProgId $currentProgId -Minute $lastWriteMinute
        $hashValid = $storedHash -ceq $expectedHash
    }

    return [pscustomobject]@{
        KeyPresent = $true
        ProgId = $currentProgId
        Hash = $storedHash
        HashValid = $hashValid
        LastWriteMinute = $lastWriteMinute
        Values = $savedValues
    }
}

function Assert-ClassicUserChoiceSupported {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FileExtension
    )

    $latestKey = "HKCU:\$script:FileExtsRegistryRoot\$FileExtension\UserChoiceLatest"
    if (Test-Path -LiteralPath $latestKey) {
        throw "Windows uses UserChoiceLatest for '$FileExtension'. Its machine-specific hash is not supported; use Settings > Apps > Default apps."
    }
}

function Set-UserChoiceValue {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FileExtension,

        [Parameter(Mandatory = $true)]
        [string] $TargetProgId,

        [object[]] $AdditionalValues = @()
    )

    $relativeKey = "$script:FileExtsRegistryRoot\$FileExtension\UserChoice"
    $lastState = $null

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        [DefaultAppAssociation.NativeMethods]::DeleteCurrentUserKey($relativeKey)

        $minute = Get-CurrentMinute
        $hash = New-UserChoiceHash -FileExtension $FileExtension -TargetProgId $TargetProgId -Minute $minute
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($relativeKey, $true)
        if ($null -eq $key) {
            throw "Could not create HKCU:\$relativeKey."
        }

        try {
            foreach ($savedValue in $AdditionalValues) {
                if ($savedValue.Name -notin @('Hash', 'ProgId')) {
                    $key.SetValue($savedValue.Name, $savedValue.Value, $savedValue.Kind)
                }
            }
            $key.SetValue('Hash', $hash, [Microsoft.Win32.RegistryValueKind]::String)
            $key.SetValue('ProgId', $TargetProgId, [Microsoft.Win32.RegistryValueKind]::String)
        } finally {
            $key.Dispose()
        }

        $lastState = Get-UserChoiceState -FileExtension $FileExtension
        if ($lastState.ProgId -ceq $TargetProgId -and $lastState.HashValid) {
            return $lastState
        }
    }

    $foundProgId = if ($null -ne $lastState) { $lastState.ProgId } else { $null }
    throw "UserChoice verification failed for '$FileExtension' after five attempts. Found ProgID '$foundProgId'."
}

function Restore-UserChoiceState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FileExtension,

        [Parameter(Mandatory = $true)]
        $State
    )

    $relativeKey = "$script:FileExtsRegistryRoot\$FileExtension\UserChoice"
    if (-not $State.KeyPresent) {
        [DefaultAppAssociation.NativeMethods]::DeleteCurrentUserKey($relativeKey)
        return
    }
    if ($State.HashValid -and -not [string]::IsNullOrWhiteSpace($State.ProgId)) {
        $null = Set-UserChoiceValue -FileExtension $FileExtension -TargetProgId $State.ProgId -AdditionalValues $State.Values
        return
    }

    [DefaultAppAssociation.NativeMethods]::DeleteCurrentUserKey($relativeKey)
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($relativeKey, $true)
    try {
        foreach ($savedValue in $State.Values) {
            $key.SetValue($savedValue.Name, $savedValue.Value, $savedValue.Kind)
        }
    } finally {
        $key.Dispose()
    }
}

function Send-AssociationChangeNotification {
    [DefaultAppAssociation.NativeMethods]::NotifyAssociationChanged()
}

function Get-ProgIdOpenCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string] $TargetProgId
    )

    $openCommandKey = "Registry::HKEY_CLASSES_ROOT\$TargetProgId\shell\open\command"
    if (-not (Test-Path -LiteralPath $openCommandKey)) {
        throw "ProgID '$TargetProgId' does not define an open command."
    }

    $key = Get-Item -LiteralPath $openCommandKey
    try {
        $command = [string] $key.GetValue('')
    } finally {
        $key.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace($command)) {
        throw "ProgID '$TargetProgId' has an empty open command."
    }
    return $command
}

function ConvertTo-FileExtensions {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Extensions
    )

    $normalizedExtensions = [Collections.Generic.List[string]]::new()
    foreach ($extensionList in $Extensions) {
        foreach ($extensionValue in $extensionList.Split(',')) {
            $extension = $extensionValue.Trim().ToLowerInvariant()
            if ($extension -notmatch '^\.?[A-Za-z0-9][A-Za-z0-9._+-]*$') {
                throw "Invalid file extension: '$extensionValue'."
            }
            if (-not $extension.StartsWith('.')) {
                $extension = ".$extension"
            }
            if (-not $normalizedExtensions.Contains($extension)) {
                $normalizedExtensions.Add($extension)
            }
        }
    }
    return $normalizedExtensions.ToArray()
}

function Get-ApplicationRegistration {
    param(
        [Parameter(Mandatory = $true)]
        [string] $TargetApplicationPath,

        [Parameter(Mandatory = $true)]
        [string] $TargetApplicationArguments
    )

    $expandedPath = [Environment]::ExpandEnvironmentVariables($TargetApplicationPath)
    $application = Get-Item -LiteralPath $expandedPath
    if ($application.PSProvider.Name -ne 'FileSystem' -or $application.PSIsContainer -or
        [IO.Path]::GetExtension($application.FullName) -ine '.exe') {
        throw "ApplicationPath must identify an executable file: $expandedPath"
    }

    $openCommand = '"{0}" {1}' -f $application.FullName, $TargetApplicationArguments
    $commandBytes = [Text.Encoding]::UTF8.GetBytes($openCommand)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $commandDigest = $sha256.ComputeHash($commandBytes)
    } finally {
        $sha256.Dispose()
    }
    $commandHash = [BitConverter]::ToString($commandDigest).Replace('-', '').ToLowerInvariant()
    $applicationProgId = "msrTools.FileAssociation.$commandHash"
    $relativePath = "Software\Classes\$applicationProgId"
    $existingKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($relativePath)
    $exists = $null -ne $existingKey
    if ($exists) {
        $commandKey = $null
        try {
            $commandKey = $existingKey.OpenSubKey('shell\open\command')
            if ($null -eq $commandKey -or [string] $commandKey.GetValue('') -cne $openCommand) {
                throw "Generated ProgID '$applicationProgId' already exists with a different or incomplete command; refusing to overwrite it."
            }
        } finally {
            if ($null -ne $commandKey) {
                $commandKey.Dispose()
            }
            $existingKey.Dispose()
        }
    }

    return [pscustomobject]@{
        ProgId = $applicationProgId
        RelativePath = $relativePath
        OpenCommand = $openCommand
        Exists = $exists
        Created = $false
    }
}

function Register-ApplicationProgId {
    param([Parameter(Mandatory = $true)] $Registration)

    if ($Registration.Exists) {
        return
    }
    $existingKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Registration.RelativePath)
    if ($null -ne $existingKey) {
        $existingKey.Dispose()
        throw "Application registration changed during the operation; refusing to overwrite '$($Registration.ProgId)'."
    }
    $registrationKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($Registration.RelativePath, $true)
    try {
        $Registration.Created = $true
    } finally {
        $registrationKey.Dispose()
    }
    $commandKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$($Registration.RelativePath)\shell\open\command", $true)
    try {
        $commandKey.SetValue('', $Registration.OpenCommand, [Microsoft.Win32.RegistryValueKind]::String)
    } finally {
        $commandKey.Dispose()
    }
}

function Remove-ApplicationRegistration {
    param([Parameter(Mandatory = $true)] $Registration)

    if (-not $Registration.Created) {
        return
    }
    if ($Registration.RelativePath -cnotmatch '^Software\\Classes\\msrTools\.FileAssociation\.[0-9a-f]{64}$') {
        throw 'Refusing to remove an application registration outside the dedicated namespace.'
    }
    $suffixes = @('', '\shell', '\shell\open', '\shell\open\command')
    for ($keyIndex = $suffixes.Count - 1; $keyIndex -ge 0; $keyIndex--) {
        $relativePath = $Registration.RelativePath + $suffixes[$keyIndex]
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($relativePath)
        if ($null -eq $key) {
            continue
        }
        try {
            $valueNames = @($key.GetValueNames())
            $ownedCommand = $keyIndex -eq 3 -and $valueNames.Count -eq 1 -and $valueNames[0] -ceq '' -and
                [string] $key.GetValue('') -ceq $Registration.OpenCommand
            if ($key.SubKeyCount -ne 0 -or ($valueNames.Count -ne 0 -and -not $ownedCommand)) {
                throw "Application registration contains unexpected data; preserving '$relativePath'."
            }
        } finally {
            $key.Dispose()
        }
        [DefaultAppAssociation.NativeMethods]::DeleteCurrentUserKey($relativePath)
    }
    $Registration.Created = $false
}

function Set-FileAssociation {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^\.?[A-Za-z0-9][A-Za-z0-9._+-]*$')]
        [string] $FileExtension,

        [string] $TargetProgId = '',
        [string] $TargetApplicationPath = '',
        [string] $TargetApplicationArguments = '"%1"',
        [switch] $Force
    )

    $hasProgId = -not [string]::IsNullOrWhiteSpace($TargetProgId)
    $hasApplication = -not [string]::IsNullOrWhiteSpace($TargetApplicationPath)
    if ($hasProgId -eq $hasApplication) {
        throw "Association for '$FileExtension' must specify exactly one of progId or applicationPath."
    }

    $normalizedExtension = if ($FileExtension.StartsWith('.')) {
        $FileExtension.ToLowerInvariant()
    } else {
        ".$($FileExtension.ToLowerInvariant())"
    }

    Assert-ClassicUserChoiceSupported -FileExtension $normalizedExtension

    $registration = $null
    if ($hasProgId) {
        $effectiveProgId = $TargetProgId
        $null = Get-ProgIdOpenCommand -TargetProgId $effectiveProgId
    } else {
        $registration = Get-ApplicationRegistration -TargetApplicationPath $TargetApplicationPath -TargetApplicationArguments $TargetApplicationArguments
        $effectiveProgId = $registration.ProgId
    }

    $previousState = Get-UserChoiceState -FileExtension $normalizedExtension
    $needsRegistration = $null -ne $registration -and -not $registration.Exists
    if (-not $Force -and -not $needsRegistration -and $previousState.ProgId -ceq $effectiveProgId -and $previousState.HashValid) {
        return [pscustomobject]@{
            Extension = $normalizedExtension
            PreviousProgId = $previousState.ProgId
            CurrentProgId = $previousState.ProgId
            TargetProgId = $effectiveProgId
            HashValid = $true
            Changed = $false
        }
    }

    $changed = $false
    $associationApplied = $false
    $currentState = $previousState
    if ($PSCmdlet.ShouldProcess($normalizedExtension, "Set default application to '$effectiveProgId'")) {
        $choiceWriteAttempted = $false
        try {
            if ($needsRegistration) {
                Register-ApplicationProgId -Registration $registration
            }
            $choiceWriteAttempted = $true
            $currentState = Set-UserChoiceValue -FileExtension $normalizedExtension -TargetProgId $effectiveProgId -AdditionalValues $previousState.Values
            Send-AssociationChangeNotification
        } catch {
            $operationError = $_
            $restoreErrors = [Collections.Generic.List[string]]::new()
            if ($choiceWriteAttempted) {
                try {
                    Restore-UserChoiceState -FileExtension $normalizedExtension -State $previousState
                } catch {
                    $restoreErrors.Add("UserChoice: $($_.Exception.Message)")
                }
            }
            if ($null -ne $registration -and $registration.Created) {
                try {
                    Remove-ApplicationRegistration -Registration $registration
                } catch {
                    $restoreErrors.Add("Application registration: $($_.Exception.Message)")
                }
            }
            if ($restoreErrors.Count -ne 0) {
                throw "Setting '$normalizedExtension' failed. Set error: $($operationError.Exception.Message) Restore errors: $($restoreErrors -join '; ')"
            }
            throw "Setting '$normalizedExtension' failed; previous state was restored. $($operationError.Exception.Message)"
        }

        $associationApplied = $true
        $changed = $true
    }

    if ($associationApplied -and ($currentState.ProgId -cne $effectiveProgId -or -not $currentState.HashValid)) {
        throw "Association verification failed for '$normalizedExtension'. Expected '$effectiveProgId', found '$($currentState.ProgId)'."
    }

    return [pscustomobject]@{
        Extension = $normalizedExtension
        PreviousProgId = $previousState.ProgId
        CurrentProgId = $currentState.ProgId
        TargetProgId = $effectiveProgId
        HashValid = $currentState.HashValid
        Changed = $changed
    }
}

if ($PSCmdlet.ParameterSetName -eq 'Config') {
    $resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
    $associationsProperty = $config.PSObject.Properties['associations']
    if ($null -eq $associationsProperty -or @($associationsProperty.Value).Count -eq 0) {
        throw "Configuration file must contain a non-empty associations array: $resolvedConfigPath"
    }

    $configDirectory = Split-Path -Parent $resolvedConfigPath
    foreach ($association in @($associationsProperty.Value)) {
        $extensionsProperty = $association.PSObject.Properties['extensions']
        $extensions = if ($null -ne $extensionsProperty) { @($extensionsProperty.Value) } else { @() }
        if ($extensions.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string] $extensions[0])) {
            throw 'Every association must contain at least one extension.'
        }

        $progIdProperty = $association.PSObject.Properties['progId']
        $configuredProgId = if ($null -ne $progIdProperty) { [string] $progIdProperty.Value } else { '' }
        $applicationPathProperty = $association.PSObject.Properties['applicationPath']
        $configuredApplicationPath = if ($null -ne $applicationPathProperty) {
            [Environment]::ExpandEnvironmentVariables([string] $applicationPathProperty.Value)
        } else {
            ''
        }
        if ($configuredApplicationPath -and -not [IO.Path]::IsPathRooted($configuredApplicationPath)) {
            $configuredApplicationPath = Join-Path $configDirectory $configuredApplicationPath
        }

        $applicationArgumentsProperty = $association.PSObject.Properties['applicationArguments']
        $configuredArguments = if ($null -ne $applicationArgumentsProperty) {
            [string] $applicationArgumentsProperty.Value
        } else {
            '"%1"'
        }

        foreach ($configuredExtension in (ConvertTo-FileExtensions -Extensions $extensions)) {
            $associationParameters = @{
                FileExtension = [string] $configuredExtension
                TargetProgId = $configuredProgId
                TargetApplicationPath = $configuredApplicationPath
                TargetApplicationArguments = $configuredArguments
                Force = $Force
            }
            if ($WhatIfPreference) {
                $associationParameters.WhatIf = $true
            }
            Set-FileAssociation @associationParameters
        }
    }
} else {
    foreach ($requestedExtension in (ConvertTo-FileExtensions -Extensions $Extension)) {
        $associationParameters = @{
            FileExtension = $requestedExtension
            Force = $Force
        }

        if ($PSCmdlet.ParameterSetName -eq 'ProgId') {
            $associationParameters.TargetProgId = $ProgId
        } else {
            $associationParameters.TargetApplicationPath = $ApplicationPath
            $associationParameters.TargetApplicationArguments = $ApplicationArguments
        }

        if ($WhatIfPreference) {
            $associationParameters.WhatIf = $true
        }
        Set-FileAssociation @associationParameters
    }
}
