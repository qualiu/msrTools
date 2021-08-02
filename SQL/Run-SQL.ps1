<#
.SYNOPSIS
    Directly run SQL Server commands without heavy tools.
    Published/updated at: https://github.com/qualiu/msrTools

.DESCRIPTION
    Execute SQL Server query from command line or file.

.Parameter ConnectionString
    SQL Server connection string like: Server=tcp:xxx.database.windows.net,1433;Initial Catalog=xxx;...

.Parameter QueryOrFile
    Query or read query from file.
    Will auto replace "`" to "'" if from command line, to help passing args from CMD like:
        -QueryOrFile 'SELECT TOP 9 * FROM table WHERE column LIKE `%match%pattern%` AND timeColumn ^> `2021-07-30`;'

.Parameter CheckCount
    Maximum running count. -1 means endless.

.Parameter SleepIntervalSeconds
    Sleep interval in second if running multiple times.

.Parameter SaveLog
    Save log path.

.Parameter ClearLogAtFirst
    Clear log file before saving.

.Parameter ShowDetails
    Show details for debug, like connection string and query.

.EXAMPLE
    .\Run-SQL.ps1 'Server=tcp:xxx...'   -- this will get and show connection count.
    .\Run-SQL.ps1 'Server=tcp:xxx...' -QueryOrFile 'SELECT TOP 9 * FROM table WHERE column LIKE `%match%pattern%` AND timeColumn ^> `2021-07-30`;'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ConnectionString,
    [Parameter(Mandatory = $false)] [string] $QueryOrFile = "",
    [Parameter(Mandatory = $false)][int] $CheckCount = 1,
    [Parameter(Mandatory = $false)][double] $SleepIntervalSeconds = 30,
    [Parameter(Mandatory = $false)][string] $SaveLog = "$env:TEMP\run-sql-command-result.log",
    [switch] $ClearLogAtFirst,
    [switch] $ShowDetails
)

# Import-Module SQLPS

$Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding $False
$trimFlag = $([System.Text.RegularExpressions.RegexOptions]::Compiled -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)
$TrimRegex = New-Object System.Text.RegularExpressions.Regex("\s+$", $trimFlag)

$DefaultQuery = @"
SELECT DB_NAME(dbid) as DBName, COUNT(dbid) as NumberOfConnections, loginame as LoginName FROM sys.sysprocesses WHERE dbid > 0 GROUP BY dbid, loginame ORDER BY NumberOfConnections DESC
"@.Trim()

$Query = $DefaultQuery
$IsQueryFromFile = $false
if (-not [string]::IsNullOrEmpty($QueryOrFile)) {
    if ([IO.File]::Exists($QueryOrFile)) {
        $Query = Get-Content $QueryOrFile
        $IsQueryFromFile = $true
    } else {
        $Query = $QueryOrFile
    }
}

$Query = $Query.Trim()

if (-not [Regex]::IsMatch($ConnectionString, "\w+=")) {
    throw "Invalid connection string: $ConnectionString"
}

if (-not [string]::IsNullOrWhiteSpace($SaveLog)) {
    $folder = [IO.Path]::GetDirectoryName($SaveLog)
    if ($(-not [string]::IsNullOrEmpty($folder)) -and $(-not [IO.Directory]::Exists($folder))) {
        [IO.Directory]::CreateDirectory($folder)
    }
}

# To help passing single quotes args
if (-not $IsQueryFromFile) {
    $Query = $Query.Replace('`', "'")
}

if ($ShowDetails) {
    Write-Host "Connection = $ConnectionString"
    Write-Host "Query = $Query"
}

$ShouldWriteLog = -not [string]::IsNullOrWhiteSpace($SaveLog)
if ($ClearLogAtFirst -and $ShouldWriteLog -and [IO.File]::Exists($SaveLog)) {
    [IO.File]::Delete($SaveLog)
}

$SqlConnection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
$ServerName = [Regex]::Replace($SqlConnection.DataSource, "^(\w+:)?([^,]+)(,\d+)?", '$2').Replace('.database.windows.net', '')

$BeginLogMark = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
if ($ShouldWriteLog) {
    $text = if ($IsQueryFromFile) { $QueryOrFile } else { $Query }
    [IO.File]::AppendAllText($SaveLog, "`n$BeginLogMark $ServerName Query = $text", $Utf8NoBomEncoding)
}

function Get-ConnectionCount([int] $continuousErrors = 0, [int] $maxErrors = 3) {
    try {
        $sqlCmd = New-Object System.Data.SqlClient.SqlCommand($Query, $SqlConnection)
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter
        $adapter.SelectCommand = $sqlCmd

        $stopWatch = [System.Diagnostics.Stopwatch]::new()
        $stopWatch.Start()
        $dataset = New-Object System.Data.DataSet
        [void] $adapter.Fill($dataset)
        $stopWatch.Stop()
        $SqlConnection.Close()

        $now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        if ($ShouldWriteLog) {
            # $dataset.Tables | msr -S -t "\s+$" -o "`n" -PAC | Out-File -FilePath $SaveLog -Encoding 'utf8' -Append
            $text = $TrimRegex.Replace($($dataset.Tables | Out-String).Trim(), "")
            if (-not [string]::IsNullOrEmpty($text)) {
                [IO.File]::AppendAllText($SaveLog, "`n$text", $Utf8NoBomEncoding)
            }
        }

        foreach ($table in $dataset.Tables) {
            $table | Format-Table | Out-String -Stream | Write-Host
            $message = if ($Query -eq $DefaultQuery) {
                $sum = $($table | Measure-Object -Property NumberOfConnections -Sum).Sum
                "$ServerName total connection count = $sum"
            } else {
                "$ServerName result rows = $($table.Rows.Count)"
            }

            Write-Host "$now $message , query-cost = $($stopWatch.ElapsedMilliseconds) ms."
            if ($ShouldWriteLog) {
                [IO.File]::AppendAllText($SaveLog, "`n$now $message , query-cost = $($stopWatch.ElapsedMilliseconds) ms.`n", $Utf8NoBomEncoding)
            }
        }

        return $true
    } catch {
        $SqlConnection.Close()
        if ($continuousErrors -gt $maxErrors) {
            throw $_.Exception
        } else {
            Write-Error $_.Exception
        }

        return $false
    }
}

$continuousErrorCount = 0
for ($times=0; $times -lt $CheckCount -or $CheckCount -eq -1; $times+=1) {
    if ($(Get-ConnectionCount $continuousErrorCount)) {
        $continuousErrorCount = 0
    } else {
        $continuousErrorCount += 1
    }

    if ($($times+1) -lt $CheckCount -or $CheckCount -eq -1) {
        Start-Sleep -Seconds $SleepIntervalSeconds
    }
}

if ($ShouldWriteLog) {
    Write-Host -ForegroundColor Green "msr -p $SaveLog -b `"^$BeginLogMark`" -P -H -1 -T -1"
}

exit $continuousErrorCount
