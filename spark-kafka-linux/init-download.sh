#!/bin/sh
ThisDir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
AppDir=$ThisDir/app
DownloadDir=$ThisDir/downloads
mkdir -p $AppDir $DownloadDir

scalaVersion=2.11
kafkaVersion=0.10.1.0
kafkaTarName=kafka_$scalaVersion-$kafkaVersion
kafkaFile=$kafkaTarName.tgz
kafkaTgz=$DownloadDir/$kafkaFile
kafkaRoot=$AppDir/$kafkaTarName

if [ ! -f $kafkaTgz ]; then
    wget http://www-eu.apache.org/dist/kafka/$kafkaVersion/$kafkaTarName.tgz -O $kafkaTgz
fi

if [ ! -f $kafkaRoot ]; then
    tar xf $kafkaTgz -C $AppDir
fi

zookeeperDataDir=$kafkaRoot/data/zookeeper
kafkaLogDir=$kafkaRoot/kafka-logs
kafkaConfigDir=$kafkaRoot/config

sh $ThisDir/../check-download-tools.sh
if [ $? -ne 0 ]; then
    echo "Failed to call $ThisDir/../check-download-tools.sh"
    exit -1
fi

msr -it "^(\s*dataDir)\s*=.*$" -o '$1="'$zookeeperDataDir'"' -p $kafkaConfigDir/zookeeper.properties -R -c
msr -it "^(\s*log.dirs)\s*=.*$" -o '$1="'$kafkaLogDir'"' -p $kafkaConfigDir/server.properties -R -c
msr -it "^(\s*num.partitions)\s*=.*$" -o '$1=2' -p $kafkaConfigDir/server.properties -R -c
