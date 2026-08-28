# FAQ / Troubleshooting

## The installer asks for administrator rights — is that normal?
Yes. Installing Office requires administrator privileges. The script
automatically re-launches itself with elevation when you accept the UAC prompt.

## The download of the Office Deployment Tool fails
- Check your internet connection.
- If you're behind a proxy/firewall, allow `go.microsoft.com`.
- You can download the ODT manually and place it at `tools\setup.exe`.

## Installation fails with an error
- Check the log file in `%TEMP%\OfficeInstaller\`.
- Make sure no other Office installation is in progress.
- If you have an older Office version installed, uninstall it first
  (Control Panel → Programs) or use the cleanup option (menu item 6).

## How do I change the language or channel?
Edit the matching file in `config/` and change the `<Language ID="..." />`
or `Channel="..."` attributes. See the ODT documentation for valid values.

## Can I install 32-bit Office on a 64-bit system?
Yes. Use the `office365-x86-*.xml` configs directly:
`setup.exe /configure config\office365-x86-full.xml`

## Does this activate Office?
No. This tool only installs Office using Microsoft's official deployment tool.
You must provide your own valid license (retail key, volume license, or
Microsoft 365 subscription) to activate the products.