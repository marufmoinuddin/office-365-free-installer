#Requires -Version 5.1
<#
.SYNOPSIS
    Office Installer - ODT-based installer for Microsoft Office 365 / 2019.

.DESCRIPTION
    Downloads the latest Office Deployment Tool (ODT), detects the system
    architecture, and installs Office from the Microsoft CDN through a
    menu-driven interface.

    Can be run directly from the repository, or bootstrapped with:
        irm https://raw.githubusercontent.com/marufmoinuddin/office-365-free-installer/main/install.ps1 | iex

.NOTES
    Requires an internet connection and administrator privileges.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# --- Repo / bootstrap settings ---
$RepoZipUrl = 'https://github.com/marufmoinuddin/office-365-free-installer/archive/refs/heads/main.zip'
$OdtUrl     = 'https://go.microsoft.com/fwlink/?linkid=626510'

# --- Determine script root ---
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ConfigDir  = Join-Path $ScriptRoot 'config'

# --- Bootstrap: if the config files are missing (e.g. running via irm | iex),
#     download the repository and re-run from the extracted copy. ---
if (-not (Test-Path (Join-Path $ConfigDir 'office365-full.xml'))) {
    Write-Host 'Downloading Office Installer...' -ForegroundColor Cyan
    $bootstrapDir = Join-Path $env:TEMP 'OfficeInstaller-Bootstrap'
    $zip          = Join-Path $bootstrapDir 'repo.zip'
    New-Item -ItemType Directory -Force -Path $bootstrapDir | Out-Null
    try {
        Invoke-WebRequest -Uri $RepoZipUrl -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $bootstrapDir -Force
    } catch {
        Write-Host "[ERROR] Failed to download the installer: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
    $extracted = Get-ChildItem $bootstrapDir -Directory |
                 Where-Object { $_.Name -like 'office-365-free-installer-*' } |
                 Select-Object -First 1
    if (-not $extracted) {
        Write-Host '[ERROR] Could not locate the extracted installer.' -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $extracted.FullName 'install.ps1')
    exit
}

# --- Paths ---
$ToolsDir   = Join-Path $ScriptRoot 'tools'
$ScriptsDir = Join-Path $ScriptRoot 'scripts'
$OdtExe     = Join-Path $ToolsDir 'setup.exe'
$LogDir     = Join-Path $env:TEMP 'OfficeInstaller'
$LogFile    = Join-Path $LogDir ("install-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

New-Item -ItemType Directory -Force -Path $LogDir, $ToolsDir | Out-Null

# --- Self-elevate to administrator ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Requesting administrator privileges...' -ForegroundColor Yellow
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") -Verb RunAs
    exit
}

# --- Detect architecture ---
$Arch = if ([Environment]::Is64BitOperatingSystem) { '64' } else { '32' }

# --- Logging ---
Start-Transcript -Path $LogFile -Append | Out-Null

# --- Helpers ---
function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Err  { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

function Ensure-Odt {
    if (Test-Path $OdtExe) { return $true }
    Write-Step 'Office Deployment Tool not found. Downloading the latest version...'
    try {
        Invoke-WebRequest -Uri $OdtUrl -OutFile $OdtExe -UseBasicParsing
        Write-Ok "Downloaded to $OdtExe"
        return $true
    } catch {
        Write-Err "Failed to download the Office Deployment Tool: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-Install {
    param([string]$Name, [string]$Config)
    if (-not (Ensure-Odt)) { return }
    if (-not (Test-Path $Config)) { Write-Err "Config file not found: $Config"; return }
    Write-Step "Installing $Name"
    Write-Host "  Config : $Config"
    Write-Host "  Log    : $LogFile"
    $p = Start-Process -FilePath $OdtExe -ArgumentList @('/configure', "`"$Config`"") -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -eq 0) { Write-Ok "$Name finished successfully." }
    else { Write-Err "$Name failed (exit code $($p.ExitCode)). See log: $LogFile" }
}

function Show-CleanupMenu {
    Clear-Host
    Write-Host ''
    Write-Host '  ============================================================'
    Write-Host '    Clean up leftover Office files (OffScrub)'
    Write-Host '  ============================================================'
    Write-Host ''
    Write-Host '    These are Microsoft official scripts for removing Office'
    Write-Host '    leftovers (files, licenses, registry entries).'
    Write-Host ''
    Write-Host '    1) Click-to-Run  (Office 2013/2016/2019/365)'
    Write-Host '    2) MSI - Office 2016'
    Write-Host '    3) MSI - Office 2013'
    Write-Host '    4) Back'
    Write-Host ''
    $choice = Read-Host '  Select an option'
    switch ($choice) {
        '1' { & cscript.exe '//nologo' (Join-Path $ScriptsDir 'OffScrubC2R.vbs') }
        '2' { & cscript.exe '//nologo' (Join-Path $ScriptsDir 'OffScrub_O16msi.vbs') }
        '3' { & cscript.exe '//nologo' (Join-Path $ScriptsDir 'OffScrub_O15msi.vbs') }
        '4' { return }
        default { Write-Host 'Invalid option.' -ForegroundColor Red }
    }
}

function Show-Menu {
    Clear-Host
    Write-Host ''
    Write-Host '  ============================================================'
    Write-Host '    Office Installer'
    Write-Host '  ============================================================'
    Write-Host ''
    Write-Host "    Architecture : $Arch-bit"
    Write-Host "    ODT          : $OdtExe"
    Write-Host ''
    Write-Host '    1) Install Office 365 - Full'
    Write-Host '    2) Install Office 365 - Minimal'
    Write-Host '    3) Install Office 2019 Enterprise'
    Write-Host '    4) Install Visio + Project'
    Write-Host '    5) Uninstall Office'
    Write-Host '    6) Clean up Office leftovers (OffScrub)'
    Write-Host '    7) Download / Update Office Deployment Tool'
    Write-Host '    8) Exit'
    Write-Host ''
    return Read-Host '  Select an option'
}

# --- Main loop ---
while ($true) {
    $choice = Show-Menu
    switch ($choice) {
        '1' {
            $cfg = if ($Arch -eq '32') { Join-Path $ConfigDir 'office365-x86-full.xml' } else { Join-Path $ConfigDir 'office365-full.xml' }
            Invoke-Install 'Office 365 (Full)' $cfg
        }
        '2' {
            $cfg = if ($Arch -eq '32') { Join-Path $ConfigDir 'office365-x86-minimal.xml' } else { Join-Path $ConfigDir 'office365-minimal.xml' }
            Invoke-Install 'Office 365 (Minimal)' $cfg
        }
        '3' { Invoke-Install 'Office 2019 Enterprise' (Join-Path $ConfigDir 'office2019-enterprise.xml') }
        '4' { Invoke-Install 'Visio + Project' (Join-Path $ConfigDir 'visio-project.xml') }
        '5' { Invoke-Install 'Office Uninstall' (Join-Path $ConfigDir 'uninstall.xml') }
        '6' { Show-CleanupMenu }
        '7' { if (Ensure-Odt) { Write-Ok "Office Deployment Tool is ready: $OdtExe" } }
        '8' {
            Write-Host 'Goodbye.'
            Stop-Transcript | Out-Null
            exit 0
        }
        default { Write-Host 'Invalid option.' -ForegroundColor Red }
    }
    Write-Host ''
    Read-Host 'Press Enter to continue'
}