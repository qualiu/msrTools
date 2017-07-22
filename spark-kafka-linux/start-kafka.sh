#!/bin/sh
ThisDir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

sh $ThisDir/../check-download-tools.sh
if [ $? -ne 0 ]; then
    echo "Failed to call $ThisDir/../check-download-tools.sh"
    exit -1
fi

kafkaRoot=$ThisDir/$(ls -d */ | msr -t "(kafka.+)/$" -o '$1' -PAC -T 1)
kafkaBin=$kafkaRoot/bin
kafkaConfigDir=$kafkaRoot/config

echo $kafkaBin/zookeeper-server-start.sh $kafkaConfigDir/zookeeper.properties | msr -aPA -ie "zookeeper\S+"
$kafkaBin/zookeeper-server-start.sh $kafkaConfigDir/zookeeper.properties &

for oneConfig in $(ls $kafkaConfigDir | grep server.*propert\S+ ); do
    echo $kafkaBin/kafka-server-start.sh $kafkaConfigDir/$oneConfig | msr -aPA -ie "kafka-server-start|server.*propert\S+"
    $kafkaBin/kafka-server-start.sh $kafkaConfigDir/$oneConfig &
done
