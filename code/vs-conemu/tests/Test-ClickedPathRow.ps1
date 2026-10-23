#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Open-ClickedPathRow-in-VisualStudio.ps1'
$tokens = $null
$parseErrors = $null
$syntax = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) {
    throw ($parseErrors | Out-String)
}
$functionAst = $syntax.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-FilePathRowColumn'
}, $true)
if (-not $functionAst) {
    throw 'File-path parser function was not found.'
}
$parserDefinition = [scriptblock]::Create($functionAst.Extent.Text)
$cases = @(
    @{ InputArgs = @('c:/opengit/msrTools/readme.md:2-100'); Expected = @('c:/opengit/msrTools/readme.md', 2, 0) }
    @{ InputArgs = @('C:/code/readme.md:2-100:23'); Expected = @('C:/code/readme.md', 2, 0) }
    @{ InputArgs = @('C:/code/readme.md:2-100 extra text'); Expected = @('C:/code/readme.md', 2, 0) }
    @{ InputArgs = @('C:/code/readme.md:2-100#section'); Expected = @('C:/code/readme.md', 2, 0) }
    @{ InputArgs = @('C:/code/readme.md:2-100-200'); Expected = @('C:/code/readme.md', 2, 0) }
    @{ InputArgs = @('C:\code\readme.md:2-100'); Expected = @('C:\code\readme.md', 2, 0) }
    @{ InputArgs = @('C:/code with spaces/readme.md:2-100'); Expected = @('C:/code with spaces/readme.md', 2, 0) }
    @{ InputArgs = @('docs/readme.md:2-100'); Expected = @('docs/readme.md', 2, 0) }
    @{ InputArgs = @('C:/code/readme.md:1-1'); Expected = @('C:/code/readme.md', 1, 0) }
    @{ InputArgs = @('100', 'C:/code/readme.md:2-100'); Expected = @('C:/code/readme.md', 2, 0) }
    @{ InputArgs = @('C:\code\my-code.cs', '100', '23'); Expected = @('C:\code\my-code.cs', 100, 23) }
    @{ InputArgs = @('C:\code\my-code.cs:100:23:'); Expected = @('C:\code\my-code.cs', 100, 23) }
    @{ InputArgs = @('C:\code\my-code.cs:100:'); Expected = @('C:\code\my-code.cs', 100, 0) }
    @{ InputArgs = @('C:\code\my-code.cs', '100'); Expected = @('C:\code\my-code.cs', 100, 0) }
    @{ InputArgs = @('C:\code\my-code.cs'); Expected = @('C:\code\my-code.cs', 0, 0) }
    @{ InputArgs = @('100', 'C:\code\my-code.cs'); Expected = @('C:\code\my-code.cs', 100, 0) }
    @{ InputArgs = @('100', 'C:\code\my-code.cs', '23'); Expected = @('C:\code\my-code.cs', 100, 23) }
    @{ InputArgs = @('C:/code/my-code.cs:100:23'); Expected = @('C:/code/my-code.cs', 100, 23) }
    @{ InputArgs = @('C:/code/my-code.cs:100'); Expected = @('C:/code/my-code.cs', 100, 0) }
    @{ InputArgs = @('C:/code with spaces/my-code.cs', '100', '23'); Expected = @('C:/code with spaces/my-code.cs', 100, 23) }
    @{ InputArgs = @('docs/my-code.cs', '100', '23'); Expected = @('docs/my-code.cs', 100, 23) }
    @{ InputArgs = @('C:/code/readme-2-100.md'); Expected = @('C:/code/readme-2-100.md', 0, 0) }
)
foreach ($testCase in $cases) {
    $inputArguments = $testCase.InputArgs
    $actual = @(& {
        param([string]$Arg1, [string]$Arg2, [string]$Arg3)
        . $parserDefinition
        Get-FilePathRowColumn
    } @inputArguments)
    $expected = $testCase.Expected
    if ($actual.Count -ne 3 -or $actual[0] -cne $expected[0] -or $actual[1] -ne $expected[1] -or $actual[2] -ne $expected[2]) {
        throw "Unexpected path/row/column for $($inputArguments | ConvertTo-Json -Compress): $($actual | ConvertTo-Json -Compress)"
    }
}
Write-Output "PASS: $($cases.Count) file-path parsing cases; no applications or terminal-cleanup functions were invoked."
