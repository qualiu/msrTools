#/bin/sh
#===============================================
# Find and disable specified exe files in PATH
#===============================================

ThisDir="$( cd "$( dirname "$0" )" && pwd )"
source $ThisDir/check-download-tools.sh
if [ $? -ne 0 ]; then
    echo "Failed to call $ThisDir/check-download-tools.sh"
    exit -1
fi

if [ -z "$1" ]; then
    echo "Usage  : $0  ExeFilePattern     "| msr -aPA -e "$0\s+(\S+).*"
    echo "Example: $0  msr.exe            "| msr -aPA -e "$0\s+(\S+).*"
    echo "Example: $0  '^msr\.exe$'       "| msr -aPA -e "$0\s+(\S+).*"
    echo "Example: $0  '^(msr|nin)\.exe$' "| msr -aPA -e "$0\s+(\S+).*"
    exit -1
fi

ExeFilePattern=$1

# Dispaly files with pattern %1
msr -l -p "$PATH" -f $ExeFilePattern --wt --sz -M 2>/dev/null

if [ -f $ThisDir/tmp-disable-exe-path.sh ]; then
    rm $ThisDir/tmp-disable-exe-path.sh
fi

msr -l -p "$PATH" -f $ExeFilePattern -PAC 2>/dev/null | nin nul "^(.+)[\\/][^\\/]*$" -iuPAC | tr -d '\r' |
    while IFS= read -r exeDirectory ; do
        # msr -z "$PATH" -P -H 0
        export PATH=$(msr -z "$PATH" -it ":$exeDirectory:|$exeDirectory:|:$exeDirectory\s*$" -o ":" -aPAC)
        # msr -z "$PATH" -P -H 0
        msr -l -p "$PATH" -f $ExeFilePattern --wt --sz -M 2>/dev/null
        echo "export PATH=\"$PATH\"" > $ThisDir/tmp-disable-exe-path.sh
    done

if [ -f $ThisDir/tmp-disable-exe-path.sh ]; then
    echo "Please call: source $ThisDir/tmp-disable-exe-path.sh" # | msr -aPA -ie "source.*"
    source $ThisDir/tmp-disable-exe-path.sh
fi
