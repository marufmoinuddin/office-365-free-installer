# Office Installer GUI

A Windows desktop GUI — written entirely in **PowerShell + WPF** — that is a
front-end for Microsoft's official **Office Deployment Tool (ODT)**.

The GUI's only job is to generate a valid ODT `configuration.xml` and call
`setup.exe` with the correct switches. It does **not** perform any licensing,
activation, or license-conversion logic. All Office files come directly from
Microsoft's CDN when you click Download or Install.

> **Note:** This tool installs Office using the official Office Deployment Tool.
> You are responsible for having a valid license for the products you install.

## Features

- ✅ Tabbed WPF GUI (`OfficeInstallerGUI.ps1` + `MainWindow.xaml`)
- ✅ Install / Uninstall Office via `setup.exe /configure`
- ✅ Download an offline source package via `setup.exe /download`
- ✅ Create an ISO from a downloaded source (IMAPI2, or `oscdimg` from the ADK)
- ✅ Read-only "Check Installed Status" (registry query, no changes)
- ✅ Dark / light theme toggle that persists across restarts
- ✅ Live console panel showing ODT's own log output as it streams
- ✅ Long-running operations run off the UI thread — the window never freezes
- ✅ Elevation (UAC) is only requested when Install/Uninstall is clicked
- ✅ No external modules, no NuGet, no telemetry

## Requirements

- Windows 10 / 11
- PowerShell 5.1+ (built into Windows) and .NET Framework (WPF, already present)
- Internet connection (to download the ODT and Office files from Microsoft)
- Administrator privileges (requested automatically, only when needed)

## Quick Start

### Option A — One-line launch (no cloning)

Open **PowerShell** and run:

```powershell
irm https://raw.githubusercontent.com/marufmoinuddin/office-365-free-installer/main/bootstrap.ps1 | iex
```

This downloads `OfficeInstallerGUI.ps1` and `MainWindow.xaml` into
`%LOCALAPPDATA%\OfficeInstallerGUI\app` and launches the GUI from there. No
administrator rights are needed to launch it — the GUI requests elevation only
when you click Install/Uninstall.

### Option B — From the repository

1. Download or clone this repository.
2. Double-click **`OfficeInstallerGUI.ps1`** (or right-click → **Run with
   PowerShell**).
3. Use the **Install** tab to pick an edition, architecture, channel, languages
   and apps, then click **Install Office**.
4. Use the **Download / Offline Package** tab to fetch an offline source and
   optionally build an ISO from it.

> `MainWindow.xaml` must stay in the same folder as `OfficeInstallerGUI.ps1`.
> If it's missing, the script falls back to an identical inline copy.

## The three tabs

### Install
- **Edition** — Microsoft 365 Apps for enterprise/business, Office LTSC
  2021/2024 (Volume), Office 2019 (Volume).
- **Architecture** — 64-bit (x64) or 32-bit (x86).
- **Individual apps** — toggle to install standalone products (Word, Excel,
  Project, Visio, OneDrive, …) instead of a full suite. A year selector picks
  the 2019/2021 Project/Visio volume IDs.
- **Applications** — suite mode: uncheck apps to emit `<ExcludeApp>` entries.
  Teams, Lync and Groove are unchecked by default (they're separate/legacy
  installs).
- **Channel** — the seven official ODT channel values.
- **Languages** — multi-select list; `en-US` is checked by default.
- **Use offline source** — install from a folder you downloaded on the
  Download tab (adds `SourcePath` to the config).
- **Install Office / Uninstall Office / Check Installed Status**.

### Download / Offline Package
- Same edition / architecture / channel / language selections as the Install
  tab (kept in sync automatically).
- **Destination folder** for the downloaded source files.
- **Download Office (offline source)** — runs `setup.exe /download`.
- **Create ISO from downloaded source** — enabled after a successful download.
- **Console** — live, auto-scrolling log of ODT's output.

### About / Settings
- App description and a link to the official ODT documentation.
- Local paths where `setup.exe` and logs are cached.
- Optional (hidden by default) **KMS host activation** section for
  organizations that run their own KMS host under a real Volume Licensing
  agreement — it only calls Microsoft's own `ospp.vbs`; it does not inject
  keys or convert channels.

## How it works

1. `OfficeInstallerGUI.ps1` loads `MainWindow.xaml` and shows the window.
2. When you click an action, it builds a `configuration.xml` from your
   selections using `[xml]` element creation (never string concatenation).
3. It ensures the ODT `setup.exe` is present in
   `%LOCALAPPDATA%\OfficeInstallerGUI\ODT`, downloading it from Microsoft's
   official download page (`id=49117`) and extracting it with the ODT
   installer's own `/extract:` switch if needed.
4. It runs `setup.exe /configure <config>.xml` (install/uninstall) or
   `setup.exe /download <config>.xml` (offline source) in a background
   runspace, tailing ODT's own log under `%temp%\OfficeLogs` into the console.
5. After a successful download you can build an ISO from the source folder.

### Keeping the ODT download URL current

Microsoft's direct ODT download link changes with every release. The GUI
resolves the current URL live from Microsoft's download page at runtime, and if
that fails it falls back to `tools/odt-url.txt` in this repository. A GitHub
Actions workflow (`.github/workflows/update-odt.yml`) re-resolves that URL from
Microsoft's page weekly and commits any change, so the fallback is never stale.

## Troubleshooting

See [docs/FAQ.md](docs/FAQ.md) for common issues.

## License

[MIT](LICENSE)