<#
.SYNOPSIS
    Fast build projects using QuickBuild which causes huge disk usage + sometimes very slow.

.Parameter ProjectPaths
    The project paths to build. Can be a single path or multiple paths separated by comma or semicolon.
.Parameter ExtensionPattern
    The file extension pattern to search for projects. Default is '\.(cs|vcx?)proj$'.
.Parameter Configuration
    The build configuration: Debug / Release. Default is 'Release'.
.Parameter Platform
    The build platform: x64 / x86. Default is 'x64'.
.Parameter Action
    The build action: Build / Clean / ReBuild. Default is 'Build'. (ReBuild may fail if a project not defines a ReBuild target)
.Parameter VisualStudioVersion
    The Visual Studio version to use (like 14.0). Default is '' which means the latest version.
.Parameter CPU
    The CPU count to use for build. Default is 80% of the total CPU count.
.Parameter Verbosity
    The build verbosity: quiet / minimal / normal / detailed / diagnostic. Default is 'minimal'.
.Parameter SkipProjectPattern
    Regex pattern of project file path, if matched, skip it. Examples like 'Test|Mock'. Input anything like 'Not-Skip-Any' to not skip.
.Parameter ThisLogLevel
    The log level for this script. Default is 'Info'.
.Parameter CompareNewBuildAndSkip
    Compare new build and skip if no changes. Default is $true.
.Parameter FromProject
    From which project to build: The sub text of project file path. Default is '' which means build all projects.
.Parameter RefreshInitCmdDuration
    The duration to refresh init.cmd. Default is '24hours'. Examples like '1day', '2hours', '30minutes'.
.Parameter CleanBuild
    Run 'git clean -dfx' for each project folder. Default is $false. This is a workaround of ReBuild not defined in some projects.
.Parameter NotBuildOtherProjects
    Not build other projects. Default is $false.
.Parameter OnlyShowCommands
    Only show the build commands without building. Default is $false.
.Parameter JustListProjects
    Just list the projects without building. Default is $false.
.Parameter ContinueOnBuildError
    Continue on build error. Default is $false.

.EXAMPLE
    .\Fast-Build-Projects.ps1 C:\my-repo\project-folder
    .\Fast-Build-Projects.ps1 C:\my-repo\project-folder -OnlyShowCommands -CompareNewBuildAndSkip 0
    .\Fast-Build-Projects.ps1 C:\my-repo\project-folder -Configuration Debug -CleanBuild
    .\Fast-Build-Projects.ps1 'C:\my-repo\project-folder1,C:\my-repo\project-folder2'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ProjectPaths,
    [string] $ExtensionPattern = '\.(cs|vcx?)proj$',
    [string] $Configuration = 'Release',
    [string] $Platform = 'x64',
    [string] $Action = 'Build', # Build, Clean, ReBuild
    [string] $VisualStudioVersion = '', #'14.0',
    [string] $CPU = [Math]::Round($env:NUMBER_OF_PROCESSORS / 1.0 * 0.8),
    [string] $Verbosity = 'quiet', # quiet, minimal, normal (default), detailed, diagnostic
    [string] $SkipProjectPattern = 'Test|Mock',
    [string] $ThisLogLevel = "Info", # [TimeLogLevel]
    [bool] $CompareNewBuildAndSkip = $true,
    [bool] $CreateOutputFolders = $false,
    [string] $FromProject = "",
    [string] $RefreshInitCmdDuration = '24hours', # 1day
    [switch] $CleanBuild,
    [switch] $NotBuildOtherProjects,
    [switch] $OnlyShowCommands,
    [switch] $JustListProjects,
    [switch] $ContinueOnBuildError
)

Import-Module "$PSScriptRoot/../common/BasicOsUtils.psm1"
Import-Module "$PSScriptRoot/../common/CommonUtils.psm1"

# $ErrorActionPreference = "Stop"

if ($MyInvocation.Line -imatch '\s+--help') {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    return
}

# $TimeLogger = New-BeginEndLogger $MyInvocation
$TimeLogger.SetLogLevel($ThisLogLevel).SetInfo($MyInvocation)

$inputPaths = $ProjectPaths -split '\s*[,;]\s*'
$InputProjectPaths = New-Object System.Collections.Generic.HashSet[String]([StringComparer]::OrdinalIgnoreCase)
msr -rp $ProjectPaths -l -f $ExtensionPattern -W -PAC | ForEach-Object { [void] $InputProjectPaths.Add($_) }

$script:HasFoundStartProject = [string]::IsNullOrWhiteSpace($FromProject)
$script:CompileTargetConfigFile = ''

# https://learn.microsoft.com/en-us/visualstudio/msbuild/msbuild-command-line-reference
$BuildHead = "/p:VisualStudioVersion=$($VisualStudioVersion) /t:$($Action) /p:ContinueOnError=false /p:StopOnFirstFailure=true /m:$($CPU) /v:$($Verbosity) /p:Configuration=$($Configuration) /p:Platform=$($Platform)" #"/clp:$($LogLevel)"
$BuildHead = $("MSBuild -NoLogo " + $($BuildHead -replace '\S+=\s+', ' ').Trim()).Trim()

$SkipProjectRegex = New-Object System.Text.RegularExpressions.Regex($SkipProjectPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$RepoInfo = New-GitRepoInfo $inputPaths[0]
$RepoFolder = $RepoInfo.RootFolder + $SysPathChar
$TimeLogger.ShowMessage("RepoFolder = $($RepoFolder), ModuleFolder: $($RepoInfo.SubModuleRoot)")

$SearchProjectReferencePattern = $ExtensionPattern.Replace('$', '')
$script:BuiltProjectPaths = New-Object System.Collections.Generic.HashSet[string]
$script:FoundImportTargets = New-Object System.Collections.Generic.HashSet[string]

$ObjFolderName = if ($Configuration -imatch 'debug') { 'objd' } else { 'obj' }
$ObjSubPath = '/' + $ObjFolderName + '/'

if ($Action -imatch 'ReBuild|Clean' -or $CleanBuild) {
    $CompareNewBuildAndSkip = $false
}

$AllBuildCommands = New-Object System.Collections.Generic.HashSet[string]
$script:ProjectCount = 0
$script:BuildCount = 0

$MapSubModuleToEnvFile = @{}

$BinPlaceFolderToCreate = New-Object System.Collections.Generic.HashSet[String]([StringComparer]::OrdinalIgnoreCase)

function Init_One_SubModules_Env {
    param (
        $MapSubModuleToEnvFile,
        [string] $GitSubModuleFolder,
        [bool] $ReadEnv = $false,
        [bool] $IsTopProject = $false
    )
    $GitSubModuleFolder = $GitSubModuleFolder.TrimEnd($SysPathChar)
    $tmpSaveEnvFileName = ($GitSubModuleFolder -ireplace '[^\w\.-]+', '_') + "_env.cmd"
    $tmpSaveEnvFilePath = Join-Path $SysTmpFolder $tmpSaveEnvFileName
    $MapSubModuleToEnvFile[$GitSubModuleFolder] = $tmpSaveEnvFilePath
    $initCmdPath = Join-Path $GitSubModuleFolder 'init.cmd'
    $shouldRunInit = [IO.File]::Exists($initCmdPath)
    Show-Message "Check packages in $($GitSubModuleFolder)"
    msr -rp "$GitSubModuleFolder/private/packages,$GitSubModuleFolder" -d "^packages$" -f "\.(lib|dll)$" -k 7 -l -H 1 -J -M 2>$null
    $hasPackageFile = $LASTEXITCODE -eq 1
    if ([IO.File]::Exists($tmpSaveEnvFilePath)) {
        $hideArgs = if ($IsTopProject) { @() } else { @("-H", "0") }
        msr -l --wt --sz --s1 300 --w1 $RefreshInitCmdDuration -p $tmpSaveEnvFilePath $hideArgs -M
        if ($LASTEXITCODE -eq 1 -and $hasPackageFile) {
            $shouldRunInit = $false
            $TimeLogger.ShowMessage("Skip refreshing init.cmd of $($GitSubModuleFolder) with duration = $($RefreshInitCmdDuration).")
        }
    }

    if ($shouldRunInit) {
        Reset-EnvVars # $true
        Save-TextToFileUtf8NoBOM $tmpSaveEnvFilePath "@echo off" -SetTailOneNewLine $true
        $command = "$($PushFolderCmd) $($GitSubModuleFolder) && init.cmd & set | msr -t '^(\w+)=\'?(.+?)\\*\'?$' -o 'set \'\1=\2\'' -PAC >> $($tmpSaveEnvFilePath)".Replace("'", '"')
        Invoke-CommandLine $command -SuccessReturnRegex "[1-9]+"
    }

    if (-not $ReadEnv) {
        return
    }

    $nameValues = msr -p $tmpSaveEnvFilePath -it '^set \"(\w+)=(.+)\"' -o "\1=\2" -PAC
    $parseEnvRegex = New-Object System.Text.RegularExpressions.Regex('^(\w+)=(.+)')
    $TimeLogger.ShowMessage("Found $($nameValues.Count) env values from $($tmpSaveEnvFilePath)")
    $parsedCount = 0
    foreach ($nv in $nameValues) {
        $match = $parseEnvRegex.Match($nv)
        if ($match.Success) {
            $parsedCount += 1
            $name = $match.Groups[1].Value
            $value = $match.Groups[2].Value
            [System.Environment]::SetEnvironmentVariable($name, $value, [System.EnvironmentVariableTarget]::Process)
        }
    }
    $TimeLogger.ShowInfo("Read $($parsedCount) env name values from $($tmpSaveEnvFilePath)")
}

function Add_Build_Command {
    param (
        [Parameter(Mandatory = $true)][string] $ProjectFilePath
    )

    $script:ProjectCount += 1
    if ($JustListProjects) {
        Write-Output $ProjectFilePath
        return
    }

    $projectFolder = [IO.Path]::GetDirectoryName($ProjectFilePath)
    $command = $PushFolderCmd + ' ' + $projectFolder + ' && '
    if ($CleanBuild) {
        $command += 'git clean -dfx -q && '
    }
    $command += $BuildHead + ' ' + [IO.Path]::GetFileName($ProjectFilePath)
    $projectTitle = [IO.Path]::GetFileNameWithoutExtension($ProjectFilePath)

    if ($CompareNewBuildAndSkip) {
        $buildResultName = msr -p $ProjectFilePath -t "^\s*<TargetName>\s*(.+?)\s*</TargetName>.*" -o "\1" -PAC -H 1
        if ([string]::IsNullOrWhiteSpace($buildResultName)) {
            $buildResultName = msr -p $ProjectFilePath -t "^\s*<ProjectName>\s*(.+?)\s*</ProjectName>.*" -o "\1" -PAC -H 1
            if ([string]::IsNullOrWhiteSpace($buildResultName)) {
                $buildResultName = [IO.Path]::GetFileNameWithoutExtension($ProjectFilePath)
            }
        }

        $buildResultName = $buildResultName.Replace('$(ProjectName)', $projectTitle)
        msr -l --wt --sz -rp $projectFolder --nd "^[\.\$]|\.tLog" --nf "\.(dll|lib|exe)\." --xd -f "^$($buildResultName)\.(dll|lib|exe)$" --sp $ObjSubPath --w1 $ProjectFilePath -M
        if ($LASTEXITCODE -gt 0) {
            $objFile = msr -l --s1 1B --wt --sz -rp $projectFolder --nd "^[\.\$]|\.tLog" --nf "\.(dll|lib|exe)\." --xd -f "^$($buildResultName)\.(dll|lib|exe)$" --sp $ObjSubPath -T 1 -PAC
            $objName = [IO.Path]::GetFileName($objFile)
            $objFolderSubPath = [regex]::Replace($objFile.Replace($SysPathChar, '/'), ".*?($($ObjSubPath)\S*?)\b$($objName)$", '$1').TrimEnd('/') + "/"
            msr -l --s1 1B --wt --sz -rp $projectFolder --nd "^([\.\$]|objd?$)|\.tLog" --xd --w1 $objFile --xp $objFolderSubPath --nf "\.(dll|lib|exe|pdb|ilk|obj|txt|log|pgd)$|\.(dll|lib|exe)\." -M
            if ($LASTEXITCODE -eq 0) {
                msr -aPA -z "$(Get-NowText) Found new build result as above, skip building projects[$($script:ProjectCount)]: $($ProjectFilePath)" -e skip $MsrOutStderrArg
                return
            }
            msr -aPA -z "$(Get-NowText) Detected new files as above, will build projects[$($script:ProjectCount)]: $($ProjectFilePath)" -e "Add \S+" -t "\[\d+\]" $MsrOutStderrArg
        }
        else {
            if ($ProjectFilePath -imatch 'bond|CodeGen') {
                $pathPattern = "$($ObjSubPath)\S*/Inc/\S*bond\S*\.hp*$" + "|" + "CodeGen\S*$($ObjSubPath)\S*/Inc/\S*\.hp*$" + "|" + "$($ObjSubPath)\S*/c?bondC?/\S*\.hp*$"
                msr -l --s1 1B --wt --sz -rp $projectFolder --nd "^[\.\$]|\.tLog" --nf "\.(dll|lib|exe)\." --xd --w1 $ProjectFilePath -f "\.hp*$" --pp $pathPattern -T 2 -M #-c
                if ($LASTEXITCODE -gt 0) {
                    msr -aPA -z "$(Get-NowText) Found new bond result as above, skip building projects[$($script:ProjectCount)]: $($ProjectFilePath)" -x bond -e skip $MsrOutStderrArg
                    return
                }
            }
            else {
                # Additional check for general build result - to replace above buildResultName checking if proved good in future.
                msr -l --wt --sz -rp $projectFolder --nd "^[\.\$]|\.tLog" --nf "\.(dll|lib|exe)\." --xd --w1 $ProjectFilePath --sp $ObjSubPath -f "\.(dll|lib|exe)$" -T 2 -M
                if ($LASTEXITCODE -gt 0) {
                    msr -aPA -z "$(Get-NowText) Found new output as above, skip building projects[$($script:ProjectCount)]: $($ProjectFilePath)" -e skip $MsrOutStderrArg -x "new output"
                    return
                }
            }
        }
    }

    if (-not $script:HasFoundStartProject) {
        $script:HasFoundStartProject = $ProjectFilePath -imatch [regex]::Escape($FromProject) #-or $ProjectFilePath.Contains($FromProject) #, [System.StringComparison]::OrdinalIgnoreCase)
    }

    if (-not $script:HasFoundStartProject) {
        Show-Message "Skip building projects[$($script:ProjectCount)]: $($ProjectFilePath)"
        return
    }

    if ($NotBuildOtherProjects -and -not $InputProjectPaths.Contains($ProjectFilePath)) {
        Show-Message "Skip building projects[$($script:ProjectCount)]: $($ProjectFilePath)"
        return
    }

    $script:BuildCount += 1
    msr -aPA -z "$(Get-NowText) Add builds[$($script:BuildCount)] of projects[$($script:ProjectCount)]: $($ProjectFilePath)" -e "Add \S+" -t "\[\d+\]" -x $ProjectFilePath $MsrOutStderrArg
    if ($OnlyShowCommands) {
        Write-Output $command
        return
    }

    if ($CreateOutputFolders) {
        $BinPlaceIncludePaths = msr -p $ProjectFilePath -i -b "^\s*<BinPlace" -Q "^\s*</BinPlace>" -t "^.*?Include=.(.+)\W\s*>" -o "\1" -PAC | Sort-Object -Unique
        foreach ($path in $BinPlaceIncludePaths) {
            Create_BinPlaceFolder $BinPlaceFolderToCreate $path $ProjectFilePath
        }

        $BinPlaceDestinations = msr -p $ProjectFilePath -i -b "^\s*<BinPlace" -Q "^\s*</BinPlace>" -t "^\s*<Destination.+?>\s*(.+?)\s*</.*" -o "\1" -PAC | Sort-Object -Unique
        foreach ($path in $BinPlaceDestinations) {
            Create_BinPlaceFolder $BinPlaceFolderToCreate $path $ProjectFilePath
        }
    }

    [void] $AllBuildCommands.Add($command)
}

function Get_MsBuild_Env_Value {
    param (
        [string] $Name,
        [string] $ProjectFilePath,
        $WorkaroundEnvMap = @{ 'BuildType' = 'retail'; 'BuildArchitecture' = 'amd64' }
    )

    $value = [System.Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrEmpty($value)) {
        return $value
    }

    if ($WorkaroundEnvMap.ContainsKey($Name)) {
        return $WorkaroundEnvMap[$Name]
    }

    # https://learn.microsoft.com/en-us/visualstudio/msbuild/msbuild-reserved-and-well-known-properties?view=vs-2022
    if ($Name -imatch '^(MSBuildThisFileDirectory|MSBuildProjectDirectory|ProjectDir)$') {
        $value = [IO.Path]::GetDirectoryName($ProjectFilePath)
        if (-not $value.EndsWith($SysPathChar)) {
            $value += $SysPathChar
        }
    }

    if (-not [string]::IsNullOrEmpty($value)) {
        $TimeLogger.ShowMessage("Found env name value: $($Name) = $($value)")
        return $value
    }

    $values = msr -p $ProjectFilePath -t "^\s*<$($Name)>\s*(.+?)\s*</$($Name)>.*" -o "\1" -PAC
    if ($values.Count -eq 0) {
        # $value = msr -p $ProjectFilePath -t "^\s*<$($Name) Condition\s*=\W+$($Name)\W*==\W+?>\s*(.+?)\s*</$($Name)>.*" -o "\1" -PAC
        $values = msr -p $ProjectFilePath -t "^\s*<$($Name) Condition\s*=.+?>\s*(.+?)\s*</$($Name)>.*" -o "\1" -PAC
        if ($values.Count -eq 0) {
            return ''
        }
    }

    $value = $values
    if ($values.Count -gt 1) {
        $TimeLogger.ShowWarning("Found $($values.Count) value, will choose first: $($Name) = $($values) in project file: $($ProjectFilePath)")
    }

    foreach ($value in $values) {
        if (-not $value.Contains('$(')) {
            return $value
        }
        $expandedValue = Replace_Variable_Path $value $ProjectFilePath
        if (-not [string]::IsNullOrEmpty($expandedValue)) {
            return $expandedValue
        }
    }
    return ''
}

function Replace_Variable_Path {
    param (
        [string] $PathHasVariables,
        [string] $ProjectFilePath,
        [bool] $Recursive = $true
    )

    for ($k = 0; $k -lt 9; $k += 1) {
        $matchedResult = [regex]::Match($PathHasVariables, '^(?<Head>.*?)(?<EnvText>\$\((?<EnvName>\w+)\))(?<Tail>.*)')
        if (-not $matchedResult.Success) {
            return $PathHasVariables
        }
        $envName = $matchedResult.Groups["EnvName"].Value
        if ($envName -eq $PathHasVariables) {
            return $PathHasVariables
        }
        $envValue = Get_MsBuild_Env_Value $envName $ProjectFilePath
        if ([string]::IsNullOrEmpty($envValue)) {
            if ($Recursive -and $PathHasVariables -inotmatch '\.(props|targets)$') {
                $importedTargets = msr -c -p $ProjectFilePath -it "^\s*<Import\s+Project=\`"(.+?)\`".*" -o "\1" -PAC
                foreach ($imported in $importedTargets) {
                    $imported = Replace_Variable_Path $imported $ProjectFilePath -Recursive $false
                    if (-not [string]::IsNullOrEmpty($imported)) {
                        $envValue = Get_MsBuild_Env_Value $envName $imported
                        if (-not [string]::IsNullOrEmpty($envValue)) {
                            break
                        }
                    }
                }
            }

            if ([string]::IsNullOrEmpty($envValue)) {
                $isError = $PathHasVariables -imatch $ExtensionPattern
                $TimeLogger.ShowErrorOrMessage("Cannot replace variable: $($envName) for referenced project path: $($PathHasVariables) defined in $($ProjectFilePath)", $isError)
                return ''
            }
        }

        $pathHead = $matchedResult.Groups["Head"].Value + $envValue
        $PathHasVariables = $pathHead + $matchedResult.Groups["Tail"].Value
        # if (-not [IO.File]::Exists($PathHasVariables)) {
        #     $testPath = Join-Path (Join-Path $pathHead "private") $matchedResult.Groups["Tail"].Value
        #     if ([IO.File]::Exists($testPath)) {
        #         $TimeLogger.ShowWarning("Replaced non-exist path: $($PathHasVariables) to $($testPath), original = $($matchedResult.Value), defined in $($ProjectFilePath)")
        #         $PathHasVariables = $testPath
        #     }
        # }
    }

    return $PathHasVariables
}

function Create_BinPlaceFolder {
    param (
        $BinPlaceFolderToCreate,
        [string] $TargetPath,
        [string] $ProjectFilePath,
        [string] $SkipBinPlaceFolderPattern = "[\\/]objd?[\\/]"
    )
    if ($ProjectFilePath -match $SkipBinPlaceFolderPattern) {
        return
    }

    $expandedPath = Replace_Variable_Path $TargetPath $ProjectFilePath
    if ([string]::IsNullOrEmpty($expandedPath)) {
        return
    }

    if ($expandedPath -match $SkipBinPlaceFolderPattern) {
        return
    }

    $folder = [IO.Path]::GetDirectoryName($expandedPath)
    if (-not $BinPlaceFolderToCreate.Add($folder)) {
        return
    }
    Show-Message "Workaround: Check/Create BinPlace folder: $($folder)" -ForegroundColor Cyan
    Test-CreateDirectory $folder
}

function Get_Project_Path {
    param (
        [string] $RefProjectPath,
        [string] $ProjectFilePath
    )

    $rawPath = $RefProjectPath
    $RefProjectPath = Replace_Variable_Path $RefProjectPath $ProjectFilePath
    if ([string]::IsNullOrEmpty($RefProjectPath)) {
        return ''
    }

    $absolutePath = $(Resolve-Path $RefProjectPath).Path 2>$null
    if ([string]::IsNullOrEmpty($absolutePath) -or -not [IO.File]::Exists($absolutePath)) {
        $match = [regex]::Match($RefProjectPath, "^\S+?GetDirectoryNameOfFileAbove\((?<Path>.+?)\)+(?<Tail>.*)", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            Show-Message "Resolving path: $($RefProjectPath) defined in $($ProjectFilePath)"
            $path = $match.Groups["Path"].Value.Trim()
            $tail = $match.Groups["Tail"].Value.Trim()
            $headValues = $path -split '\s*,\s*'
            $folder = Replace_Variable_Path $headValues[0] $ProjectFilePath
            $tailFileName = if ([string]::IsNullOrEmpty($tail)) { $headValues[1] } else { $tail }
            while (-not [string]::IsNullOrEmpty($folder)) {
                $testPath = Join-Path $folder $tailFileName
                if ([IO.File]::Exists($testPath)) {
                    return $testPath
                }
                $folder = [IO.Path]::GetDirectoryName($folder)
            }
        }
        msr -p $ProjectFilePath -x $rawPath -M --to-stderr
        $isError = $RefProjectPath -imatch $ExtensionPattern
        $TimeLogger.ShowErrorOrWarning("Not found referenced project: $($RefProjectPath) defined in $($ProjectFilePath)", $isError)
        return ''
    }
    return $absolutePath
}

function Build_Reference_Projects {
    param (
        [Parameter(Mandatory = $true)] [string] $ProjectFilePath
    )

    if (-not $script:BuiltProjectPaths.Add($ProjectFilePath)) {
        # $TimeLogger.ShowMessage("Already built project: $($ProjectFilePath)")
        return
    }

    if ($SkipProjectRegex.IsMatch($ProjectFilePath) -and -not $InputProjectPaths.Contains($ProjectFilePath)) {
        $TimeLogger.ShowMessage("Skip project by regex: $($ProjectFilePath)")
        return
    }

    $ProjectFolder = [IO.Path]::GetDirectoryName($ProjectFilePath)
    Push-Location $ProjectFolder
    $TimeLogger.ShowMessage("Searching imports of $($ProjectFilePath)")
    $importedTargets = msr -p $ProjectFilePath -it "^\s*<Import\s+Project=\`"(.+?)\`".*" -o "\1" -PAC
    foreach ($target in $importedTargets) {
        $targetPath = Get_Project_Path $target $ProjectFilePath
        if ([string]::IsNullOrEmpty($targetPath)) {
            $TimeLogger.ShowMessage("Skip unresolvable target: $($target) in $($ProjectFilePath)")
            continue
        }

        if ($SkipProjectRegex.IsMatch($targetPath)) {
            $TimeLogger.ShowMessage("Skip import by regex: $($targetPath)")
            continue
        }

        if (-not $script:FoundImportTargets.Add($targetPath)) {
            # $TimeLogger.ShowMessage("Already handled imports: $($targetPath)")
            continue
        }

        if (-not $targetPath.ToLower().StartsWith($RepoFolder.ToLower())) {
            $TimeLogger.ShowMessage("Stop tracing external target: $($targetPath) in $($ProjectFilePath)")
            continue
        }

        Build_Reference_Projects $targetPath
    }

    # find-nd -f "\.vcx?proj$" -x vcxproj -t Include -AC | nin nul ":\d+:\s*(<\w+\s+\w+)" -pd
    # 2336(88.32%): <ProjectReference Include
    # 302(11.42%): <QCustomProjectReference Include
    # 2( 0.08%): <ProjectReference Condition
    # 1( 0.04%): <QCustomInput Include
    $TimeLogger.ShowMessage("Searching referenced projects in $($ProjectFilePath)")
    $referencedProjectPaths = msr -p $ProjectFilePath -it "^\s*<\w*ProjectReference\s+\w+\s*=.*?\`"(.+?$SearchProjectReferencePattern).*" -o "\1" -PAC
    foreach ($refProjectPath in $referencedProjectPaths) {
        $refProjectPath = Get_Project_Path $refProjectPath $ProjectFilePath
        if (-not $refProjectPath) {
            continue
        }

        if ($SkipProjectRegex.IsMatch($refProjectPath)) {
            $TimeLogger.ShowMessage("Skip referenced project by regex: $($refProjectPath)")
            continue
        }

        if ($script:BuiltProjectPaths.Contains($refProjectPath)) {
            # $TimeLogger.ShowMessage("Already built project: $($refProjectPath)")
            continue
        }

        Build_Reference_Projects $refProjectPath
    }

    if ($ProjectFilePath -imatch $ExtensionPattern) {
        Add_Build_Command $ProjectFilePath
    }

    Pop-Location
}

function Build_One_Project {
    param (
        [Parameter(Mandatory = $true)][string] $ProjectFilePath
    )

    $ProjectFilePaths = msr -p $ProjectFilePath -f $ExtensionPattern -l -PAC
    foreach ($projectFile in $ProjectFilePaths) {
        Build_Reference_Projects $projectFile
    }
}

function Get_SearchDepth_for_Restoring_Message_Compile {
    param (
        [string] $RepoFolder,
        [int] $searchDepth = 3
    )

    msr -z $RepoFolder.TrimEnd($SysPathChar) -t "[\\/]+" -o "\n" -PAC | msr -H 0 -M
    $searchDepth += $LASTEXITCODE
    return $searchDepth
}

function Set-BuildToolEnv {
    $trackerExePath = $(Get-Command 'tracker.exe').Source
    if ([string]::IsNullOrEmpty($trackerExePath)) {
        Show-ErrorThrow "Not found tracker.exe in PATH, it should has been set by repo init."
    }

    Show-Message "Found tracker.exe: $($trackerExePath)"

    $windowsSdkDir = [System.Environment]::GetEnvironmentVariable('WindowsSdkDir', [System.EnvironmentVariableTarget]::Process)
    $parentToolFolder = [IO.Path]::GetDirectoryName($trackerExePath)
    while ([string]::IsNullOrEmpty($windowsSdkDir) -and -not [string]::IsNullOrEmpty($parentToolFolder)) {
        $folders = Get-ChildItem $parentToolFolder -Directory -Filter 'WindowsSdk*'
        if ($folders.Count -gt 1) {
            $windowsSdkDir = Join-Path $parentToolFolder ($folders | Where-Object { $_.Name -imatch 'core' } | ForEach-Object { $_.Name } | Select-Object -First 1)
        }
        elseif ($folders.Count -eq 1) {
            $windowsSdkDir = Join-Path $parentToolFolder $folders[0].Name
        }
        else {
            $parentToolFolder = [IO.Path]::GetDirectoryName($parentToolFolder)
        }
    }

    $script:CompileTargetConfigFile = msr -rp "$RepoFolder/private/packages,$RepoFolder" -l -f "^MessageCompile.targets$" -d '^package' -k 7 -H 1 -J -PAC 2>$null
    if ([string]::IsNullOrEmpty($script:CompileTargetConfigFile)) {
        Show-Error "Not found MessageCompile.targets in $($RepoFolder)"
        return
    }

    $archConfig = msr -p $script:CompileTargetConfigFile -it "^\s*<MessageCompileToolArchitecture.*?>\s*(\w+\S+)\s*<.*" -o "\1" -PAC
    $archPattern = if ($archConfig -match '32') { '^x86' } else { '^(x64|amd64)' }
    Show-Message "Found mc-arch = $($archConfig) in $($script:CompileTargetConfigFile)"
    $mcExePath = msr -rp $windowsSdkDir -l -f '^mc.exe$' -d $archPattern -PAC
    if ([string]::IsNullOrEmpty($mcExePath)) {
        Show-ErrorThrow "Not found mc.exe in WindowsSdkDir: $($windowsSdkDir)"
    }

    Show-Message "Found mc.exe: $($mcExePath) in WindowsSdkDir: $($windowsSdkDir)"
    $mcExeDir = [IO.Path]::GetDirectoryName($mcExePath)
    $trackerExeDir = [IO.Path]::GetDirectoryName($trackerExePath)
    [System.Environment]::SetEnvironmentVariable('WindowsSdkDir', $windowSdkDir, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable('MessageCompileToolPath', $mcExeDir, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable('TrackerSdkPath', $trackerExeDir, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable('MessageCompileTrackerSdkPath', $trackerExeDir, [System.EnvironmentVariableTarget]::Process)
}

$exitCode = 0
Init_One_SubModules_Env $MapSubModuleToEnvFile $RepoFolder -IsTopProject $true -ReadEnv $true
Set-BuildToolEnv
foreach ($project in $InputProjectPaths) {
    Build_One_Project $project
}

Show-Info "Got $($AllBuildCommands.Count) build commands, checked $($script:ProjectCount) projects, time cost = $($TimeLogger.GetElapse())."

if ($OnlyShowCommands) {
    $AllBuildCommands
}
elseif ($AllBuildCommands.Count -gt 0) {
    $executeArgs = if ($ContinueOnBuildError) { @() } else { @("-V", "ne0") }
    $AllBuildCommands | msr -X $executeArgs
    if ($LASTEXITCODE -ne 0) {
        $exitCode = -1
    }
}

$TimeLogger.Dispose()
exit $exitCode
