#Requires -Version 5.1
<#
.SYNOPSIS
    Office Installer GUI — a WPF front-end for Microsoft's official Office Deployment Tool (ODT).

.DESCRIPTION
    This script loads MainWindow.xaml (next to this file) and presents a tabbed
    WPF window that lets you:

      * Install / Uninstall Office (via setup.exe /configure <config.xml>)
      * Download an offline source package (via setup.exe /download <config.xml>)
      * Build an ISO from a downloaded source folder (IMAPI2 or oscdimg)
      * Check what Click-to-Run Office products are installed (read-only)

    It does NOT perform any licensing, activation, or license-conversion logic.
    It only generates a valid ODT configuration.xml and invokes setup.exe.
    All Office files come directly from Microsoft's CDN.

    Runs on a stock Windows 10/11 machine with only PowerShell 5.1+ and .NET
    Framework. No external modules, no NuGet, no internet dependency except
    reaching Microsoft's own domains.

.NOTES
    Author   : Office Installer GUI
    Requires : Windows 10/11, PowerShell 5.1+, .NET Framework (WPF)
    Elevation: Only requested when Install/Uninstall is actually clicked.
#>

[CmdletBinding()]
param(
    # Used when the non-elevated instance relaunches itself elevated to finish
    # an install/uninstall the user already confirmed. The elevated instance
    # auto-runs the pending action after the window loads.
    [string]$PendingConfig,
    [string]$PendingAction
)

$ErrorActionPreference = 'Stop'

# Force TLS 1.2 for older Windows (Windows 7 / Server 2008 R2 default to TLS 1.0/1.1,
# which Microsoft's download servers reject). Must be set before any web request.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ============================================================================
# Constants & local paths
# ============================================================================
$script:AppName    = 'Office Installer GUI'
$script:AppVersion = '1.0.0'

# The only local persistence/cache locations used by this app. Everything else
# (setup.exe location, config temp path) is computed at runtime.
$script:AppRoot       = Join-Path $env:LOCALAPPDATA 'OfficeInstallerGUI'
$script:OdtCacheDir   = Join-Path $script:AppRoot 'ODT'
$script:LogDir        = Join-Path $script:AppRoot 'Logs'
$script:SettingsFile  = Join-Path $script:AppRoot 'settings.json'

# Microsoft's official ODT download page (id=49117). The actual .exe URL is
# resolved from this page at runtime — never hardcoded.
$script:OdtDownloadPage = 'https://www.microsoft.com/en-us/download/details.aspx?id=49117'
$script:OdtDocsUrl      = 'https://learn.microsoft.com/en-us/deployoffice/overview-office-deployment-tool'
$script:AdkDocsUrl      = 'https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install'

# Fallback ODT download URL, maintained by the repo's .github/workflows/update-odt.yml
# workflow (it re-resolves the URL from Microsoft's page weekly and commits it here).
# Used only if live page resolution fails — see Get-OdtSetupExe.
# NOTE (documented deviation): this is the only non-Microsoft network destination
# in the GUI. It contacts only this project's own GitHub repo, is used only as a
# fallback when Microsoft's page cannot be reached, and carries no telemetry.
# Added at the maintainer's request to make the ODT download more resilient.
$script:OdtUrlFile = 'https://raw.githubusercontent.com/marufmoinuddin/office-365-free-installer/main/tools/odt-url.txt'

# Where ODT writes its own logs (matches the <Logging Path="%temp%\OfficeLogs" />
# element we emit in generated configs). We tail this directory live.
$script:OdtLogDir = Join-Path $env:TEMP 'OfficeLogs'

New-Item -ItemType Directory -Force -Path $script:AppRoot, $script:OdtCacheDir, $script:LogDir | Out-Null

# ============================================================================
# Reference data — exact ODT values from the spec. Do not invent IDs.
# ============================================================================

# Section 1.2 — Edition dropdown (label on the left, ODT Product ID on the right).
$script:Editions = @(
    @{ Name = 'Microsoft 365 Apps for enterprise'; Id = 'O365ProPlusRetail' },
    @{ Name = 'Microsoft 365 Apps for business';   Id = 'O365BusinessRetail' },
    @{ Name = 'Office LTSC ProPlus 2024 (Volume)'; Id = 'ProPlus2024Volume' },
    @{ Name = 'Office LTSC Standard 2024 (Volume)'; Id = 'Standard2024Volume' },
    @{ Name = 'Office LTSC Professional Plus 2021 (Volume)'; Id = 'ProPlus2021Volume' },
    @{ Name = 'Office LTSC Standard 2021 (Volume)'; Id = 'Standard2021Volume' },
    @{ Name = 'Office Professional Plus 2019 (Volume)'; Id = 'ProPlus2019Volume' },
    @{ Name = 'Office Standard 2019 (Volume)';      Id = 'Standard2019Volume' }
)

# Product Family groupings — a UI layer that filters the Edition dropdown.
$script:ProductFamilies = @(
    @{ Name = 'Microsoft 365';    Editions = @('O365ProPlusRetail', 'O365BusinessRetail') },
    @{ Name = 'Office LTSC 2024'; Editions = @('ProPlus2024Volume', 'Standard2024Volume') },
    @{ Name = 'Office LTSC 2021'; Editions = @('ProPlus2021Volume', 'Standard2021Volume') },
    @{ Name = 'Office 2019';      Editions = @('ProPlus2019Volume', 'Standard2019Volume') }
)

# Product Version presets (real ODT build numbers). 'CUSTOM' opens a manual entry
# in the Select Product Version dialog. The chosen version is written to the
# config as <Version>16.0.x.y</Version>.
$script:ProductVersions = @(
    @{ Name = 'Latest (default)';                 Id = '' },
    @{ Name = '16.0.20228.20186 — Windows 10/11'; Id = '16.0.20228.20186' },
    @{ Name = '16.0.15601.20538 — Windows 8/8.1'; Id = '16.0.15601.20538' },
    @{ Name = '16.0.12527.22286 — Windows 7';     Id = '16.0.12527.22286' }
)

# Section 1.5 — Channel dropdown. These are the seven official, documented ODT
# Channel values. We deliberately do NOT reproduce the extended/undocumented
# channel list seen in third-party tools (that comes from an internal Microsoft
# CDN branch-listing endpoint that isn't public API surface).
$script:Channels = @(
    @{ Name = 'Current Channel (Monthly, fastest updates)'; Id = 'Current' },
    @{ Name = 'Monthly Enterprise Channel';                  Id = 'MonthlyEnterprise' },
    @{ Name = 'Semi-Annual Enterprise Channel';              Id = 'SemiAnnual' },
    @{ Name = 'Semi-Annual Enterprise Channel (Preview)';    Id = 'SemiAnnualPreview' },
    @{ Name = 'LTSC 2019 Volume';                            Id = 'PerpetualVL2019' },
    @{ Name = 'LTSC 2021 Volume';                            Id = 'PerpetualVL2021' },
    @{ Name = 'LTSC 2024 Volume';                            Id = 'PerpetualVL2024' }
)

# Section 1.4 — Suite app checklist. Checked = include, unchecked = emit
# <ExcludeApp ID="..."/>.
# Sane defaults (documented here): Teams, Lync and Groove are unchecked by
# default because Teams/OneDrive are separate installs these days and Lync/
# Groove are legacy Skype-for-Business / OneDrive-for-Business IDs.
$script:SuiteApps = @(
    @{ Name = 'Word';    Id = 'Word' },
    @{ Name = 'Excel';   Id = 'Excel' },
    @{ Name = 'Access';  Id = 'Access' },
    @{ Name = 'Outlook'; Id = 'Outlook' },
    @{ Name = 'OneNote'; Id = 'OneNote' },
    @{ Name = 'PowerPoint'; Id = 'PowerPoint' },
    @{ Name = 'Publisher';  Id = 'Publisher' },
    @{ Name = 'Teams';      Id = 'Teams' },
    @{ Name = 'Lync (Skype for Business)'; Id = 'Lync' },
    @{ Name = 'Groove (OneDrive for Business)'; Id = 'Groove' },
    @{ Name = 'OneDrive'; Id = 'OneDrive' }
)
$script:SuiteDefaultChecked = @('Word','Excel','Access','Outlook','OneNote','PowerPoint','Publisher','OneDrive')

# Section 1.3 — Individual ("Single Products") app IDs. Project/Visio IDs depend
# on the year selector ({Year} is replaced with 2021 or 2019 at config time).
$script:IndividualApps = @(
    @{ Name = 'Word';    Id = 'Word' },
    @{ Name = 'Excel';   Id = 'Excel' },
    @{ Name = 'Access';  Id = 'Access' },
    @{ Name = 'Outlook'; Id = 'Outlook' },
    @{ Name = 'OneNote'; Id = 'OneNote' },
    @{ Name = 'PowerPoint'; Id = 'PowerPoint' },
    @{ Name = 'Publisher';  Id = 'Publisher' },
    @{ Name = 'Project Professional'; Id = 'ProjectPro{Year}Volume' },
    @{ Name = 'Project Standard';     Id = 'ProjectStd{Year}Volume' },
    @{ Name = 'Visio Professional';   Id = 'VisioPro{Year}Volume' },
    @{ Name = 'Visio Standard';       Id = 'VisioStd{Year}Volume' },
    @{ Name = 'OneDrive'; Id = 'OneDriveRetail' }
)

# Section 1.6 — Language codes. en-US is checked by default.
$script:Languages = @(
    'en-US','ru-RU','uk-UA','ar-SA','bg-BG','cs-CZ','da-DK','de-DE','el-GR','es-ES',
    'et-EE','fi-FI','fr-FR','he-IL','hi-IN','hr-HR','hu-HU','id-ID','it-IT','ja-JP',
    'kk-KZ','ko-KR','lt-LT','lv-LV','nb-NO','nl-NL','pl-PL','pt-BR','pt-PT','ro-RO',
    'sk-SK','sl-SI','sr-latn-RS','sv-SE','th-TH','tr-TR','vi-VN','zh-CN','zh-TW'
) | Select-Object -Unique

# ============================================================================
# Global state
# ============================================================================
$script:Window            = $null
$script:PollTimer         = $null
$script:Settings          = @{ DarkTheme = $true }
$script:LastDownloadDest  = $null   # destination folder of the last successful download
$script:LastDownloadFolder = $null  # same as above; used to enable "Create ISO"
$script:SelectedVersion   = $null   # ODT product version (16.0.x.y) or $null for latest
$script:DownloadStartSize = 0       # folder size at download start (for speed calc)
$script:DownloadLastSize  = 0       # last sampled folder size
$script:DownloadLastTime  = $null   # last sample timestamp
$script:SyncingEdition    = $false  # guards against event recursion when syncing tabs
$script:SyncingArch       = $false
$script:SyncingChannel    = $false
$script:SyncingLanguages  = $false
$script:SyncingVersion    = $false
$script:LogTailState      = @{}     # file path -> last-read byte offset for log tailing

# Theme dictionary references. Captured once after the window loads because a
# ResourceDictionary has no .Key property, and once a dictionary is removed from
# MergedDictionaries it can no longer be found via the Resources indexer — so we
# must keep our own references to swap them reliably.
$script:DarkThemeDict  = $null
$script:LightThemeDict = $null

# Background job state. Long-running ODT/ISO work runs in a separate runspace so
# the WPF window never freezes. The runspace writes status lines into a
# thread-safe ConcurrentQueue; a DispatcherTimer on the UI thread drains it.
$script:Job = @{
    Running     = $false
    Kind        = $null      # 'install' | 'uninstall' | 'download' | 'iso'
    PowerShell  = $null
    AsyncResult = $null
    OutputQueue = $null
    OdtLogDir   = $null
}

# ============================================================================
# Inline XAML fallback
# ============================================================================
# MainWindow.xaml is loaded from the file next to this script. If that file is
# missing (e.g. someone copied only the .ps1), we fall back to this identical
# inline copy. Keep it in sync with MainWindow.xaml.
$script:InlineXaml = @'
<!--
  MainWindow.xaml — WPF UI for OfficeInstallerGUI.ps1
  ====================================================
  Loaded at runtime by OfficeInstallerGUI.ps1 (not compiled). Keep it in the
  same folder as the script; the script also embeds an identical inline copy.

  Layout follows the visual UI reference:
    Tab 1  Main Window            — product/edition, architecture, apps, channel, version
    Tab 2  Utilities and Settings — launch Office apps, diagnostics, log panel
    Tab 3  Download Office        — download with live progress, create ISO
    Tab 4  About                  — description, docs, paths, optional KMS

  Theme: two ResourceDictionaries (LightTheme / DarkTheme). The LAST dictionary
  in the merged collection wins, so DarkTheme (last) is the active default. The
  script swaps which one is active by re-ordering the collection; all themeable
  colors use {DynamicResource ...} so they re-resolve on swap.
-->
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="OfficeInstallerGUI"
        Height="780" Width="1040"
        MinHeight="540" MinWidth="720"
        WindowStartupLocation="CenterScreen"
        Background="{DynamicResource WindowBackground}"
        FontFamily="Segoe UI" FontSize="13"
        Foreground="{DynamicResource TextForeground}">
    <Window.Resources>
        <ResourceDictionary>
            <ResourceDictionary.MergedDictionaries>
                <!-- Light theme (defined first; DarkTheme below is the active default) -->
                <ResourceDictionary x:Key="LightTheme">
                    <SolidColorBrush x:Key="WindowBackground" Color="#F5F5F5"/>
                    <SolidColorBrush x:Key="PanelBackground" Color="#FFFFFF"/>
                    <SolidColorBrush x:Key="ControlBackground" Color="#FFFFFF"/>
                    <SolidColorBrush x:Key="ControlBorder" Color="#C8C8C8"/>
                    <SolidColorBrush x:Key="TextForeground" Color="#1E1E1E"/>
                    <SolidColorBrush x:Key="TextSecondary" Color="#555555"/>
                    <SolidColorBrush x:Key="AccentBrush" Color="#D24726"/>
                    <SolidColorBrush x:Key="AccentHover" Color="#E05A38"/>
                    <SolidColorBrush x:Key="LogBackground" Color="#FFFFFF"/>
                    <SolidColorBrush x:Key="LogText" Color="#1E1E1E"/>
                    <SolidColorBrush x:Key="ErrorText" Color="#C42B1C"/>
                    <SolidColorBrush x:Key="SuccessText" Color="#107C10"/>
                    <SolidColorBrush x:Key="WarningText" Color="#9D5D00"/>
                    <SolidColorBrush x:Key="TabBackground" Color="#FFFFFF"/>
                    <SolidColorBrush x:Key="TabSelected" Color="#F5F5F5"/>
                    <SolidColorBrush x:Key="HyperlinkBrush" Color="#0066CC"/>
                </ResourceDictionary>
                <!-- Dark theme (default) -->
                <ResourceDictionary x:Key="DarkTheme">
                    <SolidColorBrush x:Key="WindowBackground" Color="#1E1E1E"/>
                    <SolidColorBrush x:Key="PanelBackground" Color="#252526"/>
                    <SolidColorBrush x:Key="ControlBackground" Color="#333333"/>
                    <SolidColorBrush x:Key="ControlBorder" Color="#555555"/>
                    <SolidColorBrush x:Key="TextForeground" Color="#F0F0F0"/>
                    <SolidColorBrush x:Key="TextSecondary" Color="#A0A0A0"/>
                    <SolidColorBrush x:Key="AccentBrush" Color="#D24726"/>
                    <SolidColorBrush x:Key="AccentHover" Color="#E05A38"/>
                    <SolidColorBrush x:Key="LogBackground" Color="#1A1A1A"/>
                    <SolidColorBrush x:Key="LogText" Color="#D0D0D0"/>
                    <SolidColorBrush x:Key="ErrorText" Color="#F48771"/>
                    <SolidColorBrush x:Key="SuccessText" Color="#89D185"/>
                    <SolidColorBrush x:Key="WarningText" Color="#E2C08D"/>
                    <SolidColorBrush x:Key="TabBackground" Color="#252526"/>
                    <SolidColorBrush x:Key="TabSelected" Color="#1E1E1E"/>
                    <SolidColorBrush x:Key="HyperlinkBrush" Color="#4FC1FF"/>
                </ResourceDictionary>
            </ResourceDictionary.MergedDictionaries>

            <!-- Primary action button (orange accent) -->
            <Style x:Key="PrimaryButton" TargetType="Button">
                <Setter Property="Background" Value="{DynamicResource AccentBrush}"/>
                <Setter Property="Foreground" Value="White"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
                <Setter Property="Padding" Value="18,9"/>
                <Setter Property="Margin" Value="4"/>
                <Setter Property="BorderThickness" Value="0"/>
                <Setter Property="Cursor" Value="Hand"/>
                <Setter Property="Template">
                    <Setter.Value>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="bd" Property="Background" Value="{DynamicResource AccentHover}"/>
                                </Trigger>
                                <Trigger Property="IsEnabled" Value="False">
                                    <Setter TargetName="bd" Property="Opacity" Value="0.45"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Setter.Value>
                </Setter>
            </Style>

            <!-- Secondary action button (neutral) -->
            <Style x:Key="SecondaryButton" TargetType="Button">
                <Setter Property="Background" Value="{DynamicResource ControlBackground}"/>
                <Setter Property="Foreground" Value="{DynamicResource TextForeground}"/>
                <Setter Property="Padding" Value="14,8"/>
                <Setter Property="Margin" Value="4"/>
                <Setter Property="BorderThickness" Value="1"/>
                <Setter Property="BorderBrush" Value="{DynamicResource ControlBorder}"/>
                <Setter Property="Cursor" Value="Hand"/>
                <Setter Property="Template">
                    <Setter.Value>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="bd" Property="Background" Value="{DynamicResource AccentHover}"/>
                                    <Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
                                </Trigger>
                                <Trigger Property="IsEnabled" Value="False">
                                    <Setter TargetName="bd" Property="Opacity" Value="0.45"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Setter.Value>
                </Setter>
            </Style>

            <!-- Utility tile button (app launchers / diagnostics) -->
            <Style x:Key="UtilityButton" TargetType="Button" BasedOn="{StaticResource SecondaryButton}">
                <Setter Property="MinWidth" Value="120"/>
                <Setter Property="MinHeight" Value="40"/>
                <Setter Property="Margin" Value="4"/>
                <Setter Property="Padding" Value="10,6"/>
            </Style>

            <!-- Tab control / tab item styling -->
            <Style TargetType="TabControl">
                <Setter Property="Background" Value="{DynamicResource WindowBackground}"/>
                <Setter Property="BorderThickness" Value="0"/>
            </Style>
            <Style TargetType="TabItem">
                <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
                <Setter Property="Template">
                    <Setter.Value>
                        <ControlTemplate TargetType="TabItem">
                            <Border x:Name="bd" Background="{DynamicResource TabBackground}" BorderBrush="{DynamicResource ControlBorder}" BorderThickness="0,0,0,2" Padding="18,9">
                                <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsSelected" Value="True">
                                    <Setter TargetName="bd" Property="Background" Value="{DynamicResource TabSelected}"/>
                                    <Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
                                    <Setter Property="Foreground" Value="{DynamicResource TextForeground}"/>
                                </Trigger>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="bd" Property="Background" Value="{DynamicResource ControlBackground}"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Setter.Value>
                </Setter>
            </Style>

            <!-- Field label style -->
            <Style x:Key="FieldLabel" TargetType="TextBlock">
                <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
                <Setter Property="FontSize" Value="12"/>
                <Setter Property="Margin" Value="0,8,0,2"/>
            </Style>

            <!-- Section header style -->
            <Style x:Key="SectionHeader" TargetType="TextBlock">
                <Setter Property="Foreground" Value="{DynamicResource TextForeground}"/>
                <Setter Property="FontSize" Value="15"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
                <Setter Property="Margin" Value="0,10,0,4"/>
            </Style>
        </ResourceDictionary>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TabControl x:Name="MainTabs" Grid.Row="0">

            <!-- ================= TAB 1: MAIN WINDOW (Install) ================= -->
            <TabItem Header="Main Window">
                <Grid Margin="12">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="200"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <!-- Left column: branding + primary actions -->
                    <StackPanel Grid.Column="0" Margin="0,8,16,0">
                        <Border Width="110" Height="110" CornerRadius="18" Background="{DynamicResource AccentBrush}" HorizontalAlignment="Left">
                            <TextBlock Text="OFFICE" Foreground="White" FontSize="18" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <CheckBox x:Name="InstallOfflineCheck" Content="Use Offline Installation" Foreground="{DynamicResource TextForeground}" Margin="0,16,0,0"/>
                        <StackPanel x:Name="OfflineSourcePanel" Orientation="Horizontal" Margin="20,4,0,0" Visibility="Collapsed">
                            <TextBox x:Name="InstallOfflinePathBox" Width="130" Height="26" VerticalContentAlignment="Center" Background="{DynamicResource ControlBackground}" Foreground="{DynamicResource TextForeground}" BorderBrush="{DynamicResource ControlBorder}"/>
                            <Button x:Name="InstallOfflineBrowseBtn" Content="..." Style="{StaticResource SecondaryButton}" Padding="8,4" Margin="4,0,0,0"/>
                        </StackPanel>
                        <Button x:Name="InstallBtn" Content="Install Office" Style="{StaticResource PrimaryButton}" Margin="0,16,0,0" MinWidth="160"/>
                        <Button x:Name="UninstallBtn" Content="Uninstall Office" Style="{StaticResource SecondaryButton}" Margin="0,8,0,0" MinWidth="160"/>
                        <Button x:Name="StatusBtn" Content="Check Status" Style="{StaticResource SecondaryButton}" Margin="0,8,0,0" MinWidth="160"/>
                        <ProgressBar x:Name="InstallProgress" Height="6" IsIndeterminate="True" Visibility="Collapsed" Margin="4,12,4,0" Foreground="{DynamicResource AccentBrush}" Background="{DynamicResource ControlBackground}"/>
                    </StackPanel>

                    <!-- Right column: product configuration -->
                    <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto">
                        <StackPanel>
                            <TextBlock Text="Office Product" FontSize="16" FontWeight="Bold" Foreground="{DynamicResource TextForeground}"/>

                            <!-- Product Family + Architecture -->
                            <Grid Margin="0,8,0,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel>
                                    <TextBlock Text="Product Family" Style="{StaticResource FieldLabel}"/>
                                    <ComboBox x:Name="InstallFamilyCombo" Height="28" Background="{DynamicResource ControlBackground}" Foreground="{DynamicResource TextForeground}" BorderBrush="{DynamicResource ControlBorder}"/>
                                </StackPanel>
                                <StackPanel Grid.Column="1" Margin="24,0,0,0">
                                    <TextBlock Text="Architecture" Style="{StaticResource FieldLabel}"/>
                                    <StackPanel Orientation="Horizontal">
                                        <RadioButton x:Name="InstallArch64Radio" Content="x64" IsChecked="True" Foreground="{DynamicResource TextForeground}" Margin="0,0,20,0"/>
                                        <RadioButton x:Name="InstallArch32Radio" Content="x86" Foreground="{DynamicResource TextForeground}"/>
                                    </StackPanel>
                                </StackPanel>
                            </Grid>

                            <!-- Product / Edition + Single Products toggle -->
                            <Grid Margin="0,8,0,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel>
                                    <TextBlock Text="Product / Edition" Style="{StaticResource FieldLabel}"/>
                                    <ComboBox x:Name="InstallEditionCombo" Height="28" Background="{DynamicResource ControlBackground}" Foreground="{DynamicResource TextForeground}" BorderBrush="{DynamicResource ControlBorder}"/>
                                </StackPanel>
                                <CheckBox x:Name="InstallIndividualCheck" Content="Single Products" Grid.Column="1" Margin="24,26,0,0" Foreground="{DynamicResource TextForeground}"/>
                            </Grid>

                            <!-- Dual application checklists -->
                            <Grid Margin="0,8,0,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel>
                                    <TextBlock x:Name="SuiteLabel" Text="Suite Applications" Style="{StaticResource FieldLabel}"/>
                                    <Border x:Name="SuiteAppsBorder" BorderBrush="{DynamicResource ControlBorder}" BorderThickness="1" CornerRadius="4" Background="{DynamicResource ControlBackground}" Padding="6" MaxHeight="150">
                                        <ScrollViewer VerticalScrollBarVisibility="Auto">
                                            <ItemsControl x:Name="SuiteAppsList"/>
                                        </ScrollViewer>
                                    </Border>
                                </StackPanel>
                                <StackPanel Grid.Column="1" Margin="16,0,0,0">
                                    <TextBlock x:Name="SingleLabel" Text="Single Products" Style="{StaticResource FieldLabel}"/>
                                    <Border x:Name="IndividualAppsBorder" BorderBrush="{DynamicResource ControlBorder}" BorderThickness="1" CornerRadius="4" Background="{DynamicResource ControlBackground}" Padding="6" MaxHeight="150" Visibility="Collapsed">
                                        <ScrollViewer VerticalScrollBarVisibility="Auto">
                                            <ItemsControl x:Name="IndividualAppsList"/>
                                        </ScrollViewer>
                                    </Border>
                                </StackPanel>
                            </Grid>

                            <!-- Channel -->
                            <TextBlock Text="Channel" Style="{StaticResource FieldLabel}"/>
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <ComboBox x:Name="InstallChannelCombo" Height="28" Background="{DynamicResource ControlBackground}" Foreground="{DynamicResource TextForeground}" BorderBrush="{DynamicResource ControlBorder}"/>
                                <Button x:Name="ChannelInfoBtn" Content="?" Grid.Column="1" Margin="8,0,0,0" Style="{StaticResource SecondaryButton}" Padding="10,4" ToolTip="Show channel information"/>
                            </Grid>

                            <!-- Languages -->
                            <TextBlock Text="Languages" Style="{StaticResource FieldLabel}"/>
                            <Border BorderBrush="{DynamicResource ControlBorder}" BorderThickness="1" CornerRadius="4" Background="{DynamicResource ControlBackground}" Padding="6" MaxHeight="120">
                                <ScrollViewer VerticalScrollBarVisibility="Auto">
                                    <ItemsControl x:Name="InstallLanguagesList"/>
                                </ScrollViewer>
                            </Border>
                        </StackPanel>
                    </ScrollViewer>
                </Grid>
            </TabItem>

            <!-- ================= TAB 2: UTILITIES AND SETTINGS ================= -->
            <TabItem Header="Utilities and Settings">
                <Grid Margin="12">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto">
                        <StackPanel>
                            <TextBlock Text="Office Utilities" Style="{StaticResource SectionHeader}"/>
                            <UniformGrid Columns="4">
                                <Button x:Name="LaunchWordBtn" Content="Word" Style="{StaticResource UtilityButton}"/>
                                <Button x:Name="LaunchExcelBtn" Content="Excel" Style="{StaticResource UtilityButton}"/>
                                <Button x:Name="LaunchPowerPointBtn" Content="PowerPoint" Style="{StaticResource UtilityButton}"/>
                                <Button x:Name="LaunchOutlookBtn" Content="Outlook" Style="{StaticResource UtilityButton}"/>
                                <Button x:Name="LaunchOneNoteBtn" Content="OneNote" Style="{StaticResource UtilityButton}"/>
                                <Button x:Name="LaunchAccessBtn" Content="Access" Style="{StaticResource UtilityButton}"/>
                                <Button x:Name="LaunchPublisherBtn" Content="Publisher" Style="{StaticResource UtilityButton}"/>
                                <Button x:Name="LaunchProjectBtn" Content="Project" Style="{StaticResource UtilityButton}"/>
                                <Button x:Name="LaunchVisioBtn" Content="Visio" Style="{StaticResource UtilityButton}"/>
                            </UniformGrid>

                            <TextBlock Text="Office Diagnostics" Style="{StaticResource SectionHeader}"/>
                            <StackPanel Orientation="Horizontal">
                                <Button x:Name="CheckInstallBtn" Content="Check Installation" Style="{StaticResource UtilityButton}"/>
                                <Button x:Name="CheckOdtBtn" Content="Check ODT" Style="{StaticResource UtilityButton}"/>
                                <Button x:Name="OpenLogFolderBtn" Content="Open Log Folder" Style="{StaticResource UtilityButton}"/>
                                <Button x:Name="OpenDownloadFolderBtn" Content="Open Download Folder" Style="{StaticResource UtilityButton}"/>
                            </StackPanel>
                        </StackPanel>
                    </ScrollViewer>

                    <!-- Log / Output panel -->
                    <Grid Grid.Row="1" Margin="0,10,0,0">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <TextBlock Text="Log / Output" Style="{StaticResource FieldLabel}" Margin="0,0,0,4"/>
                        <RichTextBox x:Name="LogBox" Grid.Row="1" IsReadOnly="True" VerticalScrollBarVisibility="Auto" Background="{DynamicResource LogBackground}" Foreground="{DynamicResource LogText}" BorderBrush="{DynamicResource ControlBorder}" BorderThickness="1" FontFamily="Consolas" FontSize="12"/>
                    </Grid>
                </Grid>
            </TabItem>

            <!-- ================= TAB 3: DOWNLOAD OFFICE ================= -->
            <TabItem Header="Download Office">
                <Grid Margin="12">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto">
                        <StackPanel>
                            <TextBlock x:Name="DownloadVersionLabel" Text="Office Deployment Tool version: (not yet resolved)" Foreground="{DynamicResource TextSecondary}" FontSize="12" Margin="0,0,0,6"/>

                            <!-- Product + Architecture + Languages -->
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel>
                                    <TextBlock Text="Product" Style="{StaticResource FieldLabel}"/>
                                    <ComboBox x:Name="DownloadEditionCombo" Width="220" Height="28" Background="{DynamicResource ControlBackground}" Foreground="{DynamicResource TextForeground}" BorderBrush="{DynamicResource ControlBorder}"/>
                                </StackPanel>
                                <StackPanel Grid.Column="1" Margin="16,0,0,0">
                                    <TextBlock Text="Architecture" Style="{StaticResource FieldLabel}"/>
                                    <ComboBox x:Name="DownloadArchCombo" Width="90" Height="28" Background="{DynamicResource ControlBackground}" Foreground="{DynamicResource TextForeground}" BorderBrush="{DynamicResource ControlBorder}"/>
                                </StackPanel>
                                <StackPanel Grid.Column="2" Margin="16,0,0,0">
                                    <TextBlock Text="Languages" Style="{StaticResource FieldLabel}"/>
                                    <Border BorderBrush="{DynamicResource ControlBorder}" BorderThickness="1" CornerRadius="4" Background="{DynamicResource ControlBackground}" Padding="6" MaxHeight="110">
                                        <ScrollViewer VerticalScrollBarVisibility="Auto">
                                            <ItemsControl x:Name="DownloadLanguagesList"/>
                                        </ScrollViewer>
                                    </Border>
                                </StackPanel>
                            </Grid>

                            <!-- Product Version (offline packages are version-specific) -->
                            <TextBlock Text="Product Version" Style="{StaticResource FieldLabel}"/>
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <ComboBox x:Name="DownloadVersionCombo" Height="28" Background="{DynamicResource ControlBackground}" Foreground="{DynamicResource TextForeground}" BorderBrush="{DynamicResource ControlBorder}"/>
                                <Button x:Name="VersionSelectBtn" Content="Select..." Grid.Column="1" Margin="8,0,0,0" Style="{StaticResource SecondaryButton}" Padding="10,4"/>
                            </Grid>

                            <!-- Destination folder -->
                            <TextBlock Text="Destination folder" Style="{StaticResource FieldLabel}"/>
                            <StackPanel Orientation="Horizontal">
                                <TextBox x:Name="DownloadDestBox" Width="360" Height="26" VerticalContentAlignment="Center" Background="{DynamicResource ControlBackground}" Foreground="{DynamicResource TextForeground}" BorderBrush="{DynamicResource ControlBorder}"/>
                                <Button x:Name="DownloadDestBrowseBtn" Content="Browse..." Style="{StaticResource SecondaryButton}" Padding="10,4"/>
                            </StackPanel>

                            <!-- Download / Cancel -->
                            <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                                <Button x:Name="DownloadBtn" Content="Download Office" Style="{StaticResource PrimaryButton}" MinWidth="200"/>
                                <Button x:Name="CancelDownloadBtn" Content="Cancel Download" Style="{StaticResource SecondaryButton}" MinWidth="160" Visibility="Collapsed"/>
                            </StackPanel>

                            <!-- Progress -->
                            <TextBlock x:Name="DownloadProgressLabel" Text="Download Progress" Style="{StaticResource FieldLabel}" Margin="0,12,0,2"/>
                            <ProgressBar x:Name="DownloadProgress" Height="8" IsIndeterminate="True" Visibility="Collapsed" Foreground="{DynamicResource AccentBrush}" Background="{DynamicResource ControlBackground}"/>
                            <TextBlock x:Name="DownloadProgressText" Text="" Foreground="{DynamicResource TextForeground}" FontSize="12" Margin="0,4,0,0"/>
                            <TextBlock x:Name="DownloadSpeedText" Text="" Foreground="{DynamicResource TextSecondary}" FontSize="12" Margin="0,2,0,0"/>

                            <!-- Create ISO -->
                            <Button x:Name="CreateIsoBtn" Content="Create ISO" Style="{StaticResource SecondaryButton}" MinWidth="200" Margin="4,12,4,0" HorizontalAlignment="Left" IsEnabled="False"/>

                            <!-- One-stream note (ODT has no such switch; informational only) -->
                            <CheckBox x:Name="DownloadSingleStreamCheck" Content="Download files in one stream" Foreground="{DynamicResource TextForeground}" Margin="0,10,0,0" ToolTip="ODT does not expose a single-vs-multi-thread download switch; this option is retained for UI parity and does not change ODT behavior."/>

                            <!-- Status -->
                            <TextBlock x:Name="DownloadStatusText" Text="Status: Ready" Foreground="{DynamicResource TextSecondary}" FontSize="12" Margin="0,8,0,0"/>
                        </StackPanel>
                    </ScrollViewer>
                </Grid>
            </TabItem>

            <!-- ================= TAB 4: ABOUT ================= -->
            <TabItem Header="About">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel Margin="20">
                        <TextBlock Text="OfficeInstallerGUI" FontSize="26" FontWeight="Bold" Foreground="{DynamicResource TextForeground}"/>
                        <TextBlock x:Name="AboutVersionText" Text="Version 1.0.0" FontSize="13" Foreground="{DynamicResource TextSecondary}" Margin="0,4,0,12"/>

                        <TextBlock TextWrapping="Wrap" Foreground="{DynamicResource TextForeground}" FontSize="13" Margin="0,0,0,8">
                            This application is a GUI wrapper around Microsoft's official Office Deployment Tool (ODT).
                            It does not itself download or bundle Office; it only generates a valid configuration.xml
                            and invokes setup.exe. All Office files come directly from Microsoft's CDN when you click
                            Download or Install.
                        </TextBlock>

                        <TextBlock Margin="0,4,0,4" Foreground="{DynamicResource TextForeground}">
                            <Hyperlink x:Name="OdtDocsLink" NavigateUri="https://learn.microsoft.com/en-us/deployoffice/overview-office-deployment-tool" Foreground="{DynamicResource HyperlinkBrush}">
                                Office Deployment Tool documentation (learn.microsoft.com)
                            </Hyperlink>
                        </TextBlock>

                        <TextBlock Text="Local files" Style="{StaticResource FieldLabel}" Margin="0,12,0,2"/>
                        <TextBlock x:Name="AboutCachePath" Text="" Foreground="{DynamicResource TextForeground}" FontSize="12" TextWrapping="Wrap"/>
                        <TextBlock x:Name="AboutLogPath" Text="" Foreground="{DynamicResource TextForeground}" FontSize="12" TextWrapping="Wrap"/>

                        <!-- Optional KMS section (hidden unless the checkbox is checked) -->
                        <CheckBox x:Name="KmsToggleCheck" Content="I manage volume licensing for this organization" Foreground="{DynamicResource TextForeground}" Margin="0,16,0,0"/>
                        <Border x:Name="KmsSection" BorderBrush="{DynamicResource ControlBorder}" BorderThickness="1" CornerRadius="4" Background="{DynamicResource ControlBackground}" Padding="10" Margin="0,8,0,0" Visibility="Collapsed">
                            <StackPanel>
                                <TextBlock TextWrapping="Wrap" Foreground="{DynamicResource TextSecondary}" FontSize="12" Margin="0,0,0,6">
                                    If your organization runs its own KMS host under a real Volume Licensing agreement,
                                    you can point an already volume-licensed Office install at it using Microsoft's own
                                    ospp.vbs script. This does not inject keys or convert channels — it only works with
                                    a genuinely volume-licensed product.
                                </TextBlock>
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock Text="KMS host (FQDN or IP):" Foreground="{DynamicResource TextForeground}" VerticalAlignment="Center"/>
                                    <TextBox x:Name="KmsHostBox" Width="240" Height="26" Margin="8,0,0,0" VerticalContentAlignment="Center" Background="{DynamicResource ControlBackground}" Foreground="{DynamicResource TextForeground}" BorderBrush="{DynamicResource ControlBorder}"/>
                                </StackPanel>
                                <Button x:Name="KmsActivateBtn" Content="Activate against organization KMS host" Style="{StaticResource SecondaryButton}" Margin="0,10,0,0" HorizontalAlignment="Left"/>
                            </StackPanel>
                        </Border>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>
        </TabControl>

        <!-- Bottom bar: theme toggle + status -->
        <Border Grid.Row="1" Background="{DynamicResource PanelBackground}" BorderBrush="{DynamicResource ControlBorder}" BorderThickness="0,1,0,0" Padding="12,6">
            <DockPanel>
                <CheckBox x:Name="DarkThemeCheck" Content="Use Dark Theme" IsChecked="True" Foreground="{DynamicResource TextForeground}" DockPanel.Dock="Left" VerticalAlignment="Center"/>
                <TextBlock x:Name="StatusText" Foreground="{DynamicResource TextSecondary}" TextAlignment="Right" VerticalAlignment="Center" Text="Ready"/>
            </DockPanel>
        </Border>
    </Grid>
</Window>
'@

# ============================================================================
# Logging helpers
# ============================================================================

function Get-Ui {
    <#
    .SYNOPSIS
        Shortcut to find a named control on the main window.
    #>
    param([string]$Name)
    if (-not $script:Window) { return $null }
    return $script:Window.FindName($Name)
}

function Add-ConsoleLine {
    <#
    .SYNOPSIS
        Appends a colored line to the on-screen log panel (Utilities tab).
    .PARAMETER Message
        Text to display.
    .PARAMETER Level
        INFO | OK | WARN | ERROR — controls the color (theme-aware).
    #>
    param([string]$Message, [string]$Level = 'INFO')
    $rtb = Get-Ui 'LogBox'
    if (-not $rtb) { return }
    $rtb.Dispatcher.Invoke([Action]{
        $para = New-Object System.Windows.Documents.Paragraph
        $para.Margin = New-Object System.Windows.Thickness(0)
        $run = New-Object System.Windows.Documents.Run
        $run.Text = "[$(Get-Date -Format 'HH:mm:ss')] $Message`n"
        $key = switch ($Level) {
            'ERROR' { 'ErrorText' }
            'WARN'  { 'WarningText' }
            'OK'    { 'SuccessText' }
            default { 'LogText' }
        }
        $run.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, $key)
        $para.Inlines.Add($run)
        $rtb.Document.Blocks.Add($para)
        $rtb.ScrollToEnd()
    })
}

function Write-Log {
    <#
    .SYNOPSIS
        Writes a line to the rolling log file AND the on-screen console panel.
    .PARAMETER Message
        Text to log.
    .PARAMETER Level
        INFO | OK | WARN | ERROR.
    #>
    param([string]$Message, [string]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    try {
        # Rolling log: one file per day under $env:LOCALAPPDATA\OfficeInstallerGUI\Logs
        $logFile = Join-Path $script:LogDir ("app-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
        Add-Content -Path $logFile -Value $line -Encoding UTF8
    } catch {
        # Never let logging break the app.
    }
    Add-ConsoleLine $Message $Level
}

# ============================================================================
# Core functions
# ============================================================================

function Confirm-Elevation {
    <#
    .SYNOPSIS
        Returns $true if the current process is running as Administrator.
    .RETURNS
        [bool]
    #>
    return [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ODT acquisition logic, defined once as a scriptblock so both the main-thread
# Get-OdtSetupExe function and the background runspace can share it. It is fully
# self-contained (no references to script-scope variables or UI) so it can run
# inside a background runspace — this keeps the WPF window responsive while the
# ODT installer is downloaded and extracted.
$script:OdtAcquireScript = {
    param($OdtCacheDir, $OdtDownloadPage, $OdtUrlFile, $Queue, [switch]$Force)
    # Returns the full path to setup.exe, or $null on failure.
    function Write-JobLine { param([string]$Line) $Queue.Enqueue($Line) }

    $setupExe = Join-Path $OdtCacheDir 'setup.exe'

    if (-not $Force -and (Test-Path $setupExe) -and (Get-Item $setupExe).Length -gt 1MB) {
        Write-JobLine "Using cached setup.exe: $setupExe"
        return $setupExe
    }

    Write-JobLine 'Downloading the Office Deployment Tool from Microsoft...'

    # --- Build the candidate installer URL list, tried in order ---
    $candidates = @()

    # 1. Resolve the actual .exe URL from the official download page. The page
    #    embeds a direct href to download.microsoft.com — we parse it out rather
    #    than hardcoding a versioned URL that goes stale.
    try {
        $page = Invoke-WebRequest -Uri $OdtDownloadPage -UseBasicParsing -TimeoutSec 30
        $match = [regex]::Match($page.Content, 'href="(https://download\.microsoft\.com/[^"]+\.exe)"')
        if ($match.Success) {
            $candidates += $match.Groups[1].Value
        } else {
            Write-JobLine 'Could not locate the ODT download link on the Microsoft download page.'
        }
    } catch {
        Write-JobLine "Could not reach the ODT download page: $($_.Exception.Message)"
    }

    # 2. Repo-maintained fallback URL (kept fresh by the update-odt.yml workflow).
    try {
        $content = (Invoke-WebRequest -Uri $OdtUrlFile -UseBasicParsing -TimeoutSec 15).Content
        $url = ($content -split "\r?\n")[0].Trim()
        if ($url -match '^https://download\.microsoft\.com/.*\.exe$') { $candidates += $url }
    } catch { }

    $candidates = @($candidates | Select-Object -Unique)
    if ($candidates.Count -eq 0) {
        Write-JobLine 'Could not determine the ODT download URL from Microsoft or the repo fallback.'
        return $null
    }

    # --- Try each candidate (with one retry for transient network/DNS failures) ---
    $installerPath = $null
    foreach ($installerUrl in $candidates) {
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            Write-JobLine "Trying ODT installer URL (attempt $attempt/2): $installerUrl"
            $installerPath = Join-Path $env:TEMP 'odt-installer.exe'
            try {
                Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing -TimeoutSec 120
                if ((Get-Item $installerPath).Length -lt 1MB) {
                    throw "Downloaded installer is unexpectedly small ($((Get-Item $installerPath).Length) bytes)."
                }
                break   # download succeeded
            } catch {
                Write-JobLine "Download failed: $($_.Exception.Message)"
                Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
                if ($attempt -eq 2) { $installerPath = $null }
            }
        }
        if ($installerPath -and (Test-Path $installerPath)) {
            break   # got a valid installer from this candidate
        }
    }

    if (-not $installerPath -or -not (Test-Path $installerPath)) {
        Write-JobLine 'All ODT download sources failed. Check your internet connection and DNS, or download the ODT manually and place setup.exe in the cache folder.'
        return $null
    }

    # --- Extract setup.exe from the self-extracting installer ---
    try {
        # The ODT downloader is a self-extracting archive. /extract:<path> pulls
        # out setup.exe (plus configuration.xml etc.) without installing anything.
        $extractDir = Join-Path $OdtCacheDir 'extract'
        New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
        $p = Start-Process -FilePath $installerPath -ArgumentList @("/extract:`"$extractDir`"") -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0) {
            throw "ODT self-extraction failed with exit code $($p.ExitCode)."
        }

        $extracted = Join-Path $extractDir 'setup.exe'
        if (-not (Test-Path $extracted)) {
            throw 'setup.exe was not produced by the ODT self-extraction.'
        }
        Copy-Item -Path $extracted -Destination $setupExe -Force
        Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
        Write-JobLine "setup.exe ready: $setupExe"
        return $setupExe
    } catch {
        Write-JobLine "Failed to obtain the Office Deployment Tool: $($_.Exception.Message)"
        return $null
    }
}

function Get-OdtSetupExe {
    <#
    .SYNOPSIS
        Returns the full path to the ODT setup.exe, downloading it if needed.
    .DESCRIPTION
        Main-thread wrapper around $script:OdtAcquireScript. It is kept as a
        named function for the spec; at runtime the background runspace calls
        OdtAcquireScript directly so the UI never freezes during the download.
    .PARAMETER Force
        Re-download even if a cached copy exists.
    .RETURNS
        Full path to setup.exe, or $null on failure (errors are logged, never
        silently swallowed).
    #>
    param([switch]$Force)
    $queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $result = & $script:OdtAcquireScript $script:OdtCacheDir $script:OdtDownloadPage $script:OdtUrlFile $queue -Force:$Force
    $line = $null
    while ($queue.TryDequeue([ref]$line)) { Add-ConsoleLine $line 'INFO' }
    if ($result) { Update-OdtVersionLabel }
    return $result
}

function New-OdtConfigXml {
    <#
    .SYNOPSIS
        Builds a well-formed ODT configuration.xml from the current selections.
    .DESCRIPTION
        Uses [xml] element creation (never string concatenation) so empty or
        unusual fields cannot produce malformed/injected XML. Validates that at
        least one language and at least one product/app are selected for Add.
    .PARAMETER EditionId
        ODT Product ID for the suite (e.g. O365ProPlusRetail).
    .PARAMETER Architecture
        '32' or '64'.
    .PARAMETER Channel
        Official ODT Channel value (e.g. Current, PerpetualVL2021).
    .PARAMETER Languages
        Array of language tags (e.g. en-US).
    .PARAMETER ExcludedApps
        App IDs to emit as <ExcludeApp> (suite mode).
    .PARAMETER IndividualApps
        Product IDs for individual-app installs (used with -UseIndividualApps).
    .PARAMETER UseIndividualApps
        Emit one <Product> per individual app instead of a single suite product.
    .PARAMETER SourcePath
        Optional local folder. For /download this is the destination; for
        /configure this is the offline install source.
    .PARAMETER Action
        Add (default) | Remove (scoped to EditionId) | RemoveAll.
    .RETURNS
        XML string, or $null if validation fails.
    #>
    param(
        [string]$EditionId,
        [string]$Architecture = '64',
        [string]$Channel = 'Current',
        [string[]]$Languages,
        [string[]]$ExcludedApps,
        [string[]]$IndividualApps,
        [switch]$UseIndividualApps,
        [string]$SourcePath,
        [string]$Version,
        [ValidateSet('Add', 'Remove', 'RemoveAll')]
        [string]$Action = 'Add'
    )

    # --- Validation (block Install/Download otherwise) ---
    if ($Action -eq 'Add') {
        if (-not $Languages -or $Languages.Count -eq 0) {
            Write-Log 'Validation failed: select at least one language.' 'ERROR'
            return $null
        }
        if ($UseIndividualApps) {
            if (-not $IndividualApps -or $IndividualApps.Count -eq 0) {
                Write-Log 'Validation failed: select at least one individual app.' 'ERROR'
                return $null
            }
        } elseif ([string]::IsNullOrWhiteSpace($EditionId)) {
            Write-Log 'Validation failed: select an edition.' 'ERROR'
            return $null
        }
    }

    $xml = [xml]'<Configuration />'
    $root = $xml.DocumentElement

    if ($Action -eq 'RemoveAll') {
        $remove = $xml.CreateElement('Remove')
        $remove.SetAttribute('All', 'TRUE')
        [void]$root.AppendChild($remove)
    } elseif ($Action -eq 'Remove') {
        $remove = $xml.CreateElement('Remove')
        $product = $xml.CreateElement('Product')
        $product.SetAttribute('ID', $EditionId)
        [void]$remove.AppendChild($product)
        [void]$root.AppendChild($remove)
    } else {
        $add = $xml.CreateElement('Add')
        $add.SetAttribute('OfficeClientEdition', $Architecture)
        $add.SetAttribute('Channel', $Channel)
        if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
            $add.SetAttribute('SourcePath', $SourcePath)
        }

        if ($UseIndividualApps) {
            foreach ($appId in $IndividualApps) {
                $product = $xml.CreateElement('Product')
                $product.SetAttribute('ID', $appId)
                foreach ($lang in $Languages) {
                    $langEl = $xml.CreateElement('Language')
                    $langEl.SetAttribute('ID', $lang)
                    [void]$product.AppendChild($langEl)
                }
                if (-not [string]::IsNullOrWhiteSpace($Version)) {
                    $verEl = $xml.CreateElement('Version')
                    $verEl.InnerText = $Version
                    [void]$product.AppendChild($verEl)
                }
                [void]$add.AppendChild($product)
            }
        } else {
            $product = $xml.CreateElement('Product')
            $product.SetAttribute('ID', $EditionId)
            foreach ($lang in $Languages) {
                $langEl = $xml.CreateElement('Language')
                $langEl.SetAttribute('ID', $lang)
                [void]$product.AppendChild($langEl)
            }
            if (-not [string]::IsNullOrWhiteSpace($Version)) {
                $verEl = $xml.CreateElement('Version')
                $verEl.InnerText = $Version
                [void]$product.AppendChild($verEl)
            }
            foreach ($appId in $ExcludedApps) {
                $exclude = $xml.CreateElement('ExcludeApp')
                $exclude.SetAttribute('ID', $appId)
                [void]$product.AppendChild($exclude)
            }
            [void]$add.AppendChild($product)
        }
        [void]$root.AppendChild($add)

        $display = $xml.CreateElement('Display')
        $display.SetAttribute('Level', 'Full')
        $display.SetAttribute('AcceptEULA', 'TRUE')
        [void]$root.AppendChild($display)

        $logging = $xml.CreateElement('Logging')
        $logging.SetAttribute('Level', 'Standard')
        $logging.SetAttribute('Path', '%temp%\OfficeLogs')
        [void]$root.AppendChild($logging)
    }

    return $xml.OuterXml
}

function Invoke-OdtAction {
    <#
    .SYNOPSIS
        Launches setup.exe with the given config and mode.
    .DESCRIPTION
        Wraps $script:OdtRunScript (the shared setup.exe invocation). It starts
        setup.exe with /configure or /download, waits for it to finish, and
        returns the exit code. stdout/stderr are not useful from ODT (it writes
        its own logs), so the caller tails the ODT log directory separately.
    .PARAMETER SetupExe
        Full path to setup.exe.
    .PARAMETER ConfigPath
        Full path to the generated configuration.xml.
    .PARAMETER Mode
        'configure' or 'download'.
    .RETURNS
        Process exit code.
    #>
    param([string]$SetupExe, [string]$ConfigPath, [ValidateSet('configure','download')][string]$Mode)
    return & $script:OdtRunScript $SetupExe $ConfigPath $Mode
}

# ISO creation logic, defined once as a scriptblock so both the main-thread
# New-OfficeIso function and the background ISO runspace can share it.
$script:IsoLogicScript = {
    param([string]$SourceFolder, [string]$IsoPath, [string]$VolumeName)
    # Returns @{ Success = [bool]; Message = [string] }

    # Prefer oscdimg.exe from the Windows ADK if present (most reliable).
    $oscdimg = $null
    $kitPaths = @(
        "$env:ProgramFiles(x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "$env:ProgramFiles(x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\x86\Oscdimg\oscdimg.exe",
        "$env:ProgramFiles(x86)\Windows Kits\10\bin\x64\oscdimg.exe",
        "$env:ProgramFiles(x86)\Windows Kits\10\bin\x86\oscdimg.exe"
    )
    foreach ($p in $kitPaths) { if (Test-Path $p) { $oscdimg = $p; break } }

    if ($oscdimg) {
        $p = Start-Process -FilePath $oscdimg -ArgumentList @("-l$VolumeName", '-m', '-o', '-u2', "`"$SourceFolder`"", "`"$IsoPath`"") -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -eq 0) {
            return @{ Success = $true; Message = "ISO created with oscdimg: $IsoPath" }
        }
        # oscdimg failed — fall through to IMAPI2.
    }

    # IMAPI2 fallback (built into Windows, no ADK needed).
    try {
        $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
        $fsi.FileSystemsToCreate = 4   # ISO9660 + Joliet
        $fsi.VolumeName = $VolumeName
        $fsi.Root.AddTree($SourceFolder, $false)
        $result = $fsi.CreateResultImage()
        $stream = $result.ImageStream
        $fs = [System.IO.File]::Create($IsoPath)
        try {
            $stream.Position = 0
            $buffer = New-Object byte[] 1048576
            while ($true) {
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -eq 0) { break }
                $fs.Write($buffer, 0, $read)
            }
        } finally {
            $fs.Close()
            try { $stream.Close() } catch { }
        }
        return @{ Success = $true; Message = "ISO created with IMAPI2: $IsoPath" }
    } catch {
        # Note: this scriptblock runs inside a background runspace, so it cannot
        # reference $script:AdkDocsUrl — the URL is inlined here on purpose.
        return @{
            Success = $false
            Message = "ISO creation failed. oscdimg.exe was not found and IMAPI2 errored: $($_.Exception.Message). Install the Windows ADK to get oscdimg: https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install"
        }
    }
}

function New-OfficeIso {
    <#
    .SYNOPSIS
        Builds an ISO from a downloaded Office source folder.
    .DESCRIPTION
        Uses oscdimg.exe (Windows ADK) if present, otherwise IMAPI2 COM objects.
        If neither works, returns $false and tells the user how to get oscdimg.
    .PARAMETER SourceFolder
        Folder containing the downloaded Office source files.
    .PARAMETER IsoPath
        Destination .iso file path.
    .PARAMETER VolumeName
        ISO volume label.
    .RETURNS
        [bool] $true on success.
    #>
    param([string]$SourceFolder, [string]$IsoPath, [string]$VolumeName = 'OfficeOffline')
    $result = & $script:IsoLogicScript $SourceFolder $IsoPath $VolumeName
    if ($result.Success) {
        Write-Log $result.Message 'OK'
        return $true
    }
    Write-Log $result.Message 'ERROR'
    return $false
}

function Test-OfficeInstalled {
    <#
    .SYNOPSIS
        Read-only check of installed Click-to-Run Office products.
    .DESCRIPTION
        Queries HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration (and the
        WOW6432Node equivalent) for VersionToReport, ProductReleaseIds and
        Platform. Makes no changes.
    .RETURNS
        Multi-line summary string.
    #>
    $configPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration'
    )
    $found = $false
    $lines = @()
    foreach ($path in $configPaths) {
        if (Test-Path $path) {
            $found = $true
            try {
                $props = Get-ItemProperty -Path $path
                $lines += "Registry: $path"
                $lines += "  VersionToReport   : $($props.VersionToReport)"
                $lines += "  ProductReleaseIds : $($props.ProductReleaseIds)"
                $lines += "  Platform          : $($props.Platform)"
                $lines += "  UpdateChannel     : $($props.UpdateChannel)"
            } catch {
                $lines += "Registry: $path (could not read: $($_.Exception.Message))"
            }
        }
    }
    if (-not $found) {
        return 'Office (Click-to-Run) does not appear to be installed.'
    }
    return ($lines -join "`n")
}

function Set-AppTheme {
    <#
    .SYNOPSIS
        Swaps the active theme ResourceDictionary between light and dark.
    .DESCRIPTION
        Both palettes live in the window's merged dictionaries. WPF gives the
        LAST dictionary in the collection priority, so we remove the inactive one
        and re-add the active one at the end. DynamicResource references then
        re-resolve automatically. The choice is persisted to settings.json.
        Uses $script:DarkThemeDict / $script:LightThemeDict (captured at startup)
        because removed dictionaries can't be found via the Resources indexer.
    .PARAMETER Dark
        $true for dark theme, $false for light.
    #>
    param([bool]$Dark)
    $merged = $script:Window.Resources.MergedDictionaries
    if ($Dark) {
        if ($script:LightThemeDict) { [void]$merged.Remove($script:LightThemeDict) }
        if ($script:DarkThemeDict) { [void]$merged.Remove($script:DarkThemeDict); [void]$merged.Add($script:DarkThemeDict) }
    } else {
        if ($script:DarkThemeDict) { [void]$merged.Remove($script:DarkThemeDict) }
        if ($script:LightThemeDict) { [void]$merged.Remove($script:LightThemeDict); [void]$merged.Add($script:LightThemeDict) }
    }
    # Persist the choice (the only local persistence this app needs).
    try {
        @{ DarkTheme = $Dark } | ConvertTo-Json | Set-Content -Path $script:SettingsFile -Encoding UTF8
    } catch { }
}

function Update-OdtVersionLabel {
    <#
    .SYNOPSIS
        Shows the ODT tool's own version string (from setup.exe file version) on
        the Download tab. Never fabricates a version number.
    #>
    $setupExe = Join-Path $script:OdtCacheDir 'setup.exe'
    if (-not (Test-Path $setupExe)) { return }
    try {
        $vi = (Get-Item $setupExe).VersionInfo
        $label = Get-Ui 'DownloadVersionLabel'
        if ($label) { $label.Text = "Office Deployment Tool version: $($vi.FileVersion)" }
    } catch { }
}

# ============================================================================
# Background job machinery
# ============================================================================

# setup.exe invocation, shared by the main-thread Invoke-OdtAction function and
# the background runspace (which cannot call main-thread functions directly).
$script:OdtRunScript = {
    param($SetupExe, $ConfigPath, $Mode)
    $p = Start-Process -FilePath $SetupExe -ArgumentList @("/$Mode", "`"$ConfigPath`"") -Wait -PassThru -NoNewWindow
    return $p.ExitCode
}

# Scriptblock run in the background runspace for ODT configure/download actions.
# It first ensures setup.exe is available (downloading + extracting it if needed)
# and then runs setup.exe — the whole operation stays off the UI thread.
$script:OdtJobScript = {
    param($OdtAcquire, $OdtRun, $ConfigPath, $Mode, $OdtCacheDir, $OdtDownloadPage, $OdtUrlFile, $Queue)
    function Write-JobLine { param([string]$Line) $Queue.Enqueue($Line) }

    # 1. Ensure setup.exe is present (downloads + extracts if needed).
    $setupExe = & $OdtAcquire $OdtCacheDir $OdtDownloadPage $OdtUrlFile $Queue
    if (-not $setupExe) {
        Write-JobLine 'Aborting: could not obtain setup.exe.'
        return 1
    }

    # 2. Run setup.exe.
    Write-JobLine "Launching setup.exe /$Mode ..."
    $exitCode = & $OdtRun $setupExe $ConfigPath $Mode
    Write-JobLine "setup.exe finished with exit code $exitCode."
    return $exitCode
}

# Scriptblock run in the background runspace for ISO creation.
$script:IsoJobScript = {
    param($IsoLogic, $SourceFolder, $IsoPath, $VolumeName, $Queue)
    function Write-JobLine { param([string]$Line) $Queue.Enqueue($Line) }
    Write-JobLine "Creating ISO from $SourceFolder ..."
    $result = & $IsoLogic $SourceFolder $IsoPath $VolumeName
    Write-JobLine $result.Message
    if ($result.Success) { return 0 }
    return 1
}

# Scriptblock run in the background runspace for KMS host activation (ospp.vbs).
$script:KmsJobScript = {
    param($Ospp, $KmsHost, $Queue)
    function Write-JobLine { param([string]$Line) $Queue.Enqueue($Line) }
    Write-JobLine "Setting KMS host to $KmsHost ..."
    $out1 = & cscript.exe //nologo $Ospp "/sethst:$KmsHost" 2>&1
    foreach ($l in $out1) { Write-JobLine "$l" }
    Write-JobLine 'Activating against the KMS host ...'
    $out2 = & cscript.exe //nologo $Ospp /act 2>&1
    foreach ($l in $out2) { Write-JobLine "$l" }
    Write-JobLine 'KMS activation attempt finished.'
    return 0
}

function Start-BackgroundJob {
    <#
    .SYNOPSIS
        Starts a long-running operation in a separate runspace so the UI stays
        responsive. Status lines flow back through a ConcurrentQueue.
    .PARAMETER Kind
        'install' | 'uninstall' | 'download' | 'iso'.
    .PARAMETER Script
        Scriptblock to run (must accept a trailing $Queue parameter).
    .PARAMETER Arguments
        Positional arguments for the scriptblock (before $Queue).
    .PARAMETER OdtLogDir
        Directory to tail live while the job runs (may be $null).
    #>
    param([string]$Kind, [scriptblock]$Script, [object[]]$Arguments, [string]$OdtLogDir)

    $queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $script:Job.OutputQueue = $queue
    $script:Job.Running = $true
    $script:Job.Kind = $Kind
    $script:Job.OdtLogDir = $OdtLogDir

    $ps = [powershell]::Create()
    [void]$ps.AddScript($Script.ToString())
    foreach ($arg in $Arguments) { [void]$ps.AddArgument($arg) }
    [void]$ps.AddArgument($queue)
    $script:Job.PowerShell = $ps
    $script:Job.AsyncResult = $ps.BeginInvoke()
}

function Tail-OdtLog {
    <#
    .SYNOPSIS
        Reads new lines from the newest ODT log file and pumps them to the console.
    .DESCRIPTION
        ODT writes its own logs under %temp%\OfficeLogs. We track the last-read
        byte offset per file so we only emit new content.
    #>
    param([string]$LogDir)
    if (-not (Test-Path $LogDir)) { return }
    $logFile = Get-ChildItem -Path $LogDir -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $logFile) { return }
    $path = $logFile.FullName
    $lastSize = 0
    if ($script:LogTailState.ContainsKey($path)) { $lastSize = $script:LogTailState[$path] }
    $size = $logFile.Length
    if ($size -le $lastSize) { return }
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $fs.Position = $lastSize
            $reader = [System.IO.StreamReader]::new($fs)
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    Add-ConsoleLine $line 'INFO'
                }
            }
            $script:LogTailState[$path] = $fs.Position
        } finally { $fs.Close() }
    } catch { }
}

function Get-OdtResultSummary {
    <#
    .SYNOPSIS
        Best-effort summary of an ODT run by scanning its log files for
        Completed / Failed markers. Falls back to the process exit code.
    #>
    param([string]$LogDir, [int]$ExitCode)
    $lines = @()
    if (Test-Path $LogDir) {
        $files = Get-ChildItem -Path $LogDir -Filter '*.log' -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $lines += Get-Content -Path $f.FullName -ErrorAction SilentlyContinue
        }
    }
    $joined = $lines -join "`n"
    if ($joined -match 'Completed') { return 'ODT reported completion.' }
    if ($joined -match 'Failed|Error') { return 'ODT reported an error — see the console log for details.' }
    return "Process exit code: $ExitCode"
}

function Update-FromBackgroundJob {
    <#
    .SYNOPSIS
        DispatcherTimer tick: drains the job output queue, tails the ODT log,
        and finalizes the job when the runspace completes.
    #>
    if (-not $script:Job.Running) { return }

    # Drain status lines from the runspace.
    $line = $null
    while ($script:Job.OutputQueue -and $script:Job.OutputQueue.TryDequeue([ref]$line)) {
        Add-ConsoleLine $line 'INFO'
    }

    # Tail ODT's own log while the process runs.
    if ($script:Job.OdtLogDir) {
        Tail-OdtLog -LogDir $script:Job.OdtLogDir
    }

    # Sample download progress (folder size + speed) while a download runs.
    if ($script:Job.Kind -eq 'download') {
        Update-DownloadProgress
    }

    # Completion?
    if ($script:Job.AsyncResult -and $script:Job.AsyncResult.IsCompleted) {
        $exitCode = 0
        try {
            # EndInvoke returns a PSDataCollection of the script's output, NOT a
            # scalar. Comparing the collection directly (e.g. $exitCode -eq 0)
            # yields the element 0, and [bool]0 is $false — which would wrongly
            # report success as failure. Extract the first output value instead.
            $result = $script:Job.PowerShell.EndInvoke($script:Job.AsyncResult)
            if ($result -and $result.Count -gt 0) {
                $exitCode = [int]$result[0]
            }
        } catch {
            Add-ConsoleLine "Background job error: $($_.Exception.Message)" 'ERROR'
        }
        $script:Job.PowerShell.Dispose()
        $kind = $script:Job.Kind
        $script:Job.Running = $false
        $script:Job.PowerShell = $null
        $script:Job.AsyncResult = $null

        Set-UiBusy $false

        # If the job downloaded setup.exe, refresh the ODT version label now.
        Update-OdtVersionLabel

        # Re-apply validity gating to the action buttons.
        Update-ButtonStates

        switch ($kind) {
            'install' {
                if ($exitCode -eq 0) {
                    $summary = Get-OdtResultSummary -LogDir $script:OdtLogDir -ExitCode $exitCode
                    Write-Log "Install finished. $summary" 'OK'
                    [System.Windows.MessageBox]::Show($script:Window, "Office install finished.`n`n$summary", 'Install Complete', 'OK', 'Information') | Out-Null
                } else {
                    Write-Log "Install failed (exit code $exitCode). See the console log for details." 'ERROR'
                    Show-ErrorDialog -Operation 'Install' -ExitCode $exitCode -Details 'Unable to complete the Office Deployment Tool install operation.'
                }
            }
            'uninstall' {
                if ($exitCode -eq 0) {
                    Write-Log 'Uninstall finished.' 'OK'
                    [System.Windows.MessageBox]::Show($script:Window, 'Office uninstall finished.', 'Uninstall Complete', 'OK', 'Information') | Out-Null
                } else {
                    Write-Log "Uninstall failed (exit code $exitCode)." 'ERROR'
                    Show-ErrorDialog -Operation 'Uninstall' -ExitCode $exitCode -Details 'Unable to complete the Office Deployment Tool uninstall operation.'
                }
            }
            'download' {
                if ($exitCode -eq 0) {
                    $script:LastDownloadFolder = $script:LastDownloadDest
                    $isoBtn = Get-Ui 'CreateIsoBtn'
                    if ($isoBtn) { $isoBtn.IsEnabled = $true }
                    Set-DownloadUiState 'complete'
                    Write-Log "Download complete. Source files are in: $script:LastDownloadFolder" 'OK'
                } else {
                    Set-DownloadUiState 'failed'
                    Write-Log "Download failed (exit code $exitCode)." 'ERROR'
                    Show-ErrorDialog -Operation 'Download' -ExitCode $exitCode -Details 'Unable to complete the Office Deployment Tool download operation.'
                }
            }
            'iso' {
                if ($exitCode -eq 0) {
                    Write-Log 'ISO creation finished.' 'OK'
                } else {
                    Write-Log 'ISO creation failed. See the console log for details.' 'ERROR'
                    Show-ErrorDialog -Operation 'ISO creation' -ExitCode $exitCode -Details 'Unable to create the ISO image.'
                }
            }
            'kms' {
                if ($exitCode -eq 0) {
                    Write-Log 'KMS activation finished.' 'OK'
                } else {
                    Write-Log 'KMS activation failed. See the console log for details.' 'ERROR'
                }
            }
        }
    }
}

function Set-UiBusy {
    <#
    .SYNOPSIS
        Disables action buttons and shows/hides the indeterminate progress bars
        while a long-running operation is in flight.
    #>
    param([bool]$Busy)
    foreach ($name in @('InstallBtn', 'UninstallBtn', 'StatusBtn', 'DownloadBtn', 'CreateIsoBtn', 'KmsActivateBtn')) {
        $b = Get-Ui $name
        if ($b) { $b.IsEnabled = -not $Busy }
    }
    $ip = Get-Ui 'InstallProgress'
    if ($ip) { $ip.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' } }
    $dp = Get-Ui 'DownloadProgress'
    if ($dp) { $dp.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' } }
    $st = Get-Ui 'StatusText'
    if ($st) { $st.Text = if ($Busy) { 'Working...' } else { 'Ready' } }
}

# ============================================================================
# UI helpers
# ============================================================================

function Show-FolderPicker {
    <#
    .SYNOPSIS
        Shows a folder picker (WinForms FolderBrowserDialog — WPF has no built-in
        folder picker in .NET Framework).
    .RETURNS
        Selected folder path, or $null if cancelled.
    #>
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select a folder'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dlg.SelectedPath
    }
    return $null
}

function Populate-EditionCombo {
    param($Combo, [string]$FamilyName)
    $Combo.Items.Clear()
    $editions = $script:Editions
    if ($FamilyName) {
        $family = $script:ProductFamilies | Where-Object { $_.Name -eq $FamilyName }
        if ($family) { $editions = @($script:Editions | Where-Object { $family.Editions -contains $_.Id }) }
    }
    foreach ($e in $editions) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $e.Name
        $item.Tag = $e.Id
        [void]$Combo.Items.Add($item)
    }
    $Combo.SelectedIndex = 0
}

function Populate-FamilyCombo {
    param($Combo)
    $Combo.Items.Clear()
    foreach ($f in $script:ProductFamilies) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $f.Name
        $item.Tag = $f.Name
        [void]$Combo.Items.Add($item)
    }
    $Combo.SelectedIndex = 0
}

function Populate-VersionCombo {
    param($Combo)
    $Combo.Items.Clear()
    foreach ($v in $script:ProductVersions) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $v.Name
        $item.Tag = $v.Id
        [void]$Combo.Items.Add($item)
    }
    $Combo.SelectedIndex = 0
}

function Populate-ChannelCombo {
    param($Combo)
    $Combo.Items.Clear()
    foreach ($c in $script:Channels) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $c.Name
        $item.Tag = $c.Id
        [void]$Combo.Items.Add($item)
    }
    $Combo.SelectedIndex = 0
}

function Populate-YearCombo {
    param($Combo)
    $Combo.Items.Clear()
    foreach ($y in @('2021', '2019')) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $y
        $item.Tag = $y
        [void]$Combo.Items.Add($item)
    }
    $Combo.SelectedIndex = 0
}

function New-AppCheckbox {
    <#
    .SYNOPSIS
        Creates a themed CheckBox for the app lists. Toggling it re-evaluates the
        Install/Download button validity (e.g. no individual app selected).
    #>
    param([string]$Name, [string]$Id, [bool]$Checked)
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $Name
    $cb.Tag = $Id
    $cb.Margin = New-Object System.Windows.Thickness(4, 2, 4, 2)
    $cb.IsChecked = $Checked
    $cb.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'TextForeground')
    $cb.Add_Checked({ Update-ButtonStates })
    $cb.Add_Unchecked({ Update-ButtonStates })
    return $cb
}

function Populate-AppLists {
    <#
    .SYNOPSIS
        Fills the suite and individual app checkbox lists.
    #>
    $suiteList = Get-Ui 'SuiteAppsList'
    $suiteList.Items.Clear()
    foreach ($app in $script:SuiteApps) {
        $checked = ($script:SuiteDefaultChecked -contains $app.Id)
        [void]$suiteList.Items.Add((New-AppCheckbox -Name $app.Name -Id $app.Id -Checked $checked))
    }

    $indList = Get-Ui 'IndividualAppsList'
    $indList.Items.Clear()
    foreach ($app in $script:IndividualApps) {
        [void]$indList.Items.Add((New-AppCheckbox -Name $app.Name -Id $app.Id -Checked $false))
    }
}

function New-LanguageCheckbox {
    <#
    .SYNOPSIS
        Creates a themed language CheckBox that mirrors its state to the other
        tab's language list (so Install and Download never disagree).
    #>
    param([string]$Locale, [bool]$Checked)
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $Locale
    $cb.Tag = $Locale
    $cb.Margin = New-Object System.Windows.Thickness(4, 2, 4, 2)
    $cb.IsChecked = $Checked
    $cb.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'TextForeground')
    $cb.Add_Checked({ Sync-LanguageLists; Update-ButtonStates })
    $cb.Add_Unchecked({ Sync-LanguageLists; Update-ButtonStates })
    return $cb
}

function Populate-LanguageLists {
    <#
    .SYNOPSIS
        Fills both tabs' language lists. en-US is checked by default.
    #>
    foreach ($listName in @('InstallLanguagesList', 'DownloadLanguagesList')) {
        $list = Get-Ui $listName
        $list.Items.Clear()
        foreach ($lang in $script:Languages) {
            [void]$list.Items.Add((New-LanguageCheckbox -Locale $lang -Checked ($lang -eq 'en-US')))
        }
    }
}

function Sync-LanguageLists {
    <#
    .SYNOPSIS
        Copies checked state from the Install tab's language list to the Download
        tab's list (guarded against recursion).
    #>
    if ($script:SyncingLanguages) { return }
    $script:SyncingLanguages = $true
    try {
        $src = Get-Ui 'InstallLanguagesList'
        $dst = Get-Ui 'DownloadLanguagesList'
        if ($src -and $dst) {
            $count = [Math]::Min($src.Items.Count, $dst.Items.Count)
            for ($i = 0; $i -lt $count; $i++) {
                $dst.Items[$i].IsChecked = $src.Items[$i].IsChecked
            }
        }
    } finally {
        $script:SyncingLanguages = $false
    }
}

function Get-SelectedEditionId {
    <#
    .SYNOPSIS
        Returns the ODT Product ID of the currently selected edition.
    #>
    $combo = Get-Ui 'InstallEditionCombo'
    if ($combo -and $combo.SelectedItem) { return $combo.SelectedItem.Tag }
    return $null
}

function Get-SelectedChannel {
    <#
    .SYNOPSIS
        Returns the ODT Channel value of the currently selected channel.
    #>
    $combo = Get-Ui 'InstallChannelCombo'
    if ($combo -and $combo.SelectedItem) { return $combo.SelectedItem.Tag }
    return 'Current'
}

function Get-SelectedArchitecture {
    <#
    .SYNOPSIS
        Returns '64' or '32' from the architecture radio buttons.
    #>
    $r64 = Get-Ui 'InstallArch64Radio'
    if ($r64 -and $r64.IsChecked) { return '64' }
    return '32'
}

function Get-SelectedLanguages {
    <#
    .SYNOPSIS
        Returns the array of checked language tags.
    #>
    $list = Get-Ui 'InstallLanguagesList'
    $result = @()
    foreach ($item in $list.Items) {
        if ($item.IsChecked) { $result += $item.Tag }
    }
    return $result
}

function Get-ExcludedApps {
    <#
    .SYNOPSIS
        Returns app IDs to exclude (suite mode): unchecked suite apps.
    #>
    $list = Get-Ui 'SuiteAppsList'
    $result = @()
    foreach ($item in $list.Items) {
        if (-not $item.IsChecked) { $result += $item.Tag }
    }
    return $result
}

function Get-SelectedIndividualApps {
    <#
    .SYNOPSIS
        Returns the resolved Product IDs of checked individual apps. Project/Visio
        IDs use the 2021 volume IDs (the most recent LTSC); the UI has no year
        selector, so the year is fixed at 2021.
    #>
    $list = Get-Ui 'IndividualAppsList'
    $year = '2021'
    $result = @()
    foreach ($item in $list.Items) {
        if ($item.IsChecked) {
            $id = $item.Tag
            if ($id -match '\{Year\}') { $id = $id.Replace('{Year}', $year) }
            $result += $id
        }
    }
    return $result
}

function Update-ButtonStates {
    <#
    .SYNOPSIS
        Enables/disables the Install and Download buttons based on whether the
        current selections are valid (at least one language, and at least one
        product/app selected). Skipped while a background job is running so it
        never fights Set-UiBusy.
    #>
    if ($script:Job.Running) { return }

    $languages = Get-SelectedLanguages
    $hasLanguage = ($languages.Count -gt 0)

    $useIndividual = (Get-Ui 'InstallIndividualCheck').IsChecked
    $hasProduct = $false
    if ($useIndividual) {
        $hasProduct = ((Get-SelectedIndividualApps).Count -gt 0)
    } else {
        $hasProduct = (-not [string]::IsNullOrWhiteSpace((Get-SelectedEditionId)))
    }

    $installBtn = Get-Ui 'InstallBtn'
    if ($installBtn) { $installBtn.IsEnabled = ($hasLanguage -and $hasProduct) }

    # Download always uses suite mode (edition + languages).
    $downloadBtn = Get-Ui 'DownloadBtn'
    if ($downloadBtn) { $downloadBtn.IsEnabled = $hasLanguage }
}

function Test-VolumeChannelMismatch {
    <#
    .SYNOPSIS
        Warns if any selected individual app is a Volume product while the channel
        is not a PerpetualVL channel (which would make setup.exe fail cleanly).
    .RETURNS
        [bool] $true if a mismatch was found and the user chose to continue.
    #>
    $apps = Get-SelectedIndividualApps
    $channel = Get-SelectedChannel
    $volumeApps = @($apps | Where-Object { $_ -match 'Volume$' })
    if ($volumeApps.Count -gt 0 -and $channel -notmatch '^PerpetualVL') {
        $msg = "You selected volume-licensed products ($($volumeApps -join ', ')) but the channel is '$channel'.`n`nVolume products normally require a PerpetualVL channel (e.g. PerpetualVL2021). Continue anyway?"
        $res = [System.Windows.MessageBox]::Show($script:Window, $msg, 'Channel / Product mismatch', 'YesNo', 'Warning')
        return ($res -eq 'Yes')
    }
    return $true
}

function Get-ThemeColor {
    <#
    .SYNOPSIS
        Returns the active theme brush for a resource key (used by code-built dialogs).
    #>
    param([string]$Key)
    $dict = if ($script:Settings.DarkTheme) { $script:DarkThemeDict } else { $script:LightThemeDict }
    if ($dict -and $dict.Contains($Key)) { return $dict[$Key] }
    return [System.Windows.Media.Brushes]::White
}

function Get-SelectedVersion {
    <#
    .SYNOPSIS
        Returns the currently selected product version (16.0.x.y) or $null.
    #>
    return $script:SelectedVersion
}

function Set-SelectedVersion {
    <#
    .SYNOPSIS
        Sets the selected product version and reflects it in the Download tab's
        version combo.
    #>
    param([string]$Version)
    $script:SelectedVersion = $Version
    $combo = Get-Ui 'DownloadVersionCombo'
    if ($combo) {
        foreach ($item in $combo.Items) {
            if ($item.Tag -eq $Version) { $combo.SelectedItem = $item; break }
        }
    }
}

function Get-InstalledOfficeApps {
    <#
    .SYNOPSIS
        Detects which Office applications are installed by checking for their
        executables in the Click-to-Run installation folder.
    .RETURNS
        Array of app names (Word, Excel, ...) that are installed.
    #>
    $exeMap = @{
        'Word' = 'winword.exe'
        'Excel' = 'excel.exe'
        'PowerPoint' = 'powerpnt.exe'
        'Outlook' = 'outlook.exe'
        'OneNote' = 'onenote.exe'
        'Access' = 'msaccess.exe'
        'Publisher' = 'mspub.exe'
        'Project' = 'winproj.exe'
        'Visio' = 'visio.exe'
    }
    # Determine the Office installation folder from the registry.
    $officeDir = $null
    foreach ($path in @('HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration')) {
        if (Test-Path $path) {
            $props = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
            if ($props.ClientFolder) { $officeDir = $props.ClientFolder; break }
            if ($props.InstallationPath) { $officeDir = $props.InstallationPath; break }
        }
    }
    if (-not $officeDir) {
        # Fallback to the standard Click-to-Run paths.
        foreach ($candidate in @("$env:ProgramFiles\Microsoft Office\root\Office16", "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16")) {
            if (Test-Path $candidate) { $officeDir = $candidate; break }
        }
    }
    if (-not $officeDir) { return @() }

    $installed = @()
    foreach ($app in $exeMap.Keys) {
        if (Test-Path (Join-Path $officeDir $exeMap[$app])) { $installed += $app }
    }
    return $installed
}

function Update-UtilityButtons {
    <#
    .SYNOPSIS
        Enables only the Office app launcher buttons for installed products.
    #>
    $installed = Get-InstalledOfficeApps
    foreach ($app in @('Word', 'Excel', 'PowerPoint', 'Outlook', 'OneNote', 'Access', 'Publisher', 'Project', 'Visio')) {
        $btn = Get-Ui ("Launch{0}Btn" -f $app)
        if ($btn) { $btn.IsEnabled = ($installed -contains $app) }
    }
    if ($installed.Count -eq 0) {
        Write-Log 'No Office applications detected. App launchers are disabled.' 'WARN'
    } else {
        Write-Log "Detected installed Office apps: $($installed -join ', ')" 'INFO'
    }
}

function Show-ProductVersionDialog {
    <#
    .SYNOPSIS
        Shows the "Select Product Version" dialog (presets + custom, validated).
    .RETURNS
        Selected version string (16.0.x.y), or $null if cancelled.
    #>
    $bg = Get-ThemeColor 'WindowBackground'
    $fg = Get-ThemeColor 'TextForeground'
    $ctrlBg = Get-ThemeColor 'ControlBackground'
    $ctrlBorder = Get-ThemeColor 'ControlBorder'
    $err = Get-ThemeColor 'ErrorText'
    $accent = $script:Window.FindResource('AccentBrush')

    $dlg = New-Object System.Windows.Window
    $dlg.Title = 'Select Product Version'
    $dlg.Width = 460
    $dlg.Height = 360
    $dlg.WindowStartupLocation = 'CenterOwner'
    $dlg.Owner = $script:Window
    $dlg.Background = $bg
    $dlg.Foreground = $fg
    $dlg.FontFamily = 'Segoe UI'
    $dlg.FontSize = 13

    $root = New-Object System.Windows.Controls.StackPanel
    $root.Margin = New-Object System.Windows.Thickness(16)

    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = 'Product Version'
    $title.FontSize = 15
    $title.FontWeight = 'SemiBold'
    $title.Foreground = $fg
    [void]$root.Children.Add($title)

    $presets = @('16.0.20228.20186 — Windows 10/11', '16.0.15601.20538 — Windows 8/8.1', '16.0.12527.22286 — Windows 7')
    $radios = @()
    foreach ($p in $presets) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Content = $p
        $rb.Foreground = $fg
        $rb.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
        [void]$root.Children.Add($rb)
        $radios += $rb
    }
    $radios[0].IsChecked = $true

    $customRb = New-Object System.Windows.Controls.RadioButton
    $customRb.Content = 'Custom Version'
    $customRb.Foreground = $fg
    $customRb.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
    [void]$root.Children.Add($customRb)

    $customBox = New-Object System.Windows.Controls.TextBox
    $customBox.Width = 220
    $customBox.Height = 26
    $customBox.Margin = New-Object System.Windows.Thickness(24, 4, 0, 0)
    $customBox.HorizontalAlignment = 'Left'
    $customBox.Background = $ctrlBg
    $customBox.Foreground = $fg
    $customBox.BorderBrush = $ctrlBorder
    $customBox.Text = '16.0.xxxxx.xxxxx'
    [void]$root.Children.Add($customBox)

    $errorText = New-Object System.Windows.Controls.TextBlock
    $errorText.Foreground = $err
    $errorText.FontSize = 12
    $errorText.Margin = New-Object System.Windows.Thickness(24, 4, 0, 0)
    $errorText.Text = ''
    [void]$root.Children.Add($errorText)

    $btnPanel = New-Object System.Windows.Controls.StackPanel
    $btnPanel.Orientation = 'Horizontal'
    $btnPanel.HorizontalAlignment = 'Right'
    $btnPanel.Margin = New-Object System.Windows.Thickness(0, 16, 0, 0)

    $okBtn = New-Object System.Windows.Controls.Button
    $okBtn.Content = 'OK'
    $okBtn.Width = 80
    $okBtn.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
    $okBtn.Background = $accent
    $okBtn.Foreground = [System.Windows.Media.Brushes]::White
    $okBtn.FontWeight = 'SemiBold'
    [void]$btnPanel.Children.Add($okBtn)

    $cancelBtn = New-Object System.Windows.Controls.Button
    $cancelBtn.Content = 'Cancel'
    $cancelBtn.Width = 80
    $cancelBtn.Background = $ctrlBg
    $cancelBtn.Foreground = $fg
    $cancelBtn.BorderBrush = $ctrlBorder
    [void]$btnPanel.Children.Add($cancelBtn)

    [void]$root.Children.Add($btnPanel)
    $dlg.Content = $root

    $okBtn.Add_Click({
        $selected = $null
        if ($customRb.IsChecked) {
            $selected = $customBox.Text.Trim()
            if ($selected -notmatch '^16\.0\.\d+\.\d+$') {
                $errorText.Text = 'Invalid Office version format. Expected: 16.0.<build>.<revision>'
                return
            }
        } else {
            for ($i = 0; $i -lt $radios.Count; $i++) {
                if ($radios[$i].IsChecked) {
                    $selected = ($presets[$i] -split ' ')[0]
                    break
                }
            }
        }
        $script:SelectedVersion = $selected
        $dlg.DialogResult = $true
    })
    $cancelBtn.Add_Click({ $dlg.DialogResult = $false })

    $dlg.ShowDialog() | Out-Null
    if ($dlg.DialogResult) { return $script:SelectedVersion }
    return $null
}

function Show-ChannelInfoDialog {
    <#
    .SYNOPSIS
        Shows the "Office Update Channels" information dialog.
    #>
    $bg = Get-ThemeColor 'WindowBackground'
    $fg = Get-ThemeColor 'TextForeground'
    $sec = Get-ThemeColor 'TextSecondary'
    $ctrlBg = Get-ThemeColor 'ControlBackground'
    $ctrlBorder = Get-ThemeColor 'ControlBorder'

    $dlg = New-Object System.Windows.Window
    $dlg.Title = 'Office Update Channels'
    $dlg.Width = 460
    $dlg.Height = 480
    $dlg.WindowStartupLocation = 'CenterOwner'
    $dlg.Owner = $script:Window
    $dlg.Background = $bg
    $dlg.Foreground = $fg
    $dlg.FontFamily = 'Segoe UI'
    $dlg.FontSize = 13

    $root = New-Object System.Windows.Controls.StackPanel
    $root.Margin = New-Object System.Windows.Thickness(16)

    $channels = @(
        @{ Name = 'Current'; Desc = 'Latest broadly available Office updates.' },
        @{ Name = 'Monthly Enterprise'; Desc = 'Monthly update cadence intended for enterprise deployment.' },
        @{ Name = 'Semi-Annual'; Desc = 'Longer validation cycle for enterprise environments.' },
        @{ Name = 'Semi-Annual Preview'; Desc = 'Preview channel for upcoming Semi-Annual updates.' },
        @{ Name = 'PerpetualVL2019'; Desc = 'Office LTSC 2019 volume channel.' },
        @{ Name = 'PerpetualVL2021'; Desc = 'Office LTSC 2021 volume channel.' },
        @{ Name = 'PerpetualVL2024'; Desc = 'Office LTSC 2024 volume channel.' }
    )
    foreach ($c in $channels) {
        $name = New-Object System.Windows.Controls.TextBlock
        $name.Text = $c.Name
        $name.FontWeight = 'SemiBold'
        $name.Foreground = $fg
        $name.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)
        [void]$root.Children.Add($name)
        $desc = New-Object System.Windows.Controls.TextBlock
        $desc.Text = $c.Desc
        $desc.Foreground = $sec
        $desc.FontSize = 12
        $desc.TextWrapping = 'Wrap'
        [void]$root.Children.Add($desc)
    }

    $closeBtn = New-Object System.Windows.Controls.Button
    $closeBtn.Content = 'Close'
    $closeBtn.Width = 90
    $closeBtn.HorizontalAlignment = 'Right'
    $closeBtn.Margin = New-Object System.Windows.Thickness(0, 16, 0, 0)
    $closeBtn.Background = $ctrlBg
    $closeBtn.Foreground = $fg
    $closeBtn.BorderBrush = $ctrlBorder
    $closeBtn.Add_Click({ $dlg.Close() })
    [void]$root.Children.Add($closeBtn)

    $dlg.Content = $root
    $dlg.ShowDialog() | Out-Null
}

function Show-ErrorDialog {
    <#
    .SYNOPSIS
        Shows a structured "Operation Failed" dialog with details and log path.
    .PARAMETER Operation
        e.g. 'Download', 'Install', 'Uninstall', 'ISO creation'.
    .PARAMETER ExitCode
        Process exit code (may be $null).
    .PARAMETER Details
        Human-readable failure detail.
    #>
    param([string]$Operation, [int]$ExitCode, [string]$Details)
    $bg = Get-ThemeColor 'WindowBackground'
    $fg = Get-ThemeColor 'TextForeground'
    $sec = Get-ThemeColor 'TextSecondary'
    $err = Get-ThemeColor 'ErrorText'
    $ctrlBg = Get-ThemeColor 'ControlBackground'
    $ctrlBorder = Get-ThemeColor 'ControlBorder'

    $dlg = New-Object System.Windows.Window
    $dlg.Title = 'Operation Failed'
    $dlg.Width = 480
    $dlg.Height = 380
    $dlg.WindowStartupLocation = 'CenterOwner'
    $dlg.Owner = $script:Window
    $dlg.Background = $bg
    $dlg.Foreground = $fg
    $dlg.FontFamily = 'Segoe UI'
    $dlg.FontSize = 13

    $root = New-Object System.Windows.Controls.StackPanel
    $root.Margin = New-Object System.Windows.Thickness(16)

    $warn = New-Object System.Windows.Controls.TextBlock
    $warn.Text = "⚠  $Operation failed."
    $warn.FontSize = 18
    $warn.FontWeight = 'Bold'
    $warn.Foreground = $err
    [void]$root.Children.Add($warn)

    $detail = New-Object System.Windows.Controls.TextBlock
    $detail.Text = "Details:`n$Details"
    $detail.Foreground = $fg
    $detail.TextWrapping = 'Wrap'
    $detail.Margin = New-Object System.Windows.Thickness(0, 12, 0, 0)
    [void]$root.Children.Add($detail)

    if ($null -ne $ExitCode) {
        $ec = New-Object System.Windows.Controls.TextBlock
        $ec.Text = "Exit Code: $ExitCode"
        $ec.Foreground = $sec
        $ec.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
        [void]$root.Children.Add($ec)
    }

    $log = New-Object System.Windows.Controls.TextBlock
    $log.Text = "Log:`n$script:LogDir"
    $log.Foreground = $sec
    $log.FontSize = 12
    $log.TextWrapping = 'Wrap'
    $log.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
    [void]$root.Children.Add($log)

    $closeBtn = New-Object System.Windows.Controls.Button
    $closeBtn.Content = 'Close'
    $closeBtn.Width = 90
    $closeBtn.HorizontalAlignment = 'Right'
    $closeBtn.Margin = New-Object System.Windows.Thickness(0, 16, 0, 0)
    $closeBtn.Background = $ctrlBg
    $closeBtn.Foreground = $fg
    $closeBtn.BorderBrush = $ctrlBorder
    $closeBtn.Add_Click({ $dlg.Close() })
    [void]$root.Children.Add($closeBtn)

    $dlg.Content = $root
    $dlg.ShowDialog() | Out-Null
}

function Launch-OfficeApp {
    <#
    .SYNOPSIS
        Launches an installed Office application by its executable name.
    #>
    param([string]$App)
    $exeMap = @{
        'Word' = 'winword.exe'
        'Excel' = 'excel.exe'
        'PowerPoint' = 'powerpnt.exe'
        'Outlook' = 'outlook.exe'
        'OneNote' = 'onenote.exe'
        'Access' = 'msaccess.exe'
        'Publisher' = 'mspub.exe'
        'Project' = 'winproj.exe'
        'Visio' = 'visio.exe'
    }
    $exe = $exeMap[$App]
    if (-not $exe) { Write-Log "Unknown Office app: $App" 'ERROR'; return }
    try {
        Start-Process $exe
        Write-Log "Launched $App" 'OK'
    } catch {
        Write-Log "Could not launch $App : $($_.Exception.Message)" 'ERROR'
    }
}

function Check-Odt {
    <#
    .SYNOPSIS
        Reports whether the ODT setup.exe is cached and its version.
    #>
    $setupExe = Join-Path $script:OdtCacheDir 'setup.exe'
    if (Test-Path $setupExe) {
        $vi = (Get-Item $setupExe).VersionInfo
        Write-Log "ODT found: $setupExe (version $($vi.FileVersion))" 'OK'
    } else {
        Write-Log "ODT not cached at $setupExe. It will be downloaded on first use." 'WARN'
    }
}

function Open-LogFolder {
    <#
    .SYNOPSIS
        Opens the persistent log folder in Explorer.
    #>
    if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null }
    Start-Process explorer.exe $script:LogDir
    Write-Log "Opened log folder: $script:LogDir" 'INFO'
}

function Open-DownloadFolder {
    <#
    .SYNOPSIS
        Opens the last successful download folder in Explorer.
    #>
    if ($script:LastDownloadFolder -and (Test-Path $script:LastDownloadFolder)) {
        Start-Process explorer.exe $script:LastDownloadFolder
        Write-Log "Opened download folder: $script:LastDownloadFolder" 'INFO'
    } else {
        Write-Log 'No download folder yet. Run a download first.' 'WARN'
    }
}

function Cancel-BackgroundJob {
    <#
    .SYNOPSIS
        Cancels the running background operation: stops the ODT setup.exe process
        and the runspace, then restores the UI.
    #>
    if (-not $script:Job.Running) { return }
    Write-Log 'Cancelling the running operation...' 'WARN'
    # Stop the ODT process (setup.exe) started by this app.
    Get-Process -Name 'setup' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    if ($script:Job.PowerShell) {
        try { $script:Job.PowerShell.Stop() } catch { }
    }
    $kind = $script:Job.Kind
    $script:Job.Running = $false
    $script:Job.PowerShell = $null
    $script:Job.AsyncResult = $null
    Set-UiBusy $false
    Update-ButtonStates
    if ($kind -eq 'download') { Set-DownloadUiState 'cancelled' }
    Write-Log 'Operation cancelled.' 'WARN'
}

function Set-DownloadUiState {
    <#
    .SYNOPSIS
        Updates the Download tab's progress/cancel/status controls for a state.
    .PARAMETER State
        'idle' | 'downloading' | 'complete' | 'failed' | 'cancelled'.
    #>
    param([string]$State)
    $cancelBtn = Get-Ui 'CancelDownloadBtn'
    $progress = Get-Ui 'DownloadProgress'
    $status = Get-Ui 'DownloadStatusText'
    $progressText = Get-Ui 'DownloadProgressText'
    $speedText = Get-Ui 'DownloadSpeedText'
    if ($State -eq 'downloading') {
        if ($cancelBtn) { $cancelBtn.Visibility = 'Visible' }
        if ($progress) { $progress.Visibility = 'Visible' }
        if ($status) { $status.Text = 'Status: Downloading Office source files...' }
    } else {
        if ($cancelBtn) { $cancelBtn.Visibility = 'Collapsed' }
        if ($progress) { $progress.Visibility = 'Collapsed' }
        if ($progressText) { $progressText.Text = '' }
        if ($speedText) { $speedText.Text = '' }
        if ($status) {
            $status.Text = switch ($State) {
                'complete'   { 'Status: Download completed.' }
                'failed'     { 'Status: Download failed.' }
                'cancelled'  { 'Status: Download cancelled.' }
                default      { 'Status: Ready' }
            }
        }
    }
}

function Update-DownloadProgress {
    <#
    .SYNOPSIS
        Samples the download destination folder size and updates the progress UI
        (downloaded size + speed). ODT does not report a total size, so the bar
        stays indeterminate.
    #>
    $dest = $script:LastDownloadDest
    if (-not $dest -or -not (Test-Path $dest)) { return }
    $size = (Get-ChildItem -Path $dest -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $size) { $size = 0 }
    $now = Get-Date
    $speed = 0
    if ($script:DownloadLastTime -and $script:DownloadLastSize -ge 0) {
        $dt = ($now - $script:DownloadLastTime).TotalSeconds
        if ($dt -gt 0) { $speed = ($size - $script:DownloadLastSize) / $dt }
    }
    $script:DownloadLastSize = $size
    $script:DownloadLastTime = $now

    $sizeText = '{0:N2} MB' -f ($size / 1MB)
    $speedText = if ($speed -gt 0) { '{0:N2} MiB/s' -f ($speed / 1MB) } else { '—' }
    $pt = Get-Ui 'DownloadProgressText'
    if ($pt) { $pt.Text = "Downloaded: $sizeText" }
    $st = Get-Ui 'DownloadSpeedText'
    if ($st) { $st.Text = "Download speed: $speedText" }
}

# ============================================================================
# Action handlers
# ============================================================================

function Start-Install {
    <#
    .SYNOPSIS
        Builds an Add config from the current selections and runs setup.exe
        /configure. Elevates on demand (only here, not at app launch).
    #>
    $useIndividual = (Get-Ui 'InstallIndividualCheck').IsChecked
    $languages = Get-SelectedLanguages
    $arch = Get-SelectedArchitecture
    $channel = Get-SelectedChannel
    $editionId = Get-SelectedEditionId

    # Validate the offline source BEFORE building the config. If the user asked
    # for an offline install but the folder is missing/invalid, abort rather than
    # silently falling back to an online install.
    $offlinePath = Get-OfflineSourcePath
    if ($offlinePath -eq 'INVALID') { return }

    # Note: a product version is only pinned for offline downloads; an online
    # install uses the channel's default/latest version, so no <Version> is set.
    if ($useIndividual) {
        if (-not (Test-VolumeChannelMismatch)) { return }
        $apps = Get-SelectedIndividualApps
        $config = New-OdtConfigXml -EditionId $editionId -Architecture $arch -Channel $channel -Languages $languages -IndividualApps $apps -UseIndividualApps -SourcePath $offlinePath
    } else {
        $excluded = Get-ExcludedApps
        $config = New-OdtConfigXml -EditionId $editionId -Architecture $arch -Channel $channel -Languages $languages -ExcludedApps $excluded -SourcePath $offlinePath
    }

    if (-not $config) { return }

    $configPath = Join-Path $env:TEMP ("office-install-{0}.xml" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $config | Set-Content -Path $configPath -Encoding UTF8
    Write-Log "Config written to $configPath" 'INFO'

    if (-not (Confirm-Elevation)) {
        # Installing requires admin. Relaunch ourselves elevated with the pending
        # config so the user doesn't have to redo their selections.
        $scriptPath = Get-ScriptPath
        if (-not $scriptPath) {
            Write-Log 'Cannot determine the script path to relaunch elevated. Run this script from a file.' 'ERROR'
            return
        }
        Write-Log 'Requesting administrator privileges to install...' 'INFO'
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"", '-PendingConfig', "`"$configPath`"", '-PendingAction', 'install')
        Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Verb RunAs
        $script:Window.Close()
        return
    }

    Start-InstallFromConfig -ConfigPath $configPath
}

function Start-InstallFromConfig {
    <#
    .SYNOPSIS
        Runs setup.exe /configure against an existing config file (used by the
        Install button when already elevated, and by the elevated relaunch).
        ODT acquisition (download/extract) and setup.exe both run in the
        background runspace so the UI never freezes.
    #>
    param([string]$ConfigPath)
    if (-not (Test-Path $ConfigPath)) {
        Write-Log "Config not found: $ConfigPath" 'ERROR'
        return
    }
    Set-UiBusy $true
    Start-BackgroundJob -Kind 'install' -Script $script:OdtJobScript -Arguments @($script:OdtAcquireScript, $script:OdtRunScript, $ConfigPath, 'configure', $script:OdtCacheDir, $script:OdtDownloadPage, $script:OdtUrlFile) -OdtLogDir $script:OdtLogDir
}

function Start-Uninstall {
    <#
    .SYNOPSIS
        Builds a Remove config and runs setup.exe /configure. Requires explicit
        user confirmation (destructive action) and elevation.
    #>
    $res = [System.Windows.MessageBox]::Show($script:Window, 'This will remove all Click-to-Run Office products from this machine. Continue?', 'Uninstall Office', 'YesNo', 'Warning')
    if ($res -ne 'Yes') { return }

    $config = New-OdtConfigXml -Action RemoveAll
    if (-not $config) { return }
    $configPath = Join-Path $env:TEMP ("office-uninstall-{0}.xml" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $config | Set-Content -Path $configPath -Encoding UTF8
    Write-Log "Uninstall config written to $configPath" 'INFO'

    if (-not (Confirm-Elevation)) {
        $scriptPath = Get-ScriptPath
        if (-not $scriptPath) {
            Write-Log 'Cannot determine the script path to relaunch elevated. Run this script from a file.' 'ERROR'
            return
        }
        Write-Log 'Requesting administrator privileges to uninstall...' 'INFO'
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"", '-PendingConfig', "`"$configPath`"", '-PendingAction', 'uninstall')
        Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Verb RunAs
        $script:Window.Close()
        return
    }

    Start-UninstallFromConfig -ConfigPath $configPath
}

function Start-UninstallFromConfig {
    <#
    .SYNOPSIS
        Runs setup.exe /configure against a Remove config (used when already
        elevated, and by the elevated relaunch). ODT acquisition and setup.exe
        both run in the background runspace so the UI never freezes.
    #>
    param([string]$ConfigPath)
    if (-not (Test-Path $ConfigPath)) {
        Write-Log "Config not found: $ConfigPath" 'ERROR'
        return
    }
    Set-UiBusy $true
    Start-BackgroundJob -Kind 'uninstall' -Script $script:OdtJobScript -Arguments @($script:OdtAcquireScript, $script:OdtRunScript, $ConfigPath, 'configure', $script:OdtCacheDir, $script:OdtDownloadPage, $script:OdtUrlFile) -OdtLogDir $script:OdtLogDir
}

function Get-OfflineSourcePath {
    <#
    .SYNOPSIS
        Returns the offline source folder, or $null if offline source is not
        requested. If offline source IS requested but the folder is missing or
        invalid, logs an error and returns the sentinel 'INVALID' so the caller
        aborts instead of silently falling back to an online install.
    #>
    $check = Get-Ui 'InstallOfflineCheck'
    if (-not $check -or -not $check.IsChecked) { return $null }
    $box = Get-Ui 'InstallOfflinePathBox'
    $path = $box.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($path)) {
        Write-Log 'Offline source is checked but no folder was entered. Aborting the install.' 'ERROR'
        return 'INVALID'
    }
    if (-not (Test-Path $path)) {
        Write-Log "Offline source folder does not exist: $path. Aborting the install." 'ERROR'
        return 'INVALID'
    }
    return $path
}

function Start-Download {
    <#
    .SYNOPSIS
        Builds an Add config with SourcePath = destination and runs setup.exe
        /download. No elevation needed.
    .NOTES
        The "Download files in one stream" checkbox is retained for UI parity
        with the visual reference, but ODT does not expose a single-vs-multi-
        thread download switch, so it is informational only and does not change
        the ODT invocation.
    #>
    $destBox = Get-Ui 'DownloadDestBox'
    $dest = $destBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($dest)) {
        Write-Log 'Please choose a destination folder for the download.' 'ERROR'
        return
    }
    # Validate the path before it goes anywhere near a command line. Reject the
    # command-injection-relevant characters; array-arg quoting handles spaces and
    # most other characters safely.
    $invalidChars = [char[]]@('&', '|', ';', '`', '"', "'")
    if ($dest.IndexOfAny($invalidChars) -ge 0) {
        Write-Log 'Destination folder contains invalid characters (& | ; backtick or quotes).' 'ERROR'
        return
    }
    if (-not (Test-Path $dest)) {
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
    }

    $languages = Get-SelectedLanguages
    $arch = Get-SelectedArchitecture
    $channel = Get-SelectedChannel
    $editionId = Get-SelectedEditionId
    $version = Get-SelectedVersion

    $config = New-OdtConfigXml -EditionId $editionId -Architecture $arch -Channel $channel -Languages $languages -SourcePath $dest -Version $version
    if (-not $config) { return }

    $configPath = Join-Path $env:TEMP ("office-download-{0}.xml" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $config | Set-Content -Path $configPath -Encoding UTF8
    Write-Log "Download config written to $configPath" 'INFO'

    $script:LastDownloadDest = $dest
    $script:DownloadLastSize = 0
    $script:DownloadLastTime = $null
    Set-DownloadUiState 'downloading'
    Set-UiBusy $true
    Start-BackgroundJob -Kind 'download' -Script $script:OdtJobScript -Arguments @($script:OdtAcquireScript, $script:OdtRunScript, $configPath, 'download', $script:OdtCacheDir, $script:OdtDownloadPage, $script:OdtUrlFile) -OdtLogDir $script:OdtLogDir
}

function Start-CreateIso {
    <#
    .SYNOPSIS
        Builds an ISO from the last successful download folder. Only enabled after
        a successful download.
    #>
    if (-not $script:LastDownloadFolder -or -not (Test-Path $script:LastDownloadFolder)) {
        Write-Log 'No downloaded source folder available. Run a download first.' 'ERROR'
        return
    }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'ISO image (*.iso)|*.iso'
    $dlg.FileName = 'OfficeOffline.iso'
    $dlg.Title = 'Save ISO image'
    if ($dlg.ShowDialog($script:Window)) {
        $isoPath = $dlg.FileName
        Set-UiBusy $true
        Start-BackgroundJob -Kind 'iso' -Script $script:IsoJobScript -Arguments @($script:IsoLogicScript, $script:LastDownloadFolder, $isoPath, 'OfficeOffline') -OdtLogDir $null
    }
}

function Show-InstalledStatus {
    <#
    .SYNOPSIS
        Read-only status check. No elevation needed.
    #>
    $summary = Test-OfficeInstalled
    Write-Log "Installed status checked." 'INFO'
    [System.Windows.MessageBox]::Show($script:Window, $summary, 'Installed Office Status', 'OK', 'Information') | Out-Null
}

function Start-KmsActivation {
    <#
    .SYNOPSIS
        Points an already volume-licensed Office install at an organization KMS
        host using Microsoft's own ospp.vbs. No key injection, no channel
        conversion — this only works with a genuinely volume-licensed product.
        Runs in a background runspace so the UI stays responsive.
    #>
    $hostBox = Get-Ui 'KmsHostBox'
    $kmsHost = $hostBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($kmsHost)) {
        Write-Log 'Enter a KMS host FQDN or IP address first.' 'ERROR'
        return
    }
    $ospp = "$env:ProgramFiles\Microsoft Office\Office16\ospp.vbs"
    if (-not (Test-Path $ospp)) {
        Write-Log "ospp.vbs not found at $ospp. A volume-licensed Office install is required." 'ERROR'
        return
    }
    Set-UiBusy $true
    Start-BackgroundJob -Kind 'kms' -Script $script:KmsJobScript -Arguments @($ospp, $kmsHost) -OdtLogDir $null
}

# ============================================================================
# Event wiring
# ============================================================================

function Get-ScriptPath {
    <#
    .SYNOPSIS
        Returns the full path of this script, or $null if it can't be determined
        (e.g. running via irm | iex, which the GUI does not support).
    #>
    if ($PSCommandPath) { return $PSCommandPath }
    if ($MyInvocation.MyCommand.Path) { return $MyInvocation.MyCommand.Path }
    return $null
}

function Wire-Events {
    <#
    .SYNOPSIS
        Attaches all event handlers to the loaded window's controls.
    #>

    # --- Theme toggle ---
    (Get-Ui 'DarkThemeCheck').Add_Checked({ Set-AppTheme -Dark $true })
    (Get-Ui 'DarkThemeCheck').Add_Unchecked({ Set-AppTheme -Dark $false })

    # --- Main Window: individual-apps (Single Products) mode toggle ---
    (Get-Ui 'InstallIndividualCheck').Add_Checked({
        (Get-Ui 'IndividualAppsBorder').Visibility = 'Visible'
        (Get-Ui 'SuiteAppsBorder').Visibility = 'Collapsed'
        Update-ButtonStates
    })
    (Get-Ui 'InstallIndividualCheck').Add_Unchecked({
        (Get-Ui 'IndividualAppsBorder').Visibility = 'Collapsed'
        (Get-Ui 'SuiteAppsBorder').Visibility = 'Visible'
        Update-ButtonStates
    })

    # --- Main Window: offline source toggle ---
    (Get-Ui 'InstallOfflineCheck').Add_Checked({ (Get-Ui 'OfflineSourcePanel').Visibility = 'Visible' })
    (Get-Ui 'InstallOfflineCheck').Add_Unchecked({ (Get-Ui 'OfflineSourcePanel').Visibility = 'Collapsed' })

    # --- Browse buttons ---
    (Get-Ui 'InstallOfflineBrowseBtn').Add_Click({
        $folder = Show-FolderPicker
        if ($folder) { (Get-Ui 'InstallOfflinePathBox').Text = $folder }
    })
    (Get-Ui 'DownloadDestBrowseBtn').Add_Click({
        $folder = Show-FolderPicker
        if ($folder) { (Get-Ui 'DownloadDestBox').Text = $folder }
    })

    # --- Main Window: Product Family filters the Edition dropdown ---
    (Get-Ui 'InstallFamilyCombo').Add_SelectionChanged({
        if ($script:SyncingEdition) { return }
        $script:SyncingEdition = $true
        try {
            $family = $this.SelectedItem.Tag
            Populate-EditionCombo (Get-Ui 'InstallEditionCombo') -FamilyName $family
            Populate-EditionCombo (Get-Ui 'DownloadEditionCombo') -FamilyName $family
        } finally { $script:SyncingEdition = $false }
        Update-ButtonStates
    })

    # --- Main Window: Channel info ---
    (Get-Ui 'ChannelInfoBtn').Add_Click({ Show-ChannelInfoDialog })

    # --- Download: Product Version (offline packages are version-specific) ---
    (Get-Ui 'DownloadVersionCombo').Add_SelectionChanged({
        if ($script:SyncingVersion) { return }
        $item = $this.SelectedItem
        if ($item) { $script:SelectedVersion = $item.Tag }
    })
    (Get-Ui 'VersionSelectBtn').Add_Click({
        $v = Show-ProductVersionDialog
        if ($v) { Set-SelectedVersion -Version $v; Write-Log "Product version set to $v" 'INFO' }
    })

    # --- Action buttons ---
    (Get-Ui 'InstallBtn').Add_Click({ Start-Install })
    (Get-Ui 'UninstallBtn').Add_Click({ Start-Uninstall })
    (Get-Ui 'StatusBtn').Add_Click({ Show-InstalledStatus })
    (Get-Ui 'DownloadBtn').Add_Click({ Start-Download })
    (Get-Ui 'CancelDownloadBtn').Add_Click({ Cancel-BackgroundJob })
    (Get-Ui 'CreateIsoBtn').Add_Click({ Start-CreateIso })

    # --- Utilities: launch Office apps ---
    foreach ($app in @('Word', 'Excel', 'PowerPoint', 'Outlook', 'OneNote', 'Access', 'Publisher', 'Project', 'Visio')) {
        $btn = Get-Ui ("Launch{0}Btn" -f $app)
        if ($btn) { $btn.Add_Click({ Launch-OfficeApp -App $app }) }
    }

    # --- Utilities: diagnostics ---
    (Get-Ui 'CheckInstallBtn').Add_Click({ Show-InstalledStatus })
    (Get-Ui 'CheckOdtBtn').Add_Click({ Check-Odt })
    (Get-Ui 'OpenLogFolderBtn').Add_Click({ Open-LogFolder })
    (Get-Ui 'OpenDownloadFolderBtn').Add_Click({ Open-DownloadFolder })

    # Refresh app-launcher availability whenever the Utilities tab is shown.
    (Get-Ui 'MainTabs').Add_SelectionChanged({
        $tab = $this.SelectedItem
        if ($tab -and $tab.Header -eq 'Utilities and Settings') { Update-UtilityButtons }
    })

    # --- About tab ---
    (Get-Ui 'OdtDocsLink').Add_Click({ Start-Process $script:OdtDocsUrl })
    (Get-Ui 'KmsToggleCheck').Add_Checked({ (Get-Ui 'KmsSection').Visibility = 'Visible' })
    (Get-Ui 'KmsToggleCheck').Add_Unchecked({ (Get-Ui 'KmsSection').Visibility = 'Collapsed' })
    (Get-Ui 'KmsActivateBtn').Add_Click({ Start-KmsActivation })

    # --- Cross-tab state sync (Main Window <-> Download must never disagree) ---
    $installEdition = Get-Ui 'InstallEditionCombo'
    $downloadEdition = Get-Ui 'DownloadEditionCombo'
    $installEdition.Add_SelectionChanged({
        if ($script:SyncingEdition) { return }
        $script:SyncingEdition = $true
        try { (Get-Ui 'DownloadEditionCombo').SelectedIndex = $this.SelectedIndex } finally { $script:SyncingEdition = $false }
        Update-ButtonStates
    })
    $downloadEdition.Add_SelectionChanged({
        if ($script:SyncingEdition) { return }
        $script:SyncingEdition = $true
        try { (Get-Ui 'InstallEditionCombo').SelectedIndex = $this.SelectedIndex } finally { $script:SyncingEdition = $false }
        Update-ButtonStates
    })

    # Channel is selected only on the Main Window; offline packages don't pick a
    # channel, so the download uses the Main Window's channel selection.

    # Architecture: Install radios <-> Download combo.
    (Get-Ui 'InstallArch64Radio').Add_Checked({
        if ($script:SyncingArch) { return }
        $script:SyncingArch = $true
        try { (Get-Ui 'DownloadArchCombo').SelectedIndex = 0 } finally { $script:SyncingArch = $false }
    })
    (Get-Ui 'InstallArch32Radio').Add_Checked({
        if ($script:SyncingArch) { return }
        $script:SyncingArch = $true
        try { (Get-Ui 'DownloadArchCombo').SelectedIndex = 1 } finally { $script:SyncingArch = $false }
    })
    (Get-Ui 'DownloadArchCombo').Add_SelectionChanged({
        if ($script:SyncingArch) { return }
        $script:SyncingArch = $true
        try {
            if ($this.SelectedIndex -eq 1) { (Get-Ui 'InstallArch32Radio').IsChecked = $true }
            else { (Get-Ui 'InstallArch64Radio').IsChecked = $true }
        } finally { $script:SyncingArch = $false }
    })

    # --- Window close: stop the timer and clean up the runspace ---
    $script:Window.Add_Closed({
        if ($script:PollTimer) { $script:PollTimer.Stop() }
        if ($script:Job.Running -and $script:Job.PowerShell) {
            try { $script:Job.PowerShell.Stop() } catch { }
        }
    })
}

# ============================================================================
# Main
# ============================================================================

# Load WPF assemblies (present on every stock Windows 10/11).
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# Load settings (theme persistence).
if (Test-Path $script:SettingsFile) {
    try {
        $loaded = Get-Content -Path $script:SettingsFile -Raw | ConvertFrom-Json
        if ($null -ne $loaded.DarkTheme) { $script:Settings.DarkTheme = [bool]$loaded.DarkTheme }
    } catch { }
}

# Load XAML from the file next to this script; fall back to the inline copy.
$script:XamlPath = Join-Path $PSScriptRoot 'MainWindow.xaml'
$xaml = $null
if (Test-Path $script:XamlPath) {
    $xaml = Get-Content -Path $script:XamlPath -Raw
} else {
    $xaml = $script:InlineXaml
}

try {
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
    $script:Window = [System.Windows.Markup.XamlReader]::Load($reader)
} catch {
    Write-Host "Failed to load the window XAML: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host 'Press Enter to exit'
    exit 1
}

# Capture the theme dictionaries now, while both are still in the merged
# collection (see Set-AppTheme for why we keep our own references). We identify
# each dictionary by its WindowBackground brush color rather than relying on the
# Resources indexer, which is the most robust way to tell them apart.
foreach ($d in $script:Window.Resources.MergedDictionaries) {
    $wb = $d['WindowBackground']
    if ($wb) {
        $color = $wb.Color.ToString()
        if ($color -eq '#FF1E1E1E') { $script:DarkThemeDict = $d }
        elseif ($color -eq '#FFF5F5F5') { $script:LightThemeDict = $d }
    }
}

# Populate controls.
Populate-FamilyCombo (Get-Ui 'InstallFamilyCombo')
Populate-EditionCombo (Get-Ui 'InstallEditionCombo') -FamilyName 'Microsoft 365'
Populate-EditionCombo (Get-Ui 'DownloadEditionCombo') -FamilyName 'Microsoft 365'
Populate-ChannelCombo (Get-Ui 'InstallChannelCombo')
Populate-VersionCombo (Get-Ui 'DownloadVersionCombo')
Populate-AppLists
Populate-LanguageLists

# Populate the Download tab's architecture combo (x64/x86).
$archCombo = Get-Ui 'DownloadArchCombo'
$archCombo.Items.Clear()
foreach ($a in @('x64', 'x86')) {
    $item = New-Object System.Windows.Controls.ComboBoxItem
    $item.Content = $a
    $item.Tag = $a
    [void]$archCombo.Items.Add($item)
}
$archCombo.SelectedIndex = 0

# About tab paths.
(Get-Ui 'AboutVersionText').Text = "Version $script:AppVersion"
(Get-Ui 'AboutCachePath').Text = "ODT cache: $script:OdtCacheDir"
(Get-Ui 'AboutLogPath').Text = "Logs: $script:LogDir"

# Wire events.
Wire-Events

# Apply validity gating to the action buttons (initial state).
Update-ButtonStates

# Enable only the app launchers for installed Office products.
Update-UtilityButtons

# Apply persisted theme.
(Get-Ui 'DarkThemeCheck').IsChecked = $script:Settings.DarkTheme
Set-AppTheme -Dark $script:Settings.DarkTheme

# Show the ODT version if a cached setup.exe already exists.
Update-OdtVersionLabel

# Start the poll timer that drives the background job UI updates.
$script:PollTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:PollTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:PollTimer.Add_Tick({ Update-FromBackgroundJob })
$script:PollTimer.Start()

Write-Log "Application started. Cache: $script:OdtCacheDir" 'INFO'

# If this instance was relaunched elevated to finish a pending action, run it
# once the window is rendered.
if ($script:PendingConfig -and $script:PendingAction -and (Confirm-Elevation)) {
    $script:Window.Add_ContentRendered({
        if ($script:PendingAction -eq 'install') {
            Start-InstallFromConfig -ConfigPath $script:PendingConfig
        } elseif ($script:PendingAction -eq 'uninstall') {
            Start-UninstallFromConfig -ConfigPath $script:PendingConfig
        }
    })
}

# Show the window (blocks until closed).
$script:Window.ShowDialog() | Out-Null