<#
.SYNOPSIS
    Install apps for downloading + transforming videos.

.DESCRIPTION

.PARAMETER NeedEmbedThumbnail
    Will install AtomicParsley if need embed-thumbnail when downloading videos.

.EXAMPLE
    ./Install-Apps.ps1
    ./Install-Apps.ps1 $true
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][bool] $NeedEmbedThumbnail = $false
)

Import-Module "$PSScriptRoot/../common/Check-Tools.psm1"
Import-Module "$PSScriptRoot/../common/CommonUtils.psm1"

if ($MyInvocation.Line -imatch '\s+-+help') {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    msr -aPA -z "To allow running PowerShell on Windows: PowerShell Set-ExecutionPolicy Unrestricted -Scope LocalMachine -Force" -e ".+?(Set-Exe.*)"
    exit 0
}

Test-ToolAndInstall "youtube-dl"
Test-ToolAndInstall "ffmpeg"

if ($NeedEmbedThumbnail) {
    Test-ToolAndInstall "AtomicParsley"
}
