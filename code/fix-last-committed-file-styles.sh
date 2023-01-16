#!/bin/sh
ThisDir="$( cd "$( dirname "$0" )" && pwd )"
which msr >/dev/null 2>&1 || source $ThisDir/../check-download-tools.sh || exit -1
msr -z "LostArg$1" -t "^LostArg(|-h|--help|/\?)$" > /dev/null
if [ $? -ne 0 ]; then
    echo "Usage  : $0 Is_Just_Show_Commands"
    echo "Example: $0 1"
    echo "Example: $0 0"
    exit -1
fi
Is_Just_Show_Commands=$1
FixStyleScript=$ThisDir/fix-file-style.sh
GitRepoRootDir=$(git rev-parse --show-toplevel)
otherArgs="-PAC"
if [ $Is_Just_Show_Commands -eq 0 ]; then
    otherArgs="-XM"
fi

git show head --name-only --stat=500 --oneline --pretty="format:" \
  | msr -t "(.+)" -o "sh $FixStyleScript '$GitRepoRootDir/\1'" --nt "\bmakefile\W{0,2}\s*$" $otherArgs
