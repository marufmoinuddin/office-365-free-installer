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

$OdtUrl = 'https://go.microsoft.com/fwlink/?linkid=626510'
$OutFile = Join-Path $PSScriptRoot 'setup.exe'

Write-Host 'Downloading the Office Deployment Tool...' -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri $OdtUrl -OutFile $OutFile -UseBasicParsing
    Write-Host "[OK] setup.exe is ready: $OutFile" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Download failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}