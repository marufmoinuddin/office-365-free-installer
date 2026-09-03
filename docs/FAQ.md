# FAQ / Troubleshooting

## The installer asks for administrator rights — is that normal?
Yes. Installing Office requires administrator privileges. The GUI only requests
elevation when you click **Install Office** or **Uninstall Office** — browsing
the tabs and downloading an offline source never trigger a UAC prompt.

## The download of the Office Deployment Tool fails
- Check your internet connection.
- If you're behind a proxy/firewall, allow `go.microsoft.com` and
  `download.microsoft.com`.
- You can download the ODT manually and place `setup.exe` at
  `%LOCALAPPDATA%\OfficeInstallerGUI\ODT\setup.exe` — the GUI will use it.

## I get "Could not create SSL/TLS secure channel" when downloading
This happens on older Windows versions (Windows 7 / Server 2008 R2) that default
to TLS 1.0/1.1, while the download server requires TLS 1.2.

- The GUI forces TLS 1.2 automatically, so this should be fixed.
- If it still fails, install the latest Windows updates / root certificates
  (KB3140245 enables TLS 1.2 on Windows 7), then retry.

## Installation fails with an error
- Check the log file in `%LOCALAPPDATA%\OfficeInstallerGUI\Logs\`.
- Make sure no other Office installation is in progress.
- If you have an older Office version installed, uninstall it first
  (Control Panel → Programs) or use the **Uninstall Office** button.

## How do I change the language or channel?
Use the **Channel** dropdown and the **Languages** list on the **Install** tab
(or the matching controls on the **Download / Offline Package** tab — they stay
in sync). See the ODT documentation for valid values.

## Can I install 32-bit Office on a 64-bit system?
Yes. Select **32-bit (x86)** under Architecture on the **Install** tab.

## Does this activate Office?
No. This tool only installs Office using Microsoft's official deployment tool.
You must provide your own valid license (retail key, volume license, or
Microsoft 365 subscription) to activate the products.