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

# Force TLS 1.2 for older Windows (Windows 7 / Server 2008 R2 default to TLS 1.0/1.1,
# which the download servers reject). Must be set before any web request.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# --- Repo / download settings ---
$RawBase      = 'https://raw.githubusercontent.com/marufmoinuddin/office-365-free-installer/main'
# ODT download sources (tried in order):
#  1. Dynamic URL from this repo's tools/odt-url.txt (auto-updated by GitHub Actions)
#  2. GitHub mirror - stable URL that always serves the latest uploaded setup.exe
#  3. Direct Microsoft link - pinned to a specific ODT version (last resort)
$OdtUrlFile   = "$RawBase/tools/odt-url.txt"
$OdtMirrorUrl = 'https://raw.githubusercontent.com/P1N2O/office-deployment-tool/main/setup.exe'
$OdtDirectUrl = 'https://download.microsoft.com/download/6c1eeb25-cf8b-41d9-8d0d-cc1dbc032140/officedeploymenttool_20228-20124.exe'

# --- Determine script root ---
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ConfigDir  = Join-Path $ScriptRoot 'config'
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
    if ($PSCommandPath) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") -Verb RunAs
    } else {
        # Running via irm | iex — save the script to a temp file and elevate that
        $tmpScript = Join-Path $env:TEMP 'office-installer.ps1'
        Invoke-WebRequest -Uri "$RawBase/install.ps1" -OutFile $tmpScript -UseBasicParsing
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$tmpScript`"") -Verb RunAs
    }
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

function Get-DynamicOdtUrl {
    # Read the current ODT URL maintained by the repo's GitHub Actions workflow
    try {
        $content = (Invoke-WebRequest -Uri $OdtUrlFile -UseBasicParsing -TimeoutSec 15).Content
        $url = ($content -split "\r?\n")[0].Trim()
        if ($url -match '^https://download\.microsoft\.com/.*\.exe$') { return $url }
    } catch { }
    return $null
}

function Ensure-Odt {
    if (Test-Path $OdtExe) { return $true }
    Write-Step 'Office Deployment Tool not found. Downloading the latest version...'
    $sources = @()
    $dynamic = Get-DynamicOdtUrl
    if ($dynamic) { $sources += $dynamic }
    $sources += $OdtMirrorUrl
    $sources += $OdtDirectUrl
    foreach ($url in $sources) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $OdtExe -UseBasicParsing
            $size = (Get-Item $OdtExe).Length
            if ($size -lt 1MB) {
                Write-Err "Download from $url was not a valid setup.exe (only $size bytes). Trying next source..."
                Remove-Item $OdtExe -Force -ErrorAction SilentlyContinue
                continue
            }
            Write-Ok "Downloaded to $OdtExe"
            return $true
        } catch {
            Write-Err "Failed to download from $url : $($_.Exception.Message)"
            Remove-Item $OdtExe -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Err 'All download sources failed. Check your internet connection and try again.'
    return $false
}

function Get-ConfigFile {
    param([string]$Name)
    $local = Join-Path $ConfigDir $Name
    if (Test-Path $local) { return $local }
    # Not present locally (running via irm | iex) — fetch just this file
    $tmp = Join-Path $env:TEMP $Name
    try {
        Invoke-WebRequest -Uri "$RawBase/config/$Name" -OutFile $tmp -UseBasicParsing
        return $tmp
    } catch {
        Write-Err "Failed to download config '$Name': $($_.Exception.Message)"
        return $null
    }
}

function Get-ScriptFile {
    param([string]$Name)
    $local = Join-Path $ScriptsDir $Name
    if (Test-Path $local) { return $local }
    $tmp = Join-Path $env:TEMP $Name
    try {
        Invoke-WebRequest -Uri "$RawBase/scripts/$Name" -OutFile $tmp -UseBasicParsing
        return $tmp
    } catch {
        Write-Err "Failed to download script '$Name': $($_.Exception.Message)"
        return $null
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
        '1' {
            $s = Get-ScriptFile 'OffScrubC2R.vbs'
            if ($s) { & cscript.exe '//nologo' $s }
        }
        '2' {
            $s = Get-ScriptFile 'OffScrub_O16msi.vbs'
            if ($s) { & cscript.exe '//nologo' $s }
        }
        '3' {
            $s = Get-ScriptFile 'OffScrub_O15msi.vbs'
            if ($s) { & cscript.exe '//nologo' $s }
        }
        '4' { return }
        default { Write-Host 'Invalid option.' -ForegroundColor Red }
    }
}

function Show-Menu {
    Clear-Host
    Write-Host ''
    Write-Host '  ============================================================================'
    Write-Host '                                 -+yddy:..``'
    Write-Host '                             `:ohddddmmh+++///:.'
    Write-Host '                          -+shhhddddddhs++++++++-'
    Write-Host '                        .shhhhhhhyo/-. `oooooooo:'
    Write-Host '                         :yyyhhy-`      .oooooooo:'
    Write-Host '                        :yyyyy/        .osssssss:'
    Write-Host '                        :yyyyy/        .ssssssss/'
    Write-Host '                        -ssssy/        .ssssssss/'
    Write-Host '                        -sssss/        .ssssssss/'
    Write-Host '                        -oosss:        .ssssssss/'
    Write-Host '                        -ooooo.        .ssssssss/'
    Write-Host '                        `//-.`         -ssssssss/'
    Write-Host '                            `osssssyyyyhssssssss/'
    Write-Host '                             .:osssyyyyhsssssso/`'
    Write-Host '                                `-+syyyo+/:-.``'
    Write-Host '                                   `````'
    Write-Host '  ============================================================================'
    Write-Host '    Office Installer'
    Write-Host '  ============================================================================='
    Write-Host ''
    Write-Host "    Architecture : $Arch-bit"
    Write-Host "    ODT          : $OdtExe"
    Write-Host ''
    Write-Host '    1) Install Office 365 - Full'
    Write-Host '    2) Install Office 365 - Minimal'
    Write-Host '    3) Install Office 365 - Custom'
    Write-Host '    4) Install Office 2019 Enterprise'
    Write-Host '    5) Install Visio + Project'
    Write-Host '    6) Uninstall Office'
    Write-Host '    7) Clean up Office leftovers (OffScrub)'
    Write-Host '    8) Download / Update Office Deployment Tool'
    Write-Host '    9) Exit'
    Write-Host ''
    return Read-Host '  Select an option'
}

# --- Custom install app catalog ---
$AppCatalog = @(
    @{ Name = 'Word';       Id = 'Word' },
    @{ Name = 'Excel';      Id = 'Excel' },
    @{ Name = 'PowerPoint'; Id = 'PowerPoint' },
    @{ Name = 'Outlook';    Id = 'Outlook' },
    @{ Name = 'OneNote';    Id = 'OneNote' },
    @{ Name = 'Access';     Id = 'Access' },
    @{ Name = 'Publisher';  Id = 'Publisher' },
    @{ Name = 'Teams';      Id = 'Teams' },
    @{ Name = 'OneDrive';   Id = 'OneDrive' },
    @{ Name = 'Groove';     Id = 'Groove' },
    @{ Name = 'Lync';       Id = 'Lync' }
)
$DefaultSelected = @('Word', 'Excel', 'PowerPoint')

function Show-CustomSelector {
    param([string]$Arch)
    $selected = @($DefaultSelected)
    $cfgPath = Join-Path $env:TEMP ("office365-custom-{0}.xml" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '  ============================================================'
        Write-Host '    Custom install - select Office apps'
        Write-Host '  ============================================================'
        Write-Host ''
        Write-Host '    Type the numbers of the apps to toggle them on/off.'
        Write-Host '    Press Enter with no input to start the install.'
        Write-Host ''
        for ($i = 0; $i -lt $AppCatalog.Count; $i++) {
            $app = $AppCatalog[$i]
            $mark = if ($selected -contains $app.Id) { '[x]' } else { '[ ]' }
            Write-Host ("    {0,2}) {1} {2}" -f ($i + 1), $mark, $app.Name)
        }
        Write-Host ''
        $input = Read-Host '  Toggle (e.g. 1 2 3 4)'
        if ([string]::IsNullOrWhiteSpace($input)) { break }
        foreach ($token in ($input -split '\s+')) {
            if ($token -match '^\d+$') {
                $idx = [int]$token - 1
                if ($idx -ge 0 -and $idx -lt $AppCatalog.Count) {
                    $id = $AppCatalog[$idx].Id
                    if ($selected -contains $id) {
                        $selected = @($selected | Where-Object { $_ -ne $id })
                    } else {
                        $selected += $id
                    }
                }
            }
        }
    }

    if ($selected.Count -eq 0) {
        Write-Err 'No apps selected. Aborting custom install.'
        return $null
    }

    $excluded = @($AppCatalog | Where-Object { $selected -notcontains $_.Id } | ForEach-Object { $_.Id })
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<Configuration>')
    [void]$sb.AppendLine("  <Add OfficeClientEdition=`"$Arch`" Channel=`"Current`" ForceUpgrade=`"True`" MigrateArch=`"True`">")
    [void]$sb.AppendLine('    <Product ID="O365ProPlusRetail">')
    [void]$sb.AppendLine('      <Language ID="en-us" />')
    foreach ($id in $excluded) {
        [void]$sb.AppendLine("      <ExcludeApp ID=`"$id`" />")
    }
    [void]$sb.AppendLine('    </Product>')
    [void]$sb.AppendLine('  </Add>')
    [void]$sb.AppendLine('  <Display Level="Full" AcceptEULA="TRUE" />')
    [void]$sb.AppendLine('  <Updates Enabled="TRUE" />')
    [void]$sb.AppendLine('  <RemoveMSI />')
    [void]$sb.AppendLine('</Configuration>')
    $sb.ToString() | Set-Content -Path $cfgPath -Encoding UTF8
    return $cfgPath
}

# --- Main loop ---
while ($true) {
    $choice = Show-Menu
    switch ($choice) {
        '1' {
            $name = if ($Arch -eq '32') { 'office365-x86-full.xml' } else { 'office365-full.xml' }
            $cfg = Get-ConfigFile $name
            if ($cfg) { Invoke-Install 'Office 365 (Full)' $cfg }
        }
        '2' {
            $name = if ($Arch -eq '32') { 'office365-x86-minimal.xml' } else { 'office365-minimal.xml' }
            $cfg = Get-ConfigFile $name
            if ($cfg) { Invoke-Install 'Office 365 (Minimal)' $cfg }
        }
        '3' {
            $cfg = Show-CustomSelector -Arch $Arch
            if ($cfg) {
                Invoke-Install 'Office 365 (Custom)' $cfg
                Remove-Item $cfg -Force -ErrorAction SilentlyContinue
            }
        }
        '4' {
            $cfg = Get-ConfigFile 'office2019-enterprise.xml'
            if ($cfg) { Invoke-Install 'Office 2019 Enterprise' $cfg }
        }
        '5' {
            $cfg = Get-ConfigFile 'visio-project.xml'
            if ($cfg) { Invoke-Install 'Visio + Project' $cfg }
        }
        '6' {
            $cfg = Get-ConfigFile 'uninstall.xml'
            if ($cfg) { Invoke-Install 'Office Uninstall' $cfg }
        }
        '7' { Show-CleanupMenu }
        '8' { if (Ensure-Odt) { Write-Ok "Office Deployment Tool is ready: $OdtExe" } }
        '9' {
            Write-Host 'Goodbye.'
            Stop-Transcript | Out-Null
            exit 0
        }
        default { Write-Host 'Invalid option.' -ForegroundColor Red }
    }
    Write-Host ''
    Read-Host 'Press Enter to continue'
}