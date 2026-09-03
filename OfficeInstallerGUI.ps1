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
$script:SyncingEdition    = $false  # guards against event recursion when syncing tabs
$script:SyncingArch       = $false
$script:SyncingChannel    = $false
$script:SyncingLanguages  = $false
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
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Office Installer GUI"
        Height="760" Width="1000"
        MinHeight="480" MinWidth="660"
        WindowStartupLocation="CenterScreen"
        Background="{DynamicResource WindowBackground}"
        FontFamily="Segoe UI" FontSize="13"
        Foreground="{DynamicResource TextForeground}">
    <Window.Resources>
        <ResourceDictionary>
            <ResourceDictionary.MergedDictionaries>
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
            <Style x:Key="FieldLabel" TargetType="TextBlock">
                <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
                <Setter Property="FontSize" Value="12"/>
                <Setter Property="Margin" Value="0,8,0,2"/>
            </Style>
        </ResourceDictionary>
    </Window.Resources>
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TabControl x:Name="MainTabs" Grid.Row="0">
            <TabItem Header="Install">
                <Grid Margin="12">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="190"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Margin="0,8,16,0" VerticalAlignment="Top">
                        <Border Width="110" Height="110" CornerRadius="18" Background="{DynamicResource AccentBrush}" HorizontalAlignment="Left">
                            <TextBlock Text="OFFICE" Foreground="White" FontSize="18" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <TextBlock Text="Office Installer" FontSize="20" FontWeight="Bold" Foreground="{DynamicResource TextForeground}" Margin="0,14,0,0" TextWrapping="Wrap"/>
                        <TextBlock Text="A GUI front-end for Microsoft's official Office Deployment Tool. It generates configuration.xml and runs setup.exe for you." FontSize="12" Foreground="{DynamicResource TextSecondary}" TextWrapping="Wrap" Margin="0,8,0,0"/>
                    </StackPanel>
                    <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto">
                        <StackPanel>
                            <TextBlock Text="Edition" Style="{StaticResource FieldLabel}"/>
                            <ComboBox x:Name="InstallEditionCombo" Height="28" Background="{DynamicResource ControlBackground}" Foreground="{DynamicResource TextForeground}" BorderBrush="{DynamicResource ControlBorder}"/>
                            <TextBlock Text="Architecture" Style="{StaticResource FieldLabel}"/>
                            <StackPanel Orientation="Horizontal">
                                <RadioButton x:Name="InstallArch64Radio" Content="64-bit (x64)" IsChecked="True" Foreground="{DynamicResource TextForeground}" Margin="0,0,20,0"/>
                                <RadioButton x:Name="InstallArch32Radio" Content="32-bit (x86)" Foreground="{DynamicResource TextForeground}"/>
                            </StackPanel>
                            <CheckBox x:Name="InstallIndividualCheck" Content="Install individual apps instead of the full suite" Foreground="{DynamicResource TextForeground}" Margin="0,10,0,0"/>
                            <StackPanel x:Name="YearSelectorPanel" Orientation="Horizontal" Margin="24,4,0,0" Visibility="Collapsed">
                                <TextBlock Text="Project / Visio year:" Foreground="{DynamicResource TextSecondary}" VerticalAlignment="Center"/>
                                <ComboBox x:Name="InstallYearCombo" Width="90" Height="26" Margin="8,0,0,0" Background="{DynamicResource ControlBackground}" Foreground="{DynamicResource TextForeground}" BorderBrush="{DynamicResource ControlBorder}"/>
                            </StackPanel>
                            <TextBlock x:Name="AppsLabel" Text="Applications (uncheck to exclude from the suite)" Style="{StaticResource FieldLabel}"/>
                            <Border x:Name="SuiteAppsBorder" BorderBrush="{DynamicResource ControlBorder}" BorderThickness="1" CornerRadius="4" Background="{DynamicResource ControlBackground}" Padding="6" MaxHeight="120">
                                <ScrollViewer VerticalScrollBarVisibility="Auto">
                                    <ItemsControl x:Name="SuiteAppsList"/>
                                </ScrollViewer>
                            </Border>
                            <Border x:Name="IndividualAppsBorder" BorderBrush="{DynamicResource ControlBorder}" BorderThickness="1" CornerRadius="4" Background="{DynamicResource ControlBackground}" Padding="6" MaxHeight="120" Visibility="Collapsed">
                                <ScrollViewer VerticalScrollBarVisibility="Auto">
                                    <ItemsControl x:Name="IndividualAppsList"/>
                                </ScrollViewer>
                            </Border>
                            <TextBlock Text="Channel" Style="{StaticResource FieldLabel}"/>
                            <ComboBox x:Name="InstallChannelCombo" Height="28" Background="{DynamicResource ControlBackground}" Foreground="{DynamicResource TextForeground}" BorderBrush="{DynamicResource ControlBorder}"/>
                            <TextBlock Text="Languages" Style="{StaticResource FieldLabel}"/>
                            <Border BorderBrush="{DynamicResource ControlBorder}" BorderThickness="1" CornerRadius="4" Background="{DynamicResource ControlBackground}" Padding="6" MaxHeight="130">
                                <ScrollViewer VerticalScrollBarVisibility="Auto">
                                    <ItemsControl x:Name="InstallLanguagesList"/>
                                </ScrollViewer>
                            </Border>
                            <CheckBox x:Name="InstallOfflineCheck" Content="Use offline source (install from a folder downloaded via the Download tab)" Foreground="{DynamicResource TextForeground}" Margin="0,10,0,0"/>
                            <StackPanel x:Name="OfflineSourcePanel" Orientation="Horizontal" Margin="24,4,0,0" Visibility="Collapsed">
                                <TextBox x:Name="InstallOfflinePathBox" Width="280" Height="26" VerticalContentAlignment="Center" Background="{DynamicResource ControlBackground}" Foreground="{DynamicResource TextForeground}" BorderBrush="{DynamicResource ControlBorder}"/>
                                <Button x:Name="InstallOfflineBrowseBtn" Content="Browse..." Style="{StaticResource SecondaryButton}" Padding="10,4"/>
                            </StackPanel>
                            <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
                                <Button x:Name="InstallBtn" Content="Install Office" Style="{StaticResource PrimaryButton}" MinWidth="140"/>
                                <Button x:Name="UninstallBtn" Content="Uninstall Office" Style="{StaticResource SecondaryButton}" MinWidth="140"/>
                                <Button x:Name="StatusBtn" Content="Check Installed Status" Style="{StaticResource SecondaryButton}" MinWidth="150"/>
                            </StackPanel>
                            <ProgressBar x:Name="InstallProgress" Height="6" IsIndeterminate="True" Visibility="Collapsed" Margin="4,8,4,0" Foreground="{DynamicResource AccentBrush}" Background="{DynamicResource ControlBackground}"/>
                        </StackPanel>
                    </ScrollViewer>
                </Grid>
            </TabItem>
            <TabItem Header="Download / Offline Package">
                <Grid Margin="12">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto">
                        <StackPanel>
                            <TextBlock x:Name="DownloadVersionLabel" Text="Office Deployment Tool version: (not yet resolved)" Foreground="{DynamicResource TextSecondary}" FontSize="12" Margin="0,0,0,6"/>
                            <TextBlock Text="Edition" Style="{StaticResource FieldLabel}"/>
                            <ComboBox x:Name="DownloadEditionCombo" Height="28" Background="{DynamicResource ControlBackground}" Foreground="{DynamicResource TextForeground}" BorderBrush="{DynamicResource ControlBorder}"/>
                            <TextBlock Text="Architecture" Style="{StaticResource FieldLabel}"/>
                            <StackPanel Orientation="Horizontal">
                                <RadioButton x:Name="DownloadArch64Radio" Content="64-bit (x64)" IsChecked="True" Foreground="{DynamicResource TextForeground}" Margin="0,0,20,0"/>
                                <RadioButton x:Name="DownloadArch32Radio" Content="32-bit (x86)" Foreground="{DynamicResource TextForeground}"/>
                            </StackPanel>
                            <TextBlock Text="Channel" Style="{StaticResource FieldLabel}"/>
                            <ComboBox x:Name="DownloadChannelCombo" Height="28" Background="{DynamicResource ControlBackground}" Foreground="{DynamicResource TextForeground}" BorderBrush="{DynamicResource ControlBorder}"/>
                            <TextBlock Text="Languages" Style="{StaticResource FieldLabel}"/>
                            <Border BorderBrush="{DynamicResource ControlBorder}" BorderThickness="1" CornerRadius="4" Background="{DynamicResource ControlBackground}" Padding="6" MaxHeight="110">
                                <ScrollViewer VerticalScrollBarVisibility="Auto">
                                    <ItemsControl x:Name="DownloadLanguagesList"/>
                                </ScrollViewer>
                            </Border>
                            <TextBlock Text="Destination folder (for the downloaded source files)" Style="{StaticResource FieldLabel}"/>
                            <StackPanel Orientation="Horizontal">
                                <TextBox x:Name="DownloadDestBox" Width="360" Height="26" VerticalContentAlignment="Center" Background="{DynamicResource ControlBackground}" Foreground="{DynamicResource TextForeground}" BorderBrush="{DynamicResource ControlBorder}"/>
                                <Button x:Name="DownloadDestBrowseBtn" Content="Browse..." Style="{StaticResource SecondaryButton}" Padding="10,4"/>
                            </StackPanel>
                            <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                                <Button x:Name="DownloadBtn" Content="Download Office (offline source)" Style="{StaticResource PrimaryButton}" MinWidth="220"/>
                                <Button x:Name="CreateIsoBtn" Content="Create ISO from downloaded source" Style="{StaticResource SecondaryButton}" MinWidth="220" IsEnabled="False"/>
                            </StackPanel>
                            <ProgressBar x:Name="DownloadProgress" Height="6" IsIndeterminate="True" Visibility="Collapsed" Margin="4,8,4,0" Foreground="{DynamicResource AccentBrush}" Background="{DynamicResource ControlBackground}"/>
                        </StackPanel>
                    </ScrollViewer>
                    <Grid Grid.Row="1" Margin="0,10,0,0">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <TextBlock Text="Console" Style="{StaticResource FieldLabel}" Margin="0,0,0,4"/>
                        <RichTextBox x:Name="DownloadLogBox" Grid.Row="1" IsReadOnly="True" VerticalScrollBarVisibility="Auto" Background="{DynamicResource LogBackground}" Foreground="{DynamicResource LogText}" BorderBrush="{DynamicResource ControlBorder}" BorderThickness="1" FontFamily="Consolas" FontSize="12"/>
                    </Grid>
                </Grid>
            </TabItem>
            <TabItem Header="About / Settings">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel Margin="20">
                        <TextBlock Text="Office Installer GUI" FontSize="26" FontWeight="Bold" Foreground="{DynamicResource TextForeground}"/>
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
        <Border Grid.Row="1" Background="{DynamicResource PanelBackground}" BorderBrush="{DynamicResource ControlBorder}" BorderThickness="0,1,0,0" Padding="12,6">
            <DockPanel>
                <CheckBox x:Name="DarkThemeCheck" Content="Dark theme" IsChecked="True" Foreground="{DynamicResource TextForeground}" DockPanel.Dock="Left" VerticalAlignment="Center"/>
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
        Appends a colored line to the on-screen console panel (Tab 2).
    .PARAMETER Message
        Text to display.
    .PARAMETER Level
        INFO | OK | WARN | ERROR — controls the color (theme-aware).
    #>
    param([string]$Message, [string]$Level = 'INFO')
    $rtb = Get-Ui 'DownloadLogBox'
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

function Get-OdtSetupExe {
    <#
    .SYNOPSIS
        Returns the full path to the ODT setup.exe, downloading it if needed.
    .DESCRIPTION
        Checks the local cache folder for setup.exe. If absent (or -Force), it
        resolves the current ODT download URL from Microsoft's official download
        page (id=49117), downloads the self-extracting installer, and extracts
        setup.exe using the installer's own /extract:<path> switch.
    .PARAMETER Force
        Re-download even if a cached copy exists.
    .RETURNS
        Full path to setup.exe, or $null on failure (errors are logged, never
        silently swallowed).
    #>
    param([switch]$Force)

    $setupExe = Join-Path $script:OdtCacheDir 'setup.exe'

    if (-not $Force -and (Test-Path $setupExe) -and (Get-Item $setupExe).Length -gt 1MB) {
        Write-Log "Using cached setup.exe: $setupExe" 'INFO'
        return $setupExe
    }

    Write-Log 'Downloading the Office Deployment Tool from Microsoft...' 'INFO'
    try {
        # Resolve the actual .exe URL from the official download page. The page
        # embeds a direct href to download.microsoft.com — we parse it out rather
        # than hardcoding a versioned URL that goes stale.
        $page = Invoke-WebRequest -Uri $script:OdtDownloadPage -UseBasicParsing -TimeoutSec 30
        $match = [regex]::Match($page.Content, 'href="(https://download\.microsoft\.com/[^"]+\.exe)"')
        if (-not $match.Success) {
            throw 'Could not locate the ODT download link on the Microsoft download page.'
        }
        $installerUrl = $match.Groups[1].Value
        Write-Log "ODT installer URL: $installerUrl" 'INFO'

        $installerPath = Join-Path $env:TEMP 'odt-installer.exe'
        Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing -TimeoutSec 120

        # The ODT downloader is a self-extracting archive. /extract:<path> pulls
        # out setup.exe (plus configuration.xml etc.) without installing anything.
        $extractDir = Join-Path $script:OdtCacheDir 'extract'
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
        Write-Log "setup.exe ready: $setupExe" 'OK'
        Update-OdtVersionLabel
        return $setupExe
    } catch {
        Write-Log "Failed to obtain the Office Deployment Tool: $($_.Exception.Message)" 'ERROR'
        return $null
    }
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
        This is the synchronous core used by the background runspace. It starts
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
    $p = Start-Process -FilePath $SetupExe -ArgumentList @("/$Mode", "`"$ConfigPath`"") -Wait -PassThru -NoNewWindow
    return $p.ExitCode
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

# Scriptblock run in the background runspace for ODT configure/download actions.
$script:OdtJobScript = {
    param($SetupExe, $ConfigPath, $Mode, $Queue)
    function Write-JobLine { param([string]$Line) $Queue.Enqueue($Line) }
    Write-JobLine "Launching setup.exe /$Mode ..."
    $p = Start-Process -FilePath $SetupExe -ArgumentList @("/$Mode", "`"$ConfigPath`"") -Wait -PassThru -NoNewWindow
    Write-JobLine "setup.exe finished with exit code $($p.ExitCode)."
    return $p.ExitCode
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

    # Completion?
    if ($script:Job.AsyncResult -and $script:Job.AsyncResult.IsCompleted) {
        $exitCode = 0
        try {
            $exitCode = $script:Job.PowerShell.EndInvoke($script:Job.AsyncResult)
        } catch {
            Add-ConsoleLine "Background job error: $($_.Exception.Message)" 'ERROR'
        }
        $script:Job.PowerShell.Dispose()
        $kind = $script:Job.Kind
        $script:Job.Running = $false
        $script:Job.PowerShell = $null
        $script:Job.AsyncResult = $null

        Set-UiBusy $false

        switch ($kind) {
            'install' {
                if ($exitCode -eq 0) {
                    $summary = Get-OdtResultSummary -LogDir $script:OdtLogDir -ExitCode $exitCode
                    Write-Log "Install finished. $summary" 'OK'
                    [System.Windows.MessageBox]::Show($script:Window, "Office install finished.`n`n$summary", 'Install Complete', 'OK', 'Information') | Out-Null
                } else {
                    Write-Log "Install failed (exit code $exitCode). See the console log for details." 'ERROR'
                    [System.Windows.MessageBox]::Show($script:Window, "Office install failed with exit code $exitCode. See the console log for details.", 'Install Failed', 'OK', 'Error') | Out-Null
                }
            }
            'uninstall' {
                if ($exitCode -eq 0) {
                    Write-Log 'Uninstall finished.' 'OK'
                    [System.Windows.MessageBox]::Show($script:Window, 'Office uninstall finished.', 'Uninstall Complete', 'OK', 'Information') | Out-Null
                } else {
                    Write-Log "Uninstall failed (exit code $exitCode)." 'ERROR'
                    [System.Windows.MessageBox]::Show($script:Window, "Office uninstall failed with exit code $exitCode. See the console log for details.", 'Uninstall Failed', 'OK', 'Error') | Out-Null
                }
            }
            'download' {
                if ($exitCode -eq 0) {
                    $script:LastDownloadFolder = $script:LastDownloadDest
                    $isoBtn = Get-Ui 'CreateIsoBtn'
                    if ($isoBtn) { $isoBtn.IsEnabled = $true }
                    Write-Log "Download complete. Source files are in: $script:LastDownloadFolder" 'OK'
                } else {
                    Write-Log "Download failed (exit code $exitCode)." 'ERROR'
                }
            }
            'iso' {
                if ($exitCode -eq 0) {
                    Write-Log 'ISO creation finished.' 'OK'
                } else {
                    Write-Log 'ISO creation failed. See the console log for details.' 'ERROR'
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
    foreach ($name in @('InstallBtn', 'UninstallBtn', 'StatusBtn', 'DownloadBtn', 'CreateIsoBtn')) {
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
    param($Combo)
    $Combo.Items.Clear()
    foreach ($e in $script:Editions) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $e.Name
        $item.Tag = $e.Id
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
        Creates a themed CheckBox for the app lists.
    #>
    param([string]$Name, [string]$Id, [bool]$Checked)
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $Name
    $cb.Tag = $Id
    $cb.Margin = New-Object System.Windows.Thickness(4, 2, 4, 2)
    $cb.IsChecked = $Checked
    $cb.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'TextForeground')
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
    $cb.Add_Checked({ Sync-LanguageLists })
    $cb.Add_Unchecked({ Sync-LanguageLists })
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
        Returns the resolved Product IDs of checked individual apps, substituting
        the selected Project/Visio year into the {Year} placeholder.
    #>
    $list = Get-Ui 'IndividualAppsList'
    $yearCombo = Get-Ui 'InstallYearCombo'
    $year = '2021'
    if ($yearCombo -and $yearCombo.SelectedItem) { $year = $yearCombo.SelectedItem.Tag }
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

    if ($useIndividual) {
        if (-not (Test-VolumeChannelMismatch)) { return }
        $apps = Get-SelectedIndividualApps
        $config = New-OdtConfigXml -EditionId $editionId -Architecture $arch -Channel $channel -Languages $languages -IndividualApps $apps -UseIndividualApps -SourcePath (Get-OfflineSourcePath)
    } else {
        $excluded = Get-ExcludedApps
        $config = New-OdtConfigXml -EditionId $editionId -Architecture $arch -Channel $channel -Languages $languages -ExcludedApps $excluded -SourcePath (Get-OfflineSourcePath)
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
    #>
    param([string]$ConfigPath)
    if (-not (Test-Path $ConfigPath)) {
        Write-Log "Config not found: $ConfigPath" 'ERROR'
        return
    }
    $setupExe = Get-OdtSetupExe
    if (-not $setupExe) { return }
    Set-UiBusy $true
    Start-BackgroundJob -Kind 'install' -Script $script:OdtJobScript -Arguments @($setupExe, $ConfigPath, 'configure') -OdtLogDir $script:OdtLogDir
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
        elevated, and by the elevated relaunch).
    #>
    param([string]$ConfigPath)
    if (-not (Test-Path $ConfigPath)) {
        Write-Log "Config not found: $ConfigPath" 'ERROR'
        return
    }
    $setupExe = Get-OdtSetupExe
    if (-not $setupExe) { return }
    Set-UiBusy $true
    Start-BackgroundJob -Kind 'uninstall' -Script $script:OdtJobScript -Arguments @($setupExe, $ConfigPath, 'configure') -OdtLogDir $script:OdtLogDir
}

function Get-OfflineSourcePath {
    <#
    .SYNOPSIS
        Returns the offline source folder if the "Use offline source" checkbox is
        checked and a folder is entered, otherwise $null.
    #>
    $check = Get-Ui 'InstallOfflineCheck'
    if (-not $check -or -not $check.IsChecked) { return $null }
    $box = Get-Ui 'InstallOfflinePathBox'
    $path = $box.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($path)) {
        Write-Log 'Offline source is checked but no folder was entered.' 'WARN'
        return $null
    }
    if (-not (Test-Path $path)) {
        Write-Log "Offline source folder does not exist: $path" 'WARN'
        return $null
    }
    return $path
}

function Start-Download {
    <#
    .SYNOPSIS
        Builds an Add config with SourcePath = destination and runs setup.exe
        /download. No elevation needed.
    .NOTES
        The spec asked for a "Single-threaded download" checkbox. ODT does not
        expose any single-vs-multi-thread download switch (verified against the
        ODT /? help and the configuration schema — there is no such option), so
        per the spec the checkbox was removed rather than faking behavior. ODT
        downloads files sequentially on its own.
    #>
    $destBox = Get-Ui 'DownloadDestBox'
    $dest = $destBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($dest)) {
        Write-Log 'Please choose a destination folder for the download.' 'ERROR'
        return
    }
    # Validate the path before it goes anywhere near a command line.
    if ($dest -match '[&|;`]') {
        Write-Log 'Destination folder contains invalid characters (& | ; `).' 'ERROR'
        return
    }
    if (-not (Test-Path $dest)) {
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
    }

    $languages = Get-SelectedLanguages
    $arch = Get-SelectedArchitecture
    $channel = Get-SelectedChannel
    $editionId = Get-SelectedEditionId

    $config = New-OdtConfigXml -EditionId $editionId -Architecture $arch -Channel $channel -Languages $languages -SourcePath $dest
    if (-not $config) { return }

    $configPath = Join-Path $env:TEMP ("office-download-{0}.xml" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $config | Set-Content -Path $configPath -Encoding UTF8
    Write-Log "Download config written to $configPath" 'INFO'

    $setupExe = Get-OdtSetupExe
    if (-not $setupExe) { return }

    $script:LastDownloadDest = $dest
    Set-UiBusy $true
    Start-BackgroundJob -Kind 'download' -Script $script:OdtJobScript -Arguments @($setupExe, $configPath, 'download') -OdtLogDir $script:OdtLogDir
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
    Write-Log "Setting KMS host to $kmsHost ..." 'INFO'
    & cscript.exe //nologo $ospp "/sethst:$kmsHost"
    Write-Log 'Activating against the KMS host ...' 'INFO'
    & cscript.exe //nologo $ospp /act
    Write-Log 'KMS activation attempt finished. Check the output above.' 'INFO'
}

# ============================================================================
# Event wiring
# ============================================================================

function Add-ArchSync {
    <#
    .SYNOPSIS
        Mirrors a radio button's checked state to its counterpart on the other
        tab. Implemented as a function (not a loop) so each handler captures its
        own Src/Dst values — PowerShell closures capture variables by reference,
        so a foreach loop would make every handler use the last pair.
    #>
    param([string]$Src, [string]$Dst)
    (Get-Ui $Src).Add_Checked({
        if ($script:SyncingArch) { return }
        $script:SyncingArch = $true
        try { (Get-Ui $Dst).IsChecked = $true } finally { $script:SyncingArch = $false }
    })
}

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

    # --- Install tab: individual-apps mode toggle ---
    (Get-Ui 'InstallIndividualCheck').Add_Checked({
        (Get-Ui 'IndividualAppsBorder').Visibility = 'Visible'
        (Get-Ui 'SuiteAppsBorder').Visibility = 'Collapsed'
        (Get-Ui 'YearSelectorPanel').Visibility = 'Visible'
        (Get-Ui 'AppsLabel').Text = 'Individual apps to install'
    })
    (Get-Ui 'InstallIndividualCheck').Add_Unchecked({
        (Get-Ui 'IndividualAppsBorder').Visibility = 'Collapsed'
        (Get-Ui 'SuiteAppsBorder').Visibility = 'Visible'
        (Get-Ui 'YearSelectorPanel').Visibility = 'Collapsed'
        (Get-Ui 'AppsLabel').Text = 'Applications (uncheck to exclude from the suite)'
    })

    # --- Install tab: offline source toggle ---
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

    # --- Action buttons ---
    (Get-Ui 'InstallBtn').Add_Click({ Start-Install })
    (Get-Ui 'UninstallBtn').Add_Click({ Start-Uninstall })
    (Get-Ui 'StatusBtn').Add_Click({ Show-InstalledStatus })
    (Get-Ui 'DownloadBtn').Add_Click({ Start-Download })
    (Get-Ui 'CreateIsoBtn').Add_Click({ Start-CreateIso })

    # --- About tab ---
    (Get-Ui 'OdtDocsLink').Add_Click({ Start-Process $script:OdtDocsUrl })
    (Get-Ui 'KmsToggleCheck').Add_Checked({ (Get-Ui 'KmsSection').Visibility = 'Visible' })
    (Get-Ui 'KmsToggleCheck').Add_Unchecked({ (Get-Ui 'KmsSection').Visibility = 'Collapsed' })
    (Get-Ui 'KmsActivateBtn').Add_Click({ Start-KmsActivation })

    # --- Cross-tab state sync (Install <-> Download must never disagree) ---
    $installEdition = Get-Ui 'InstallEditionCombo'
    $downloadEdition = Get-Ui 'DownloadEditionCombo'
    $installEdition.Add_SelectionChanged({
        if ($script:SyncingEdition) { return }
        $script:SyncingEdition = $true
        try { (Get-Ui 'DownloadEditionCombo').SelectedIndex = $this.SelectedIndex } finally { $script:SyncingEdition = $false }
    })
    $downloadEdition.Add_SelectionChanged({
        if ($script:SyncingEdition) { return }
        $script:SyncingEdition = $true
        try { (Get-Ui 'InstallEditionCombo').SelectedIndex = $this.SelectedIndex } finally { $script:SyncingEdition = $false }
    })

    $installChannel = Get-Ui 'InstallChannelCombo'
    $downloadChannel = Get-Ui 'DownloadChannelCombo'
    $installChannel.Add_SelectionChanged({
        if ($script:SyncingChannel) { return }
        $script:SyncingChannel = $true
        try { (Get-Ui 'DownloadChannelCombo').SelectedIndex = $this.SelectedIndex } finally { $script:SyncingChannel = $false }
    })
    $downloadChannel.Add_SelectionChanged({
        if ($script:SyncingChannel) { return }
        $script:SyncingChannel = $true
        try { (Get-Ui 'InstallChannelCombo').SelectedIndex = $this.SelectedIndex } finally { $script:SyncingChannel = $false }
    })

    # Architecture radios: mirror between tabs. Uses a helper function (not a
    # foreach loop) because PowerShell closures capture loop variables by
    # reference — a foreach would make every handler use the last pair.
    Add-ArchSync -Src 'InstallArch64Radio' -Dst 'DownloadArch64Radio'
    Add-ArchSync -Src 'InstallArch32Radio' -Dst 'DownloadArch32Radio'
    Add-ArchSync -Src 'DownloadArch64Radio' -Dst 'InstallArch64Radio'
    Add-ArchSync -Src 'DownloadArch32Radio' -Dst 'InstallArch32Radio'

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
Populate-EditionCombo (Get-Ui 'InstallEditionCombo')
Populate-EditionCombo (Get-Ui 'DownloadEditionCombo')
Populate-ChannelCombo (Get-Ui 'InstallChannelCombo')
Populate-ChannelCombo (Get-Ui 'DownloadChannelCombo')
Populate-YearCombo (Get-Ui 'InstallYearCombo')
Populate-AppLists
Populate-LanguageLists

# About tab paths.
(Get-Ui 'AboutVersionText').Text = "Version $script:AppVersion"
(Get-Ui 'AboutCachePath').Text = "ODT cache: $script:OdtCacheDir"
(Get-Ui 'AboutLogPath').Text = "Logs: $script:LogDir"

# Wire events.
Wire-Events

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