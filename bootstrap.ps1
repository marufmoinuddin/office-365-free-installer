#Requires -Version 5.1
<#
.SYNOPSIS
    One-line bootstrap for the Office Installer GUI.

.DESCRIPTION
    Downloads OfficeInstallerGUI.ps1 and MainWindow.xaml from this repository
    into a local app folder (%LOCALAPPDATA%\OfficeInstallerGUI\app) and launches
    the GUI from there.

    Running the GUI from a real file (not a pipeline) means $PSScriptRoot is set,
    MainWindow.xaml is co-located, and the GUI can re-launch itself elevated when
    you click Install/Uninstall.

    Usage (no cloning required):
        irm https://raw.githubusercontent.com/marufmoinuddin/office-365-free-installer/main/bootstrap.ps1 | iex

.NOTES
    No administrator rights are needed to run this bootstrap. The GUI requests
    elevation itself, and only when you actually click Install/Uninstall.
#>

$ErrorActionPreference = 'Stop'

# Force TLS 1.2 for older Windows (Windows 7 / Server 2008 R2 default to TLS 1.0/1.1,
# which the download servers reject). Must be set before any web request.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$RawBase = 'https://raw.githubusercontent.com/marufmoinuddin/office-365-free-installer/main'
$AppDir  = Join-Path $env:LOCALAPPDATA 'OfficeInstallerGUI\app'

New-Item -ItemType Directory -Force -Path $AppDir | Out-Null

# Files the GUI needs, kept together so the script can find MainWindow.xaml.
$files = @(
    @{ Name = 'OfficeInstallerGUI.ps1'; MinSize = 10KB },
    @{ Name = 'MainWindow.xaml';        MinSize = 5KB }
)

foreach ($f in $files) {
    $dest = Join-Path $AppDir $f.Name
    try {
        Invoke-WebRequest -Uri "$RawBase/$($f.Name)" -OutFile $dest -UseBasicParsing -TimeoutSec 60
        # Sanity check: a truncated download would be tiny and would break the GUI.
        if ((Get-Item $dest).Length -lt $f.MinSize) {
            throw "Downloaded $($f.Name) is unexpectedly small ($((Get-Item $dest).Length) bytes)."
        }
    } catch {
        Write-Host "[ERROR] Failed to download $($f.Name): $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Check your internet connection and try again.' -ForegroundColor Yellow
        exit 1
    }
}

$gui = Join-Path $AppDir 'OfficeInstallerGUI.ps1'
Write-Host "Launching the Office Installer GUI from $AppDir ..." -ForegroundColor Cyan
Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$gui`"")