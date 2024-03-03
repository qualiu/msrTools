#!/bin/bash
if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    echo "Usage: [SaveDir: ~] [CleanEnvMSR: 0|1]  [ValidateTool: 0|1]"
    echo "Example: $0 ~"
    echo "Example: $0 /usr/bin/"
    echo "Example: $0 /usr/bin/ 1 1"
    exit 1
fi

SaveDir=$1 && [ -z "$SaveDir" ] && SaveDir=~
CleanEnvMSR=$2
ValidateTool=$3

ThisFolder=$(dirname $(realpath "${BASH_SOURCE[0]}"))
Md5File=$ThisFolder/md5.txt

[ "$CleanEnvMSR" != "1" ] && [ "$CleanEnvMSR" != "0" ] && CleanEnvMSR=1
[ "$ValidateTool" != "1" ] && [ "$ValidateTool" != "0" ] && ValidateTool=1

function show_error() {
    echo "$1" | GREP_COLOR='01;31' grep -E .+ --color=always 1>&2
}

function show_info() {
    echo "$1" | GREP_COLOR='01;32' grep -E .+ --color=always 1>&2
}

function show_warning() {
    echo "$1" | GREP_COLOR='01;33' grep -E .+ --color=always 1>&2
}

function exit_error() {
    show_error "$1"
    exit 1
}

SYS_ARCH=$(uname -m | awk '{print tolower($0)}')
SYS_TYPE=$(uname -s | sed 's/[_-].*//g' | awk '{print tolower($0)}')
DEFAULT_SUFFIX="-$SYS_ARCH.$SYS_TYPE"

if [ "$SYS_TYPE" == "darwin" ] || [ "$SYS_ARCH" == "aarch64" ] || [ "$DEFAULT_SUFFIX" == "-amd64.freebsd" ]; then
    toolSuffix=$DEFAULT_SUFFIX
elif [ "$SYS_TYPE" == "linux" ]; then
    if [ -n "$(echo "$SYS_ARCH" | grep -iE "i386|i686")" ]; then
        toolSuffix=-i386.gcc48
    else
        toolSuffix=.gcc48
    fi
elif [ "$SYS_TYPE" == "cygwin" ]; then
    toolSuffix=.cygwin
elif [ -n "$(echo "$SYS_TYPE" | grep -iE "MinGW")" ]; then
    toolSuffix=.exe
    echo "WARNING: MinGW is not fully supported: $0" | grep -E --color=always ".+" >&2
else
    exit_error "Unknown system type: $(uname -smr)"
    exit -1
fi

function validate_tool() {
    toolPath=$1
    toolName=$(basename $toolPath)
    # strings $(which $toolPath) | grep -E "COMPILE_HASH=\w+5599" >/dev/null && return 0
    toolMd5=$(md5sum $toolPath | awk '{print $1}')
    grep -E "$toolMd5 $toolName" $Md5File >/dev/null && return 0
    exit_error "[Security-Error]: Outdated or unknown version of $toolName in $toolPath with MD5 = $toolMd5, please update it or remove it to auto-download on $(hostname)."
}

function check_tool() {
    toolName=$1
    toolPath=$(which $toolName)
    if [ -f "$toolPath" ]; then
        # show_info "Skip downloading $toolName, already exists: $toolPath"
        validate_tool $toolPath || exit_error "Failed to validate $toolName: $toolPath"
        return 0
    fi

    toolPath=$SaveDir/$toolName
    if [ ! -f $SaveDir/$toolName ]; then
        curl --silent "https://raw.githubusercontent.com/qualiu/msr/master/tools/$toolName$toolSuffix" -o $toolPath.tmp && mv -f $toolPath.tmp $toolPath && chmod +x $toolPath
        if [ $? -ne 0 ] || [ ! -e $toolPath ]; then
            exit_error "Failed to download $toolName$toolSuffix"
        fi
    fi

    chmod +x $toolPath
    which $toolName > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        export PATH=$PATH:$SaveDir
        if [ -n "$(echo $SaveDir | grep -E '^/home/')" ]; then
            grep -E '^which msr.*?export PATH' ~/.bashrc >/dev/null || ( echo >> ~/.bashrc && echo 'which msr >/dev/null || export PATH="$PATH:~"' >> ~/.bashrc )
        fi
    fi
    validate_tool $toolPath || exit_error "Failed to validate $toolName: $toolPath"
}

check_tool msr || exit_error "Failed to get msr"
check_tool nin || exit_error "Failed to get nin"

if [ "$CleanEnvMSR" == "1" ]; then
    for name in $(printenv | msr -t "^(MSR_[A-Z_]+)=.*" -o "\1" -PAC); do
        # echo "Cleared env: $name=$(printenv $name)"
        unset $name
    done
fi
