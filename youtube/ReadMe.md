

# Step-1: Configure or Install PowerShell

Scripts in this folder requires PowerShell, run command below to configure or install it with **Admin**/**root**(`sudo`) role:
- Windows:
  - `powershell Set-ExecutionPolicy Unrestricted -Scope LocalMachine -Force`
- Linux/MacOS:
  - bash [install-powershell.sh](https://github.com/qualiu/msrTools/blob/master/common/install-powershell.sh)

# Step-2: Install Tools for Video + Audio

Run PowerShell command below:
- Windows:
  - `powershell` [./Install-Apps.ps1](https://github.com/qualiu/msrTools/blob/master/youtube/Install-Apps.ps1)
- Linux/MacOs:
  - `pwsh` [./Install-Apps.ps1](https://github.com/qualiu/msrTools/blob/master/youtube/Install-Apps.ps1)


# Check Usage + Examples

- Native Method
  - `powershell Get-Help ./Download-Video.ps1 -Examples`
  - `powershell Get-Help ./Download-Video.ps1 -Detailed`
  - `powershell Get-Help ./Download-Video.ps1 -Full`
- Additional Method
  - `powershell ./Download-Video.ps1 --help`
