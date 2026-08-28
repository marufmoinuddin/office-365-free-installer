# Office Installer

A clean, ODT-based installer for **Microsoft Office 365 / 2019** for Windows.

This project wraps Microsoft's official **Office Deployment Tool (ODT)** with a
simple menu-driven PowerShell script. It downloads the latest ODT automatically,
detects your system architecture, and installs Office from the Microsoft CDN.

> **Note:** This tool installs Office using the official Office Deployment Tool.
> You are responsible for having a valid license for the products you install.

## Features

- ✅ One-click menu-driven installer (`install.ps1`)
- ✅ One-line install via `irm | iex` — menu shows instantly, files fetched on demand
- ✅ Auto-downloads the latest Office Deployment Tool (no bundled binaries)
- ✅ Auto-detects 64-bit / 32-bit architecture
- ✅ Full, Minimal, Office 2019 Enterprise, and Visio + Project presets
- ✅ Uninstall and cleanup (Microsoft's official OffScrub scripts)
- ✅ Full logging to `%TEMP%\OfficeInstaller`
- ✅ Self-elevates to administrator automatically

## Requirements

- Windows 10 / 11 (Windows 7 SP1+ also works)
- PowerShell 3.0+ (built into Windows)
- Internet connection (to download the ODT and Office files)
- Administrator privileges (requested automatically)

## Quick Start

### Option A — One-line install (recommended)

Open **PowerShell** and run:

```powershell
irm https://raw.githubusercontent.com/marufmoinuddin/office-365-free-installer/main/install.ps1 | iex
```

The script shows the menu instantly and downloads only the files you choose.

### Option B — From the repository

1. Download or clone this repository.
2. Right-click **`install.ps1`** → **Run with PowerShell** (or run it from a terminal).
3. Accept the UAC prompt.
4. Choose an option from the menu.

## Usage

| Option | Description |
|--------|-------------|
| 1. Install Office 365 – Full | Word, Excel, PowerPoint, Outlook, OneNote, Access, Publisher |
| 2. Install Office 365 – Minimal | Word, Excel, PowerPoint only |
| 3. Install Office 365 – Custom | Pick apps yourself — toggle with numbers (e.g. `1 2 3 4`) |
| 4. Install Office 2019 Enterprise | ProPlus + Visio + Project (volume license) |
| 5. Install Visio + Project | Adds Visio/Project to an existing Office 365 install |
| 6. Uninstall Office | Removes all Click-to-Run Office products |
| 7. Clean up leftovers | Microsoft's official OffScrub scripts |
| 8. Download / Update ODT | Fetches the latest Office Deployment Tool |
| 9. Exit | — |

## How it works

1. `install.ps1` shows the menu instantly — nothing is downloaded up front.
2. It checks for administrator rights and elevates if needed.
3. It detects whether your system is 64-bit or 32-bit.
4. Only after you pick an option, it downloads what's needed:
   - the matching config from `config/` (or generates one for Custom),
   - the Office Deployment Tool (`tools\setup.exe`) if missing,
   - the OffScrub script only if you choose cleanup.
5. It runs `setup.exe /configure <config>.xml`.
6. Office is downloaded from the Microsoft CDN and installed.

## Configuration files

| File | Purpose |
|------|---------|
| `config/office365-full.xml` | Full Office 365 suite (64-bit) |
| `config/office365-minimal.xml` | Word/Excel/PowerPoint only (64-bit) |
| `config/office365-x86-full.xml` | Full Office 365 suite (32-bit) |
| `config/office365-x86-minimal.xml` | Word/Excel/PowerPoint only (32-bit) |
| `config/office2019-enterprise.xml` | Office 2019 ProPlus + Visio + Project (volume) |
| `config/visio-project.xml` | Visio + Project for Office 365 |
| `config/uninstall.xml` | Remove all Click-to-Run Office products |

You can edit these files to change channels, languages, or excluded apps.
See the [official ODT documentation](https://learn.microsoft.com/en-us/deployoffice/office-deployment-tool-configuration-options) for all options.

## Troubleshooting

See [docs/FAQ.md](docs/FAQ.md) for common issues.

## License

[MIT](LICENSE)
