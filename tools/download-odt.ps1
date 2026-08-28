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