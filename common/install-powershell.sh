#!/bin/bash
# This script installs PowerShell for Linux / MacOS, which probably no built-in PowerShell.
# For Windows, run command with Admin role: powershell Set-ExecutionPolicy Unrestricted -Scope LocalMachine -Force

function show_error() {
    echo "$(date +'%F %T %z') $1" | GREP_COLOR='01;31' grep -E .+ --color=always 1>&2
}

function show_info() {
    echo "$(date +'%F %T %z') $1" | GREP_COLOR='01;32' grep -E .+ --color=always
}

function show_warning() {
    echo "$(date +'%F %T %z') $1" | GREP_COLOR='01;33' grep -E .+ --color=always
}

function exit_error() {
    show_error "$1"
    exit 1
}

which pwsh
if [ $? -eq 0 ]; then
    show_info "Already installed PowerShell as above."
    exit 0
fi

SYS_ARCH=$(uname -m)
SYS_TYPE=$(uname -s | sed 's/_.*//g' | awk '{print tolower($0)}')

if [ "$SYS_TYPE" == "darwin" ]; then
    show_info "Will install PowerShell, follow: https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-macos"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    brew install --cask powershell
    which pwsh
    exit $?
fi

if [ "$SYS_TYPE" != "linux" ]; then
    show_error "Please install PowerShell follow: https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux"
    exit -1
fi

# OS_VERSION=$(cat /etc/*release | grep -ioP '(DISTRIB_RELEASE=|VERSION_ID=")\K[\d\.]+' | head -n 1)
OS_VERSION=$(cat /etc/*release | grep -i -E '^(DISTRIB_RELEASE|VERSION_ID)=' | sed -E 's/.*?\b([0-9]+\.[0-9]+).*/\1/' | head -n 1)
OS_NAME=$(cat /etc/os-release | grep -i -E '^ID=' | sed 's/ID=//i')
if [ "$OS_NAME" == "ubuntu" ]; then
    show_info "Will install PowerShell, follow: https://docs.microsoft.com/en-us/powershell/scripting/install/install-ubuntu"
    sudo apt-get update -y
    sudo apt-get install -y wget apt-transport-https software-properties-common
    wget -q "https://packages.microsoft.com/config/ubuntu/$OS_VERSION/packages-microsoft-prod.deb"
    sudo dpkg -i packages-microsoft-prod.deb
    sudo apt-get update -y
    sudo apt-get install -y powershell
    rm -f packages-microsoft-prod.deb
elif [ "$OS_NAME" == "centos" ]; then
    show_info "will install PowerShell, follow: https://docs.microsoft.com/en-us/powershell/scripting/install/install-centos"
    curl https://packages.microsoft.com/config/rhel/$OS_VERSION/prod.repo | sudo tee /etc/yum.repos.d/microsoft.repo
    sudo yum install -y powershell
elif [ "$OS_NAME" == "fedora" ]; then
    show_info "Will install PowerShell, follow: https://docs.microsoft.com/en-us/powershell/scripting/install/install-fedora"
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    curl https://packages.microsoft.com/config/rhel/$OS_VERSION/prod.repo | sudo tee /etc/yum.repos.d/microsoft.repo
    sudo dnf check-update
    sudo dnf install -y compat-openssl10
    sudo dnf install -y powershell
else
    show_error "Please install PowerShell follow: https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux"
    exit -1
fi
