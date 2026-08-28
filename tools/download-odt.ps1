#Requires -Version 5.1
<#
.SYNOPSIS
    Download the latest Office Deployment Tool (ODT).
.DESCRIPTION
    Downloads the ODT from Microsoft and saves it as setup.exe in this folder.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Force TLS 1.2 for older Windows (Windows 7 / Server 2008 R2 default to TLS 1.0/1.1,
# which the download servers reject). Must be set before any web request.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ODT download sources (tried in order):
#  1. Dynamic URL from this repo's tools/odt-url.txt (auto-updated by GitHub Actions)
#  2. GitHub mirror - stable URL that always serves the latest uploaded setup.exe
#  3. Direct Microsoft link - pinned to a specific ODT version (last resort)
$OdtUrlFile   = 'https://raw.githubusercontent.com/marufmoinuddin/office-365-free-installer/main/tools/odt-url.txt'
$OdtMirrorUrl = 'https://raw.githubusercontent.com/P1N2O/office-deployment-tool/main/setup.exe'
$OdtDirectUrl = 'https://download.microsoft.com/download/6c1eeb25-cf8b-41d9-8d0d-cc1dbc032140/officedeploymenttool_20228-20124.exe'
$OutFile = Join-Path $PSScriptRoot 'setup.exe'

function Get-DynamicOdtUrl {
    try {
        $content = (Invoke-WebRequest -Uri $OdtUrlFile -UseBasicParsing -TimeoutSec 15).Content
        $url = ($content -split "\r?\n")[0].Trim()
        if ($url -match '^https://download\.microsoft\.com/.*\.exe$') { return $url }
    } catch { }
    return $null
}

Write-Host 'Downloading the Office Deployment Tool...' -ForegroundColor Cyan
$sources = @()
$dynamic = Get-DynamicOdtUrl
if ($dynamic) { $sources += $dynamic }
$sources += $OdtMirrorUrl
$sources += $OdtDirectUrl
foreach ($url in $sources) {
    try {
        Invoke-WebRequest -Uri $url -OutFile $OutFile -UseBasicParsing
        $size = (Get-Item $OutFile).Length
        if ($size -lt 1MB) {
            Write-Host "[WARN] Download from $url was not a valid setup.exe (only $size bytes). Trying next source..." -ForegroundColor Yellow
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
            continue
        }
        Write-Host "[OK] setup.exe is ready: $OutFile" -ForegroundColor Green
        exit 0
    } catch {
        Write-Host "[WARN] Failed to download from $url : $($_.Exception.Message)" -ForegroundColor Yellow
        Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
    }
}
Write-Host '[ERROR] All download sources failed. Check your internet connection and try again.' -ForegroundColor Red
exit 1