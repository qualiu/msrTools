#!/bin/bash
ThisDir="$(dirname $(realpath "${BASH_SOURCE[0]}"))"
if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    echo "Usage: CheckFolder"
    echo "Example: ."
    exit 1
fi

CheckFolder=$1; [ -z "$CheckFolder" ] && CheckFolder=$PWD
CheckFolder="$(realpath "$CheckFolder")"
source $ThisDir/check-download-tools.sh || exit 1

while read -r line; do
    echo; echo "Checking $line"
    msr -z "$line" -t "^(.+?)[^/]+:\d+:\s*(.+)" -o "ls \$(realpath '\1\2')" -XMO -V ne0 || exit_error "Failed to check $line"
done < <(msr -rp $CheckFolder -f "\.sh$" -t ".*?\w+/(\.{2}/[\./\w-]+).*" -o "\1" -M -C)

show_info "$(date +'%F %T %z') Well checked all path references in $CheckFolder"
