<#
.SYNOPSIS
    Initialize test: downloading resources and configure.

.DESCRIPTION
    Check and download Kafka, Hadoop and Spark; Configure them to save data and log in itself directory.
    Will not overwrite each of them if there's already a version exists in $AppDir, except $ForceOverwriteConfig used.
    You can set environment variable ExtraDownloadRepository to avoid downloading from web.
    
.PARAMETER KafkaVersion
    Kafka version like 0.10.1.0 in http://archive.apache.org/dist/kafka/

.PARAMETER HadoopVersion
    Hadoop version like 2.7.3 in http://archive.apache.org/dist/hadoop/common/

.PARAMETER SparkVersion
    Spark version like 2.1.0 in http://archive.apache.org/dist/spark/

.PARAMETER ExtraDownloadRepository
    Local download repository directory, will use it if exist to avoid downloading from web.
    If not provided or not exists, will check environment variable of name: ExtraDownloadRepository.

.PARAMETER SkipSpark
    Skip downloading and configuring Spark if not need.

.PARAMETER SkipHadoop
    Skip downloading and configuring Hadoop if not need.
    
.PARAMETER ForceOverwriteConfig
    Usefull if you want to download another version and configure it, not skip if exists another version Kafka.
    
.EXAMPLE
    
#>

[CmdletBinding()]
param(
      [Parameter(Mandatory = $false)][string] $KafkaVersion = "0.10.1.0",
      [Parameter(Mandatory = $false)][string] $HadoopVersion = "2.7.3",
      [Parameter(Mandatory = $false)][string] $SparkVersion = "2.1.0",
      [Parameter(Mandatory = $false)][int] $KafkaPartitions = 1,
      [Parameter(Mandatory = $false)][AllowEmptyString()][string] $ExtraDownloadRepository = "",
      [Parameter(Mandatory = $false)][int] $ZookeeperPort = 2181,
      [Parameter(Mandatory = $false)][int] $KafkaPort = 9092,
      [Parameter(Mandatory = $false)][AllowEmptyString()][string] $HdfsHostIP = "localhost",
      [Parameter(Mandatory = $false)][int] $HdfsPort = 9000,
      [Parameter(Mandatory = $false)][int] $YarnResourceManagerPort = 8020,
      [Parameter(Mandatory = $false)][int] $YarnNodeManagerPort = 45454,
      [switch] $SkipSpark,
      [switch] $SkipHadoop,
      [switch] $ForceOverwriteConfig
      )

$scriptDirectory = Convert-Path $(Split-Path $PSCommandPath -Parent -Resolve)
if (! ($env:PATH -icontains $scriptDirectory)) {
    $env:PATH = $scriptDirectory + ";" + $env:PATH
}

if ([String]::IsNullOrEmpty($ExtraDownloadRepository) -or -not [IO.Directory]::exists($ExtraDownloadRepository)) {
    if(-not [String]::IsNullOrEmpty($env:ExtraDownloadRepository) -and [IO.Directory]::exists($env:ExtraDownloadRepository)) {
        $ExtraDownloadRepository = $env:ExtraDownloadRepository
    }
}

$ToolDir = Join-Path $scriptDirectory "tools"
$AppDir = Join-Path $scriptDirectory "app"
$DownloadsDir = Join-Path $scriptDirectory "downloads"
$WinutilsExeName = "winutils.exe"
$WinutilsExeDownloadPath = Join-Path $DownloadsDir $WinutilsExeName

$SparkDist = "http://archive.apache.org/dist/spark/"
$HadoopDist = "http://archive.apache.org/dist/hadoop/common/"
$KafkaDist = "https://archive.apache.org/dist/kafka/"
$Home7z = "http://www.7-zip.org/download.html"
$App7zDir = Join-Path $AppDir "7z"
$App7zExe = Join-Path $App7zDir "7z.exe"

$HadoopWindowsBinaryUrl = "https://github.com/steveloughran/winutils/tree/master/hadoop-2.7.1/bin"
$HadoopWindowsBinaryDownloadDir = Join-Path $DownloadsDir "winutils"

$SparkDirectoryNamePattern = "^spark.*\d+.*hadoop.*\d+"
$HadoopDirectoryNamePattern = "^hadoop.*\d+"
$KafkaDirectoryNamePattern = "^kafka.*\d+"

$TarExe = (Get-Command tar.exe 2>$null).Source

function Check-Create-Directory($directory) {
    if (-not $(Test-Path $directory)) {
        New-Item $directory -ItemType Directory >$null
    }
}

Check-Create-Directory $ToolDir

if( -not $(Get-Command msr.exe > $null 2>$null) ) {
    if (-not $(Test-Path $(Join-Path $ToolDir msr.exe))) {
        Invoke-WebRequest -Uri https://github.com/qualiu/msr/blob/master/tools/msr.exe?raw=true -OutFile $(Join-Path $ToolDir msr.exe)
    }
    
    $env:PATH = $ToolDir + ";" + $env:PATH
}

$ipList = ipconfig | msr -it ".*IPv4.*\s+(\d+\.[\d\.]+\d+)\s*$" -o '$1' -PAC
$LocalIP = $ipList | where { $_ -match "192" }
if ([String]::IsNullOrEmpty($LocalIP)) {
    $LocalIP = $ipList[0]
}

if ([String]::IsNullOrEmpty($HdfsHostIP)) {
    $HdfsHostIP = $LocalIP
}

function Get-Kafka-Download-Url-FileName-DirectoryName() {
    # http://archive.apache.org/dist/kafka/ 0.10.2.1/kafka_2.10-0.10.2.1.tgz
    $folder = $KafkaVersion  # 0.10.2.1
    $dirName = "kafka_" + $SparkVersion.Substring(0, 2) + $SparkVersion.Substring(2).Replace(".", "") + "-$KafkaVersion"
    $name = $dirName + ".tgz"
    $url = $KafkaDist + $folder + "/" + $name
    Write-Host "Kafka web folder = $KafkaVersion, name = $name, url = $url"
    return $url, $name, $dirName
}

function Get-Spark-Download-Url-FileName-DirectoryName() {
    # http://archive.apache.org/dist/spark/ spark-2.1.0/spark-2.1.0-bin-hadoop2.7.tgz
    $folder = "spark-" + "$SparkVersion"  # spark-2.1.0
    $dirName = "spark-" + "$SparkVersion" + "-bin-hadoop" + $HadoopVersion.Substring(0, 3)
    $name = $dirName + ".tgz"
    $url = $SparkDist + $folder + "/" + $name
    Write-Host "Spark-Hadoop web folder = $folder, name = $name, url = $url"
    return $url, $name, $dirName
}

function Get-Hadoop-Download-Url-FileName-DirectoryName() {
    # http://archive.apache.org/dist/hadoop/common/hadoop-2.7.3/hadoop-2.7.3.tar.gz
    $folder = "hadoop-" + "$HadoopVersion"  # hadoop-2.7.3
    $name = $folder + ".tar.gz"
    $url = $HadoopDist + $folder + "/" + $name
    Write-Host "Hadoop web folder = $folder, name = $name, url = $url"
    return $url, $name, $folder
}

function Get-App-Directory($directoryNamePattern, $dirName = "") {
    if(-not [String]::IsNullOrEmpty($dirName)) {
        $directory = Join-Path $AppDir $dirName
        if (Test-Path -PathType Container $directory) {
            return $directory
        }
    }
    
    $dirName = $(Get-ChildItem -Directory $AppDir | where { $_.Name -imatch $directoryNamePattern } | Sort Name -Descending | Select -Last 1 Name).Name
    if([String]::IsNullOrEmpty($dirName)) {
        return ""
    }
    
    return $(Join-Path $AppDir $dirName)
}

function Copy-From-ExtraDownloadRepository($name, $savePath) {
    if([String]::IsNullOrEmpty($ExtraDownloadRepository) -or -not $(Test-Path $ExtraDownloadRepository)) {
        return $false
    }
    
    if (Test-Path $(Join-Path $ExtraDownloadRepository $name)) {
        Copy-Item $(Join-Path $ExtraDownloadRepository $name) $savePath
        return $true
    }
    
    foreach($dir in [IO.Directory]::GetDirectories($ExtraDownloadRepository)) {
        if (Test-Path $(Join-Path $dir $name)) {
            Copy-Item $(Join-Path $dir $name) $savePath
            return $true
        }
    }
    
    return $false
}

function Download-File($url, $saveDirectory, $name, $overwrite = $false) {
    $savePath = Join-Path $saveDirectory $name
    if(Test-Path $savePath){
        if($overwrite) {
            Remove-Item $savePath
        } else {
            Write-Host -ForegroundColor Yellow "Not download $name as existed : $savePath"
            return $savePath
        }
    }
    $tmpSavePath = $savePath + ".tmp"
    # Write-Host "Will save to $savePath"
    if (-not $(Copy-From-ExtraDownloadRepository $name $savePath)){
        Invoke-WebRequest -Uri $url -OutFile $tmpSavePath
        if(-not $(Test-Path $tmpSavePath)) {
        exit -1
        }
        Rename-Item $tmpSavePath $savePath
    }
    
    return $savePath
}


# Get Url and name for a file that will be downloaded.
function Get-Url-Name($toolName, $homePage, $pattern) {
    $page = Invoke-WebRequest $homePage
    $regex = New-Object System.Text.RegularExpressions.Regex($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $match = $regex.Match($page.RawContent)
    if(!$match.Success) {
        Write-Error "Cannot find $toolName in $homePage, please check version or pattern: $pattern"
        exit -1
    }

    $url = $match.Groups[1].Value + $match.Groups[2].Value
    $homeRoot = if($homePage -imatch "\w+\.\w+$") { $homePage -replace "[^/]+$",""} else { $homePage }
    if(-not $url.StartsWith($homePage.SubString(0,4))) {
        # Write-Host -ForegroundColor Green "Will add $homeRoot to $url"
        $url = $homeRoot + $url
    }
    
    $name = $match.Groups[2].Value

    return $url, $name
}

function Get-Installed-Directory($exeDirName, $exeName) {
    $programDirs = @("Program Files (x86)", "Program Files")
    foreach($driveInfo in [System.IO.DriveInfo]::GetDrives()) {
        foreach($dir in $programDirs) {
            $exeDir = [System.IO.Path]::Combine([System.IO.Path]::Combine($driveInfo.Name, $dir), $exeDirName)
            if(Test-Path $(Join-Path $exeDir $exeName)) {
                # Write-Host "Found $exeName in $exeDir"
                return $exeDir
            }
        }
    }
}

function Download-7z() {
    if ([IO.Directory]::Exists($App7zDir)) {
        $exe7z = [System.IO.Directory]::GetFiles($App7zDir, "7z*.exe")[0]
        if([IO.File]::Exists($exe7z)) {
            $env:PATH = $App7zDir + ";" + $env:PATH
            Write-Host -ForegroundColor Green "Already exists $exe7z"
            return
        } else {
            Write-Host -ForegroundColor Yellow "Will remove $App7zDir"
            Remove-Item -Recurse -Force $App7zDir
        }
    }

    $url, $name = Get-Url-Name "7z" $Home7z "<a href=`"(.*?/)?(7z[\w\.-]*\.zip)`">"
    $7zSavePath = Download-File $url $DownloadsDir $name
    
    # unzip -o $7zSavePath -d $App7zDir >$null
    Add-Type -A System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($7zSavePath, $App7zDir)

    $exe7z = [System.IO.Directory]::GetFiles($App7zDir, "7z*.exe")[0]
    
    if([System.IO.Path]::GetFileNameWithoutExtension($exe7z) -ine "7z") {
        Rename-Item $exe7z $App7zExe
    }
    
    $env:PATH = $App7zDir + ";" + $env:PATH
    $tool7z = $(Get-Command 7z.exe 2>$null).Source
    if([String]::IsNullOrEmpty($tool7z) -or ![IO.File]::Exists($tool7z)) {
        Write-Error "Not found 7z.exe in System nor $App7zDir. Please install 7-Zip"
        exit -1
    }
}


function Is-TarGz-File($file) {
    $file -imatch "\.(gz|tar|tgz)"
}

function Extract-ZipTarGz-By-Tar($tgzFile, $saveDirectory) {
    # & $TarExe xf $tgzFile -C $saveDirectory --overwrite
    $fileDir = [IO.Path]::GetDirectoryName($tgzFile)
    $fileName = [IO.Path]::GetFileName($tgzFile)
    Copy-Item -Path $tgzFile -Destination $saveDirectory

    Push-Location $saveDirectory
    & $TarExe xf $fileName --overwrite
    Remove-Item $fileName
    Pop-Location

    return

    $pureName = [IO.Path]::GetFileNameWithoutExtension($tgzFile) -ireplace ".tar",""

    $decompressedDir = Join-Path $fileDir $pureName

    if (![IO.Directory]::Exists($decompressedDir)) {
        Write-Error "Not exist $decompressedDir of $tgzFile"
        exit -1
    }

    robocopy $decompressedDir $( Join-Path $saveDirectory $pureName) /MOVE /E >$null
}

function Extract-ZipTarGz($tgzFile, $saveDirectory) {

    if(-not [String]::IsNullOrEmpty($TarExe) -and $(Is-TarGz-File $tgzFile) ) {
        # Write-Host "Will use tar to extract $tgzFile to $saveDirectory"
        # Extract-ZipTarGz-By-Tar $tgzFile $saveDirectory
        # return
    }
    
    Write-Host "Will use 7z to extract $tgzFile to $saveDirectory"
    $tool7z = $(Get-Command 7z.exe 2>$null).Source
    if([String]::IsNullOrEmpty($tool7z)) {
        $installed7zDir = Get-Installed-Directory "7-Zip" "7z.exe"
        if(![String]::IsNullOrEmpty($installed7zDir)) {
            $env:PATH = $installed7zDir + ";" + $env:PATH
            $tool7z = Join-Path $installed7zDir "7z.exe"
        } else {
            Download-7z
            $tool7z = Join-Path $App7zDir "7z.exe"
        }
    }
    
    if([String]::IsNullOrEmpty($tool7z)){
        $tool7z = $(Get-Command 7z.exe 2>$null).Source
    }
    Write-Host -ForegroundColor Green  "7z = $tool7z"
    if([String]::IsNullOrEmpty($tool7z)) {
        Write-Error "Not found 7z.exe"
        exit -1
    }

    #7z x $tgzFile -so | 7z -si x -aoa -ttar "-o$saveDirectory"
    7z -aoa x $tgzFile "-o$saveDirectory"

    $tarName = [IO.Path]::GetFileNameWithoutExtension($tgzFile)
    # $tarName = [Regex]::Replace($tarName, "\.tar$", "", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if(-not $tarName.EndsWith(".tar", [StringComparison]::OrdinalIgnoreCase)) {
        $tarName += ".tar"
    }

    $tarTmp = Join-Path $saveDirectory $tarName
    if(Test-Path $tarTmp) {
        7z -aoa x $tarTmp "-o$saveDirectory" >$null
        Remove-Item $tarTmp
    }
}

function Download-App-To-Directory($url, $saveDirectory, $name) {
    $savePath = Join-Path $saveDirectory $name

    if(Test-Path $savePath) {
        Write-Host -ForegroundColor Yellow "Will not download as existed: $savePath"
        return $savePath
    }

    Write-Host "Will download $url to $savePath"
    return Download-File $url $saveDirectory $name
}

function Update-Kafka-Settings($kafkaDir) {
    if (-not $(Test-Path $kafkaDir)) {
        Write-Error "Not exist kafka : $kafkaDir"
        exit -1
    }

    $myKafkaRootDir = Join-Path $kafkaDir "my"
    $zookeeperDataDir = Join-Path $(Join-Path $myKafkaRootDir "data") "zookeeper"
    $zookeeperDataDirReplace = $zookeeperDataDir -replace "\\","/"

    $kafkaLogDir = Join-Path $myKafkaRootDir "kafka-logs"
    $kafkaLogDirReplace = $kafkaLogDir -replace "\\","/"

    if (Test-Path $zookeeperDataDir) {
        Write-Host -ForegroundColor Yellow "Will clear zookeeper data directory: $zookeeperDataDir"
        Remove-Item -Recurse -Force $zookeeperDataDir
    }

    if (Test-Path $kafkaLogDir) {
        Write-Host -ForegroundColor Yellow "Will clear kafka log directory: $kafkaLogDir"
        Remove-Item -Recurse -Force $kafkaLogDir
    }

    # msr -it "set\s+LOG_DIR=" -x / -o "\\" -f "\.(bat|cmd)$" -rp $KafkaDirectory  -R -O -c To avoid first time warning
    
    $kafkaConfigDir = Join-Path $kafkaDir "config"
    msr -it "^(\s*dataDir)\s*=.*$" -o "`$1=$zookeeperDataDirReplace" -p $(Join-Path $kafkaConfigDir "zookeeper.properties") -R -c Set zookeeper dataDir = $zookeeperDataDir

    $kafkaServerConfigFile = $(Join-Path $kafkaConfigDir "server.properties")
    msr -it "^(\s*log.dirs)\s*=.*$" -o "`$1=$kafkaLogDirReplace" -p $kafkaServerConfigFile -R -c Set kafka log.dirs = $zookeeperDataDir
    
    msr -it "^(\s*num.partitions)\s*=.*$" -o "`$1=$KafkaPartitions" -p $kafkaServerConfigFile -R -c Set kafka num.partitions = $KafkaPartitions
    
    msr -rp $kafkaConfigDir -f properties -x 9092 -o $KafkaPort -R -c Replace kakfa port to $KafkaPort
    msr -rp $kafkaConfigDir -f properties -x 2181 -o $ZookeeperPort -R -c Replace zookeeper port to $ZookeeperPort
    msr -rp $kafkaConfigDir -f properties -it "^(\s*port)\s*=\s*(\d+)(.*)" -o "`$1=$KafkaPort`$3" -R -c Replace kafka port to $KafkaPort
    if ( $LASTEXITCODE -eq 0 ) {
        msr -rp $kafkaConfigDir -f properties -it "^(\s*port)\s*=\s*(\d+)(.*)"
        if ( $LASTEXITCODE -eq 0 ) {
            msr -rp $kafkaConfigDir -f properties -it "^(broker.id\s*=.+)" -o "`$0`nport=$KafkaPort" -R -c Add kafka port settings to $KafkaPort
        }
    }
    
    # msr -rp $kafkaConfigDir -f properties -it "^(\s*)#?(listeners)=\S+" -o "`$1`$2==PLAINTEXT://192.168.56.1:9292" -R -c Replace zookeeper port.
}

function Update-Or-Add-Setting($file, $findPattern, $replaceTo, $notFoundThenAdd="") {
     if(-not [IO.File]::Exists($file)) {
        Write-Error "Not exist file: $file"
        exit -1
     }
     $allText = [IO.File]::ReadAllText($file)
     $mode = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
     $reg = New-Object System.Text.RegularExpressions.Regex($findPattern, $mode)
     $newText = $allText = $reg.Replace($allText, $replaceTo)
     if(-not $newText.Equals($allText)) {
        [IO.File]::WriteAllText($file, $newText)
        Write-Host -ForegroundColor Green "Updated setting: $file"
     } elseif ($reg.IsMatch($allText)) {
        
     } elseif (-not [String]::IsNullOrEmpty($notFoundThenAdd)) {
        [IO.File]::AppendAllText($file, $notFoundThenAdd)
        Write-Host -ForegroundColor Green "Added setting to file: $file"
     } else {
        Write-Host -ForegroundColor Magenta "Not change/add to $file for pattern = $findPattern, replaceTo = $replaceTo, notFoundThenAdd = $notFoundThenAdd"
     }
}

function Check-Update-Config($file, $replaceTo, $checkExistPattern, $findPattern = "<configuration>.*?</configuration>"){
    if(-not [IO.File]::Exists($file)) {
        Write-Error "Not exist file: $file"
        exit -1
    }
    $allText = [IO.File]::ReadAllText($file)
    $mode = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
    $regExist = New-Object System.Text.RegularExpressions.Regex($checkExistPattern, $mode)
    if($regExist.IsMatch($allText) -and -not $ForceOverwriteConfig) {
        Write-Host -ForegroundColor Cyan "Not replace as file $file matched checkExistPattern: $checkExistPattern"
        return
    }
    $reg = New-Object System.Text.RegularExpressions.Regex($findPattern, $mode)
    $mc = $reg.Match($allText)
    if($mc.Success) {
        $allText = $allText.Remove($mc.Index, $mc.Length)
        $allText = $allText.Insert($mc.Index, $replaceTo)
        [IO.File]::WriteAllText($file, $allText)
        Write-Host -ForegroundColor Green "Updated file: $file"
    } else {
        Write-Host -ForegroundColor Yellow "Not update file: $file because not match: $findPattern"
    }
}

function Check-Copy-Template($file) {
    if (-not $(Test-Path $file)) {
        $templateFile = $file + ".template"
        if (Test-Path $templateFile) {
            Write-Host -ForegroundColor Green "Copy $templateFile $file"
            Copy-Item $templateFile $file
        }
    }
}

function Replace-Hadoop-Config-PlaceHolder($configContent, $myHadoopDataLogRootDirectory, $dirHolder = "my_hadoop_datalog_root_to_be_replaced") {
    $root = $myHadoopDataLogRootDirectory.Replace("\", "/")
    $configContent = $configContent.replace($dirHolder, "/" + $root)
    $configContent = $configContent.Replace("%USERNAME%", $env:USERNAME)
    return $configContent
}

function Update-Hadoop-Settings($hadoopDir) {
    if (-not $(Test-Path $hadoopDir)) {
        Write-Error "Not exist hadoop : $hadoopDir"
        exit -1
    }

    $myHadoopDataLogRootDirectory = Join-Path $hadoopDir "my"
    $hadoopConfigDirectory = Join-Path $(Join-Path $hadoopDir "etc") "hadoop"
    # hadoop-env.cmd
    $hadoop_env_cmd = Join-Path $hadoopConfigDirectory "hadoop-env.cmd"
    Update-Or-Add-Setting $hadoop_env_cmd "([\r\n]+\s*set\s+HADOOP_HOME)\s*=[^\r\n]*"  ('$1=' + $hadoopDir)  ("`nset HADOOP_HOME=" + $hadoopDir)
    Update-Or-Add-Setting $hadoop_env_cmd "([\r\n]+\s*set\s+HADOOP_CONF_DIR)\s*=[^\r\n]*" '$1=%HADOOP_HOME%\etc\hadoop' "`nset HADOOP_CONF_DIR=%HADOOP_HOME%\etc\hadoop"
    Update-Or-Add-Setting $hadoop_env_cmd "([\r\n]+\s*set\s+YARN_CONF_DIR)\s*=[^\r\n]*" '$1=%HADOOP_CONF_DIR%'  "`nset YARN_CONF_DIR=%HADOOP_CONF_DIR%"
    Update-Or-Add-Setting $hadoop_env_cmd "([\r\n]+\s*set\s+PATH)\s*=.*HADOOP_HOME[^\r\n]*" '$1=%PATH%;%HADOOP_HOME%\bin' "`nset PATH=%PATH%;%HADOOP_HOME%\bin"
    
    # core-site.xml
    $core_site_xml = Join-Path $hadoopConfigDirectory "core-site.xml"
    $configCoreSite = @"
<configuration>
  <property>
    <name>fs.default.name</name>
    <value>hdfs://${HdfsHostIP}:${HdfsPort}</value>
  </property>
  <property>
    <name>hadoop.tmp.dir</name>
    <value>my_hadoop_datalog_root_to_be_replaced/tmp</value>
  </property>
  
  <!-- Refresh proxyuser settings command: hdfs dfsadmin -refreshSuperUserGroupsConfiguration -->
  <property>
    <name>hadoop.proxyuser.qualiu.hosts</name>
    <value>*</value>
  </property>
  
  <property>
    <name>hadoop.proxyuser.qualiu.groups</name>
    <value>*</value>
  </property>
  
  <property>
    <name>hadoop.proxyuser.qualiu.users</name>
    <value>*</value>
  </property>
  
</configuration>
"@
    $configCoreSite = Replace-Hadoop-Config-PlaceHolder $configCoreSite $myHadoopDataLogRootDirectory
    Check-Update-Config $core_site_xml $configCoreSite "<name>\s*fs.default.name"

    # hdfs-site.xml
    $hdfs_site_xml = Join-Path $hadoopConfigDirectory "hdfs-site.xml"
    $configHdfsSite = @"
<configuration>
  <property>
    <name>dfs.replication</name>
    <value>1</value>
  </property>
   <property>
   <name>dfs.namenode.name.dir</name>
   <value>my_hadoop_datalog_root_to_be_replaced/namenode</value>
 </property>
 <property>
   <name>dfs.datanode.data.dir</name>
   <value>my_hadoop_datalog_root_to_be_replaced/datanode</value>
 </property>
</configuration>
"@
    $configHdfsSite = Replace-Hadoop-Config-PlaceHolder $configHdfsSite $myHadoopDataLogRootDirectory
    Check-Update-Config $hdfs_site_xml $configHdfsSite "<name>\s*dfs.replication"

    # mapred-site.xml
    $mapred_site_xml = Join-Path $hadoopConfigDirectory "mapred-site.xml"
    $configMapredSite = @"
<configuration>

   <property>
     <name>mapreduce.job.user.name</name>
     <value>%USERNAME%</value>
   </property>

   <property>
     <name>mapreduce.framework.name</name>
     <value>yarn</value>
   </property>

  <property>
    <name>yarn.apps.stagingDir</name>
    <value>my_hadoop_datalog_root_to_be_replaced/user/%USERNAME%/staging</value>
  </property>

  <property>
    <name>mapreduce.jobtracker.address</name>
    <value>local</value>
  </property>

</configuration>
"@
    $configMapredSite = Replace-Hadoop-Config-PlaceHolder $configMapredSite $myHadoopDataLogRootDirectory
    Check-Copy-Template $mapred_site_xml
    Check-Update-Config $mapred_site_xml $configMapredSite "<name>\s*mapreduce.job.user.name"

    # yarn-site.xml
    $yarn_site_xml = Join-Path $hadoopConfigDirectory "yarn-site.xml"
    $configYarnSite = @"
<configuration>
  <property>
    <name>yarn.server.resourcemanager.address</name>
    <value>${HdfsHostIP}:${YarnResourceManagerPort}</value>
  </property>

  <property>
    <name>yarn.server.resourcemanager.application.expiry.interval</name>
    <value>60000</value>
  </property>

  <property>
    <name>yarn.server.nodemanager.address</name>
    <value>${HdfsHostIP}:${YarnNodeManagerPort}</value>
  </property>

  <property>
    <name>yarn.nodemanager.aux-services</name>
    <value>mapreduce_shuffle</value>
  </property>

  <property>
    <name>yarn.nodemanager.aux-services.mapreduce.shuffle.class</name>
    <value>org.apache.hadoop.mapred.ShuffleHandler</value>
  </property>

  <property>
    <name>yarn.server.nodemanager.remote-app-log-dir</name>
    <value>my_hadoop_datalog_root_to_be_replaced/app-logs</value>
  </property>

  <property>
    <name>yarn.nodemanager.log-dirs</name>
    <value>my_hadoop_datalog_root_to_be_replaced/userlogs</value>
  </property>

  <property>
    <name>yarn.server.mapreduce-appmanager.attempt-listener.bindAddress</name>
    <value>${HdfsHostIP}</value>
  </property>

  <property>
    <name>yarn.server.mapreduce-appmanager.client-service.bindAddress</name>
    <value>${HdfsHostIP}</value>
  </property>

  <property>
    <name>yarn.log-aggregation-enable</name>
    <value>true</value>
  </property>

  <property>
    <name>yarn.log-aggregation.retain-seconds</name>
    <value>-1</value>
  </property>

  <property>
    <name>yarn.application.classpath</name>
    <value>%HADOOP_CONF_DIR%,%HADOOP_COMMON_HOME%/share/hadoop/common/*,%HADOOP_COMMON_HOME%/share/hadoop/common/lib/*,%HADOOP_HDFS_HOME%/share/hadoop/hdfs/*,%HADOOP_HDFS_HOME%/share/hadoop/hdfs/lib/*,%HADOOP_MAPRED_HOME%/share/hadoop/mapreduce/*,%HADOOP_MAPRED_HOME%/share/hadoop/mapreduce/lib/*,%HADOOP_YARN_HOME%/share/hadoop/yarn/*,%HADOOP_YARN_HOME%/share/hadoop/yarn/lib/*</value>
  </property>
</configuration>
"@
    Check-Copy-Template $yarn_site_xml
    $configYarnSite = Replace-Hadoop-Config-PlaceHolder $configYarnSite $myHadoopDataLogRootDirectory
    Check-Update-Config $yarn_site_xml $configYarnSite "<name>\s*yarn.server.resourcemanager.address"
    
    # dir /A:D /S /B test\app\hadoop-2.7.2 | msr --nt "(test|sources|examples)$|tomcat" -PAC
    # $jarLibPathes = ""
    # (Get-ChildItem -Recurse -Directory $hadoopDir |
    #    Where { $_.FullName -inotmatch "(test|sources|examples)$|tomcat" -and [IO.Directory]::GetFiles($_.FullName, "*.jar").Length -gt 0  }
    #    ).FullName | ForEach-Object -Process { $jarLibPathes += $_ + "\*" + "," }
    # $jarLibPathes = $jarLibPathes.TrimEnd(",")
}

function Init-Hadoop($hadoopDir, $isForceFormatNameNode = $false){
    if (-not $(Test-Path $hadoopDir)) {
        Write-Error "Not exist hadoop : $hadoopDir"
        exit -1
    }

    $hadoopBin = Join-Path $hadoopDir "bin"
    $haddopSbin = Join-Path $hadoopDir "sbin"
    # $env:PATH = $hadoopBin + ";" + $env:PATH
    $hdfs = Join-Path $hadoopBin "hdfs.cmd"
    $start_dfs = Join-Path $haddopSbin "start-dfs"
    $start_all = Join-Path $haddopSbin "start-all"
    # Start-Process $hdfs -ArgumentList "namenode -format" -Wait
    $oldPath = $env:PATH
    $env:PATH = $hadoopBin + ";" + $env:PATH
    $formatArg = if ($isForceFormatNameNode) { "-force" } else { "" }
    hdfs namenode -format -nonInteractive $formatArg
    $env:PATH = $oldPath
    # & $start_dfs
}

function Check-Download-Extract-App($url, $name, $appName, $appDirNamePattern) {
    $tgz = Download-App-To-Directory $url $DownloadsDir $name
    if([String]::IsNullOrEmpty($tgz)) {
        exit -1
    }
    
    $foundDir = Get-App-Directory $appDirNamePattern
    if ([String]::IsNullOrEmpty($foundDir)) {
        Extract-ZipTarGz $tgz $AppDir
    } else {
        Write-Host -ForegroundColor Yellow "Found existed $appName and not extract $tgz to overwrite: $foundDir"
    }
    
    $foundDir = Get-App-Directory $appDirNamePattern
    if (-not $(Test-Path $foundDir)) {
        Write-Host -ForegroundColor Red "Not exist $appName directory: $foundDir, search pattern = '$appDirNamePattern'"
        exit -1
    }

    return $directory
}

function Download-Hadoop-Windows-Binaries() {
    $files = [IO.Directory]::GetFiles($HadoopWindowsBinaryDownloadDir)  # Get-ChildItem -File $HadoopWindowsBinaryDownloadDir
    
    $page = Invoke-WebRequest $HadoopWindowsBinaryUrl
    $pattern = '<a.*?href=\"(.*?/winutils/blob/master/hadoop[^/]*/bin)/([^/\"]+)\"'
    $mode = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline
    $regex = New-Object System.Text.RegularExpressions.Regex($pattern, $mode)
    $matches = $regex.Matches($page.RawContent)
    if($matches.Count -lt 1) {
        Write-Error "Cannot find hadoop winutil files in $HadoopWindowsBinaryUrl, please check version or pattern: $pattern"
        exit -1
    }

    $totalFiles = $matches.Count
    
    if($files.Count -ge $matches.Count) {
        Write-Host -ForegroundColor Cyan "Already exists $totalFiles files in $HadoopWindowsBinaryDownloadDir"
        return
    }

    Write-Host -ForegroundColor Green "Downloading" $matches.Count "Hadoop winutils files save to $HadoopWindowsBinaryDownloadDir"
    $homePage = [System.Text.RegularExpressions.Regex]::Match($HadoopWindowsBinaryUrl, "^(\w*://[^/]+)").Value

    $number = 0
    foreach($match in $matches) {
        $number += 1
        # https://github.com/steveloughran/winutils/blob/master/hadoop-2.7.1/bin/datanode.exe?raw=true
        $url = $match.Groups[1].Value + "/" + $match.Groups[2].Value + "?raw=true"
        if(-not $url.StartsWith("http")) {
            $url = $homePage.TrimEnd("/") + "/" + $url.TrimStart("/")
        }
        $name = $match.Groups[2].Value
        Write-Host -ForegroundColor Green "Download Hadoop winutils[$number]-${totalFiles}: $name to $HadoopWindowsBinaryDownloadDir"
        $filePath = Download-File $url $HadoopWindowsBinaryDownloadDir $name
    }
}

Check-Create-Directory $AppDir
Check-Create-Directory $DownloadsDir
Check-Create-Directory $HadoopWindowsBinaryDownloadDir

$KafkaDirectory = Get-App-Directory $KafkaDirectoryNamePattern
$SparkDirectory = Get-App-Directory $SparkDirectoryNamePattern
$HadoopDirectory = Get-App-Directory $HadoopDirectoryNamePattern

if($ForceOverwriteConfig -or [String]::IsNullOrWhiteSpace($KafkaDirectory)) {
    $url, $name, $dirName = Get-Kafka-Download-Url-FileName-DirectoryName
    Write-Host "Kafka url = $url, name = $name"
    Check-Download-Extract-App $url $name "Kafka" $KafkaDirectoryNamePattern
    $KafkaDirectory = Get-App-Directory $KafkaDirectoryNamePattern $dirName
    Write-Host "KafkaDirectory = " -ForegroundColor Green $KafkaDirectory
    Update-Kafka-Settings $KafkaDirectory
}

if(($ForceOverwriteConfig -or [String]::IsNullOrWhiteSpace($SparkDirectory)) -and -not $SkipSpark) {
    $url, $name, $dirName = Get-Spark-Download-Url-FileName-DirectoryName
    Check-Download-Extract-App $url $name "Spark" $SparkDirectoryNamePattern $dirName
    $SparkDirectory = Get-App-Directory $SparkDirectoryNamePattern $dirName
    Write-Host "SparkDirectory = " -ForegroundColor Green $SparkDirectory
}

if(($ForceOverwriteConfig -or [String]::IsNullOrWhiteSpace($HadoopDirectory)) -and -not $SkipHadoop) {
    $url, $name, $dirName = Get-Hadoop-Download-Url-FileName-DirectoryName
    Check-Download-Extract-App $url $name "Hadoop" $HadoopDirectoryNamePattern $dirName
    $HadoopDirectory = Get-App-Directory $HadoopDirectoryNamePattern $dirName
    Write-Host "HadoopDirectory = " -ForegroundColor Green $HadoopDirectory

    $hadoopBin = Join-Path $HadoopDirectory "bin"
    Download-Hadoop-Windows-Binaries
    Copy-Item "$HadoopWindowsBinaryDownloadDir\*" $hadoopBin -Force
    Update-Hadoop-Settings $HadoopDirectory
    Init-Hadoop $HadoopDirectory $ForceOverwriteConfig
}

exit 0
