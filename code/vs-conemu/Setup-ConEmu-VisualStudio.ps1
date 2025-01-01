<#
.DESCRIPTION
    Auto setup ConEmu + Visual Studio integration.

.Parameter ConEmuConfigPaths
    All possible config paths of ConEmu (separated by comma) like: C:\Program Files\ConEmu\ConEmu.xml, $env:APPDATA\ConEmu.xml, $env:TMP\ConEmu
    You can input 1 or more paths, skip file paths not-exist or you don't want to change.

.Parameter TmpConfigPattern
    Regex pattern to match the temporary config file. Default is '^Con\w+\.xml$'

.EXAMPLE
    .\Setup-ConEmu-VisualStudio.ps1
    .\Setup-ConEmu-VisualStudio.ps1 -ConEmuConfigPaths 'C:\Program Files\ConEmu\ConEmu.xml, $env:APPDATA\ConEmu.xml, $env:TMP\ConEmu'
    .\Setup-ConEmu-VisualStudio.ps1 -ConEmuConfigPaths 'C:\Program Files\ConEmu\ConEmu.xml, $env:APPDATA\ConEmu.xml, $env:TMP\ConEmu' -TmpConfigPattern '^Con\w+\.xml$'
#>

[CmdletBinding()]
param(
    [string] $ConEmuConfigPaths = "$env:ProgramFiles\ConEmu\ConEmu.xml, $env:APPDATA\ConEmu.xml, $env:TMP\ConEmu",
    [string] $TmpConfigPattern = '^Con\w+\.xml$'
)

Import-Module "$PSScriptRoot/../../common/CommonUtils.psm1"
$ToolPath = $(Resolve-Path $(Join-Path $PSScriptRoot "Open-ClickedPathRow-in-VisualStudio.ps1")).Path
$ToolName = [IO.Path]::GetFileName($ToolPath)
$ToolPathSlashes = $ToolPath.Replace('\', '\\')
$ToolCommand = "PowerShell -NoProfile -ExecutionPolicy Bypass -NoLogo -WindowStyle Hidden -File $($ToolPathSlashes) &quot;%1&quot; &quot;%2&quot; &quot;%3&quot;"
Show-Info "Run as Admin to avoid permission errors of updating ConEmu config files."

function Update-ConfigItems {
    param(
        [string[]] $ConfigPathList
    )

    $filePaths = $ConfigPathList -join ','
    Show-Message "Will change ConEmu config for FarGotoEditorPath ..."
    msr -p $filePaths -x FarGotoEditorPath -t "data\s*=\s*(\S).*?\1" -o "data=\1$($ToolCommand)\1" --nt "$($ToolName) &quot;%1&quot;" -R -M -T 0

    # https://github.com/Maximus5/ConEmu/blob/master/src/ConEmu/Options.h#L769
    Show-Message "Will change ConEmu config for Tabs display ..." # NotShow=0 AlwaysShow=1 AutoShow=2
    msr -p $filePaths -x "name=\`"Tabs\`"" -it "data\s*=\s*(\S)\S+?\1" -o "data=\102\1" --sp $env:TMP -R -M -T 0 Auto-show tabs for ConEmu in Visual Studio
    msr -p $filePaths -x "name=\`"Tabs\`"" -it "data\s*=\s*(\S)\S+?\1" -o "data=\101\1" --xp $env:TMP -R -M -T 0 Always show tabs for normal ConEmu
}

function Add-ConfigItems {
    param(
        [string[]] $ConfigPathList
    )

    foreach ($file in $ConfigPathList) {
        msr -p $file -it "^\s*<.*?\bname=\`"FarGotoEditorPath\`"" -M -H 0
        if ($LASTEXITCODE -eq 0) {
            Show-Message "Will add FarGotoEditorPath setting to default ConEmu config ..."
            $firstName = msr -p $file -it "^\s*<value name=\`"(\w+)\`" type=.*" -o "\1" -PAC -H 1
            $content = msr -p $file -it "^(\s*)<value name=\`"($firstName)\`" type=\`"(.+?)\`" data=\`"(.+?)\`"(\s*/>)" -o "\1<value name=\`"\2\`" type=\`"\3\`" data=\`"\4\`"\5\n\1<value name=\`"FarGotoEditorPath\`" type=\`"string\`" data=\`"$($ToolCommand)\`"\5" -aPAC
            $content | Set-Content -Path $file
            if (-not $?) {
                Show-ErrorThrow "Failed to write file: $file, Please run as Admin."
            }
        }
        msr -p $file -it "^\s*<.*?\bname=\`"Tabs\`"" -M -H 0
        if ($LASTEXITCODE -eq 0) {
            Show-Message "Will add Tabs setting to default ConEmu config ..."
            $firstName = msr -p $file -it "^\s*<value name=\`"(\w+)\`" type=.*" -o "\1" -PAC -H 1
            $showTabsValue = if ($file.StartsWith($env:TMP, [StringComparison]::OrdinalIgnoreCase)) { '02' } else { '01' }
            $content = msr -p $file -it "^(\s*)<value name=\`"($firstName)\`" type=\`"(.+?)\`" data=\`"(.+?)\`"(\s*/>)" -o "\1<value name=\`"\2\`" type=\`"\3\`" data=\`"\4\`"\5\n\1<value name=\`"Tabs\`" type=\`"dword\`" data=\`"$($showTabsValue)\`"\5" -aPAC
            $content | Set-Content -Path $file
            if (-not $?) {
                Show-ErrorThrow "Failed to write file: $file, Please run as Admin."
            }
        }
    }
}

$configPathList = msr -rp "$ConEmuConfigPaths" -f $TmpConfigPattern -l -PAC 2>$null
if ($configPathList.Count -eq 0) {
    Show-Error "No ConEmu config file found from input paths: $ConEmuConfigPaths"
    exit 1
}

Update-ConfigItems $configPathList
Add-ConfigItems $configPathList

Show-Message "Will show all ConEmu config changes:"
msr -p $($ConfigPathList -join ',') -t "name\s*=\W+(Tabs|FarGotoEditorPath)\b" -e "data\s*=\s*(\S)(.+?)\1" -M
if ($configPathList.Count -eq 1) {
    Show-Warning "Not found other ConEmu config files, please re-run this when you started ConEmu in Visual Studio."
}
Show-Warning "If you run this in a ConEmu terminal, please restart the ConEmu (or reload config in the ConEmu) to take effect."
exit 0
