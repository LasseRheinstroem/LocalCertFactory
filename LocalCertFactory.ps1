Add-Type -AssemblyName PresentationFramework

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$xamlPath   = Join-Path $ScriptDir "gui.xaml"
$configPath = Join-Path $ScriptDir "config.yaml"

# --- 1. YAML MODUL PRÜFEN / NACHLADEN ---
if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
    try {
        Write-Host "Das Modul 'powershell-yaml' wird installiert..." -ForegroundColor Yellow
        Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    } catch {
        Write-Warning "powershell-yaml konnte nicht automatisch aus PSGallery installiert werden: $_"
    }
}

if (Get-Module -Name powershell-yaml -ListAvailable) {
    Import-Module -Name powershell-yaml -ErrorAction SilentlyContinue
}

if (-not (Test-Path $xamlPath)) {
    Write-Error "gui.xaml nicht gefunden!"
    exit
}

# --- 2. DEFAULT CONFIG & LOAD FUNCTION ---
$defaultConfigText = @"
# ==========================================
# LocalCertFactory Configuration
# ==========================================

paths:
  openssl_exe: "openssl" # Oder absoluter Pfad, z. B. "C:\\Program Files\\OpenSSL-Win64\\bin\\openssl.exe"
  ca_directory: "CA" # oder "C:\\LocalCertFactory\\CA"
  certs_directory: "Certificates" # oder "C:\\LocalCertFactory\\Certificates"
  # bei Pfaden ist leider für ein "\" ein "\\" nötig, bitte entsprechend eingeben

defaults:
  country: "DE"
  state: "Baden-Wuerttemberg"
  locality: "Stuttgart"
  organization: "Familiennetzwerk"
  threshold_days_warning: 30
  threshold_days_critical: 7
  
  root_ca:
    common_name: "MeinHeimnetz Root CA"
    ou: "Certificate Authority"
    validity_days: 10957 # 30 Jahre
    key_algorithm: "RSA"
    key_length: 4096
    hash_algorithm: "SHA256"
    crt_file: "RootCA.crt"
    pfx_file: "RootCA.pfx"

  intermediate_ca:
    enabled: false
    common_name: "MeinHeimnetz Intermediate CA"
    ou: "Issuing CA"
    validity_days: 1826 # 5 Jahre
    key_algorithm: "RSA"
    key_length: 2048
    has_password: false
    crt_file: "IntermediateCA.crt"
    pfx_file: "IntermediateCA.pfx"

  services:
    validity_days: 365 # 1 Jahr
    key_algorithm: "RSA"
    key_length: 2048
    exports:
      pfx: true
      crt: true
      key: true
      pem_cert: false
      pem_full: true
"@

function Get-OrCreateConfig {
    param(
        [string]$FilePath,
        [string]$DefaultContent
    )

    if (-not (Test-Path $FilePath)) {
        # Datei anlegen und Standard-Inhalt schreiben
        [System.IO.File]::WriteAllText($FilePath, $DefaultContent, [System.Text.Encoding]::UTF8)
        return $DefaultContent
    } else {
        # Bestehende Datei lesen
        return [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
    }
}

# --- 3. CONFIG LADEN & PARSEN ---
$rawConfigText = Get-OrCreateConfig -FilePath $configPath -DefaultContent $defaultConfigText

try {
    $global:Config = ConvertFrom-Yaml -Yaml $rawConfigText
} catch {
    Write-Warning "Fehler beim Parsen der config.yaml, verwende Fallback: $_"
    $global:Config = ConvertFrom-Yaml -Yaml $defaultConfigText
}

# --- 4. XAML LADEN ---
$xamlText = [System.IO.File]::ReadAllText($xamlPath, [System.Text.Encoding]::UTF8)
$reader   = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xamlText))
$window   = [System.Windows.Markup.XamlReader]::Load($reader)

# --- 5. GLOBAL STATE ---
$global:CaPasswordCache     = $null
$global:HasRootCA           = $false   # Mock State
$global:RootDaysRemaining   = 400     # Mock Wert (> 30 Tage = Grün)
$global:HasIntermediate     = $false   # Mock State
$global:InterDaysRemaining  = 25      # Mock Wert (< 30 Tage = Orange für Test)
$global:IntermediateHasPass = $false

# --- 6. PASSWORT DIALOG ---
function Get-CaPassword {
    param([string]$PromptText = "Bitte Passwort eingeben:")

    if (-not [string]::IsNullOrEmpty($global:CaPasswordCache)) {
        return $global:CaPasswordCache
    }

    $pwdWindow = New-Object System.Windows.Window
    $pwdWindow.Title = "Passwort erforderlich"
    $pwdWindow.Width = 380
    $pwdWindow.Height = 180
    $pwdWindow.WindowStartupLocation = "CenterOwner"
    $pwdWindow.Owner = $window
    $pwdWindow.ResizeMode = "NoResize"
    $pwdWindow.Background = "#F4F5F7"

    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Margin = 15

    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = "$PromptText`n(Wird für diese Sitzung zwischengespeichert)"
    $lbl.Margin = "0,0,0,10"
    $stack.Children.Add($lbl)

    $pwdBox = New-Object System.Windows.Controls.PasswordBox
    $pwdBox.Margin = "0,0,0,15"
    $pwdBox.Padding = "4"
    $stack.Children.Add($pwdBox)

    $btnStack = New-Object System.Windows.Controls.StackPanel
    $btnStack.Orientation = "Horizontal"
    $btnStack.HorizontalAlignment = "Right"

    $btnOk = New-Object System.Windows.Controls.Button
    $btnOk.Content = "OK"
    $btnOk.Width = 75
    $btnOk.IsDefault = $true
    $btnOk.Add_Click({
        $pwdWindow.DialogResult = $true
        $pwdWindow.Close()
    })

    $btnCancel = New-Object System.Windows.Controls.Button
    $btnCancel.Content = "Abbrechen"
    $btnCancel.Width = 75
    $btnCancel.Margin = "8,0,0,0"
    $btnCancel.Add_Click({
        $pwdWindow.DialogResult = $false
        $pwdWindow.Close()
    })

    $btnStack.Children.Add($btnOk)
    $btnStack.Children.Add($btnCancel)
    $stack.Children.Add($btnStack)

    $pwdWindow.Content = $stack
    $pwdBox.Focus() | Out-Null

    $result = $pwdWindow.ShowDialog()

    if ($result -eq $true -and -not [string]::IsNullOrEmpty($pwdBox.Password)) {
        $global:CaPasswordCache = $pwdBox.Password
        return $global:CaPasswordCache
    }

    return $null
}

# --- 7. CONTROLS REINIZIALISIEREN & MAP PEN ---
$MainTabControl         = $window.FindName("MainTabControl")
$TabDashboard           = $window.FindName("TabDashboard")
$TabCreateRootCA        = $window.FindName("TabCreateRootCA")
$TabCreateIntermediate  = $window.FindName("TabCreateIntermediate")
$TabNewService          = $window.FindName("TabNewService")
$TabConfig              = $window.FindName("TabConfig")

$PanelCaDetails         = $window.FindName("PanelCaDetails")
$TxtCaMissing           = $window.FindName("TxtCaMissing")

$TxtRootCaInfo          = $window.FindName("TxtRootCaInfo")
$TxtRootCaExpiry        = $window.FindName("TxtRootCaExpiry")
$TxtInterCaInfo         = $window.FindName("TxtInterCaInfo")
$TxtInterCaExpiry       = $window.FindName("TxtInterCaExpiry")
$TxtSignModeInfo        = $window.FindName("TxtSignModeInfo")

$BtnShowCreateRootCA    = $window.FindName("BtnShowCreateRootCA")
$BtnShowCreateIntermediate = $window.FindName("BtnShowCreateIntermediate")
$PanelNoRootForInterWarning = $window.FindName("PanelNoRootForInterWarning")
$BtnRenewRootCA         = $window.FindName("BtnRenewRootCA")
$BtnRenewIntermediate   = $window.FindName("BtnRenewIntermediate")

$BtnRenewSelected       = $window.FindName("BtnRenewSelected")
$BtnRenewDue            = $window.FindName("BtnRenewDue")
$GridServices           = $window.FindName("GridServices")
$BtnNewService          = $window.FindName("BtnNewService")
$PanelNoCaWarning       = $window.FindName("PanelNoCaWarning")

# Form Controls
$TxtRootCn              = $window.FindName("TxtRootCn")
$TxtRootOrg             = $window.FindName("TxtRootOrg")
$TxtRootOu              = $window.FindName("TxtRootOu")
$TxtRootCountry         = $window.FindName("TxtRootCountry")
$TxtRootState           = $window.FindName("TxtRootState")
$TxtRootLocality        = $window.FindName("TxtRootLocality")
$TxtRootDays            = $window.FindName("TxtRootDays")
$CmbRootAlgorithm       = $window.FindName("CmbRootAlgorithm")
$CmbRootKeyLength       = $window.FindName("CmbRootKeyLength")
$PwdRootPass            = $window.FindName("PwdRootPass")
$PwdRootPassConfirm     = $window.FindName("PwdRootPassConfirm")
$BtnCancelRootCA        = $window.FindName("BtnCancelRootCA")
$BtnSaveRootCA          = $window.FindName("BtnSaveRootCA")

$TxtInterCn             = $window.FindName("TxtInterCn")
$TxtInterOrg            = $window.FindName("TxtInterOrg")
$TxtInterDays           = $window.FindName("TxtInterDays")
$CmbInterAlgorithm      = $window.FindName("CmbInterAlgorithm")
$CmbInterKeyLength      = $window.FindName("CmbInterKeyLength")
$PwdInterPass           = $window.FindName("PwdInterPass")
$PwdInterPassConfirm    = $window.FindName("PwdInterPassConfirm")
$BtnCancelIntermediate  = $window.FindName("BtnCancelIntermediate")
$BtnSaveIntermediate    = $window.FindName("BtnSaveIntermediate")

$TxtServiceDisplayName  = $window.FindName("TxtServiceDisplayName")
$TxtServiceCn           = $window.FindName("TxtServiceCn")
$TxtServiceSANs         = $window.FindName("TxtServiceSANs")
$CmbServiceAlgorithm    = $window.FindName("CmbServiceAlgorithm")
$CmbServiceKeyLength    = $window.FindName("CmbServiceKeyLength")
$TxtServiceDays         = $window.FindName("TxtServiceDays")
$ChkExportPfx           = $window.FindName("ChkExportPfx")
$ChkExportCrt           = $window.FindName("ChkExportCrt")
$ChkExportKey           = $window.FindName("ChkExportKey")
$ChkExportPemOnly       = $window.FindName("ChkExportPemOnly")
$ChkExportPemFull       = $window.FindName("ChkExportPemFull")
$BtnCancelNewService    = $window.FindName("BtnCancelNewService")
$BtnSaveNewService      = $window.FindName("BtnSaveNewService")

$TxtConfigEditor        = $window.FindName("TxtConfigEditor")
$TxtConfigNotice        = $window.FindName("TxtConfigNotice")
$BtnOpenConfig          = $window.FindName("BtnOpenConfig")
$BtnBackFromConfig      = $window.FindName("BtnBackFromConfig")
$BtnImportConfig        = $window.FindName("BtnImportConfig")
$BtnExportConfig        = $window.FindName("BtnExportConfig")

$TxtStatus              = $window.FindName("TxtStatus")

# --- 8. FUNKTIONEN ZUM BEFÜLLEN & SPEICHERN DER CONFIG ---

# Helper zum Aktualisieren des Config-Tab Status
function Update-ConfigTabState {
    if ($global:HasRootCA) {
        $BtnImportConfig.IsEnabled = $false
        $TxtConfigNotice.Text = "🔒 Die Konfiguration ist gesperrt, da bereits eine aktive Root-CA existiert. So werden versehentliche Fehlkonfigurationen vermieden. Du kannst die aktuelle Konfiguration weiterhin exportieren."
    } else {
        $BtnImportConfig.IsEnabled = $true
        $TxtConfigNotice.Text = "ℹ️ Noch keine Root-CA angelegt: Du kannst eine bestehende 'config.yaml' importieren, um Voreinstellungen für eine Neuinstallation zu übernehmen."
    }
}

function Set-ComboBoxByText {
    param([System.Windows.Controls.ComboBox]$ComboBox, [string]$Value)
    if (-not $ComboBox) { return }
    for ($i = 0; $i -lt $ComboBox.Items.Count; $i++) {$item = $ComboBox.Items[$i]
        $content = if ($item -is [System.Windows.Controls.ComboBoxItem]) { $item.Content.ToString() } else {$item.ToString() }
        if ($content -eq $Value) {
            $ComboBox.SelectedIndex =$i
            return
        }
    }
}

function LoadConfigToForm {
    $cfg = $global:Config

    # Root CA
    if ($TxtRootCn)       { $TxtRootCn.Text       = $cfg.defaults.root_ca.common_name }
    if ($TxtRootOrg)      { $TxtRootOrg.Text      = $cfg.defaults.organization }
    if ($TxtRootOu)       { $TxtRootOu.Text       = $cfg.defaults.root_ca.ou }
    if ($TxtRootCountry)  { $TxtRootCountry.Text  = $cfg.defaults.country }
    if ($TxtRootState)    { $TxtRootState.Text    = $cfg.defaults.state }
    if ($TxtRootLocality) { $TxtRootLocality.Text = $cfg.defaults.locality }
    if ($TxtRootDays)     { $TxtRootDays.Text     = $cfg.defaults.root_ca.validity_days.ToString() }
    Set-ComboBoxByText -ComboBox $CmbRootAlgorithm -Value $cfg.defaults.root_ca.key_algorithm
    Set-ComboBoxByText -ComboBox $CmbRootKeyLength -Value $cfg.defaults.root_ca.key_length.ToString()

    # Intermediate CA
    if ($TxtInterCn)   { $TxtInterCn.Text   = $cfg.defaults.intermediate_ca.common_name }
    if ($TxtInterOrg)  { $TxtInterOrg.Text  = $cfg.defaults.organization }
    if ($TxtInterDays) { $TxtInterDays.Text = $cfg.defaults.intermediate_ca.validity_days.ToString() }
    Set-ComboBoxByText -ComboBox $CmbInterAlgorithm -Value $cfg.defaults.intermediate_ca.key_algorithm
    Set-ComboBoxByText -ComboBox $CmbInterKeyLength -Value $cfg.defaults.intermediate_ca.key_length.ToString()

    # Service Defaults
    if ($TxtServiceDays) { $TxtServiceDays.Text = $cfg.defaults.services.validity_days.ToString() }
    Set-ComboBoxByText -ComboBox $CmbServiceAlgorithm -Value $cfg.defaults.services.key_algorithm
    Set-ComboBoxByText -ComboBox $CmbServiceKeyLength -Value $cfg.defaults.services.key_length.ToString()
    if ($ChkExportPfx)     { $ChkExportPfx.IsChecked     = [bool]$cfg.defaults.services.exports.pfx }
    if ($ChkExportCrt)     { $ChkExportCrt.IsChecked     = [bool]$cfg.defaults.services.exports.crt }
    if ($ChkExportKey)     { $ChkExportKey.IsChecked     = [bool]$cfg.defaults.services.exports.key }
    if ($ChkExportPemOnly) { $ChkExportPemOnly.IsChecked = [bool]$cfg.defaults.services.exports.pem_cert }
    if ($ChkExportPemFull) { $ChkExportPemFull.IsChecked = [bool]$cfg.defaults.services.exports.pem_full }

    # Config Editor Textupdaten
    if ($TxtConfigEditor) { $TxtConfigEditor.Text = ConvertTo-Yaml -Data $cfg }
}

function Save-ConfigToFile {
    $yamlString = ConvertTo-Yaml -Data $global:Config
    [System.IO.File]::WriteAllText($configPath,$yamlString, [System.Text.Encoding]::UTF8)
    if ($TxtConfigEditor) { $TxtConfigEditor.Text = $yamlString }
}

# Formulare initial befüllen
LoadConfigToForm

# --- 9. HELPER FUNKTIONEN GUI STYLING ---
function Get-StatusColor {
    param([int]$Days)
    if ($Days -le 0) { return "#D13438" }    # Rot / Abgelaufen
    if ($Days -lt 30) { return "#D97706" }   # Orange / Warnung
    return "#107C41"                        # Grün / Gut
}

function Set-ButtonStyle {
    param(
        [System.Windows.Controls.Button]$Button,
        [int]$DaysRemaining
    )
    if (-not $Button) { return }
    if ($DaysRemaining -lt 30) {
        $Button.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0078D4")
        $Button.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("White")
        $Button.BorderThickness = New-Object System.Windows.Thickness(0)
    } else {
        $Button.Background = [System.Windows.Media.Brushes]::Transparent
        $Button.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0078D4")
        $Button.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0078D4")
        $Button.BorderThickness = New-Object System.Windows.Thickness(1)
    }
}

# --- 10. STATUS-AKTUALISIERUNG INFRASTRUKTUR ---
function Test-HasDueServices {
    param(
        $Services,
        [int]$WarningThreshold = 30
    )
    if ($null -eq $Services) { return $false }

    foreach ($item in $Services) {
        # 1. Prüfe auf Status-Text
        if ($item.Status -eq "Warnung" -or $item.Status -eq "Abgelaufen") {
            return $true
        }

        # 2. Prüfe auf verbleibende Tage
        if ($null -ne $item.DaysRemaining) {
            $daysVal = 0
            if ([int]::TryParse($item.DaysRemaining.ToString(), [ref]$daysVal)) {
                if ($daysVal -le $WarningThreshold) {
                    return $true
                }
            }
        }
    }
    return $false
}

function Update-DashboardStatus {
    $canIssueCertificates = $global:HasRootCA

    # Service-Zertifikate Absicherung
    if ($BtnNewService) {
        $BtnNewService.IsEnabled = $canIssueCertificates
        $BtnNewService.ToolTip = if (-not $canIssueCertificates) { "Es muss zuerst eine Root-CA angelegt werden." } else { $null }
    }
    if ($PanelNoCaWarning) {
        $PanelNoCaWarning.Visibility = if ($canIssueCertificates) { "Collapsed" } else { "Visible" }
    }
    if ($BtnSaveNewService) {
        $BtnSaveNewService.IsEnabled = $canIssueCertificates
    }

    # Intermediate-CA Absicherung
    if ($BtnShowCreateIntermediate) {
        $BtnShowCreateIntermediate.IsEnabled = $canIssueCertificates
        $BtnShowCreateIntermediate.ToolTip = if (-not $canIssueCertificates) { "Es muss zuerst eine Root-CA angelegt werden." } else { $null }
    }
    if ($PanelNoRootForInterWarning) {
        $PanelNoRootForInterWarning.Visibility = if ($canIssueCertificates) { "Collapsed" } else { "Visible" }
    }
    if ($BtnSaveIntermediate) {
        $BtnSaveIntermediate.IsEnabled = $canIssueCertificates
    }

    # --- PRÜFUNG SERVICE-ZERTIFIKATE & ERNEUERUNGS-BUTTONS ---
    $services = $GridServices.ItemsSource
    $hasServices = ($null -ne $services -and @($services).Count -gt 0)

    # Threshold-Wert verlässlich auslesen
    $warningDays = 30
    try {
        if ($global:Config -and $global:Config.defaults -and $global:Config.defaults.ContainsKey('threshold_days_warning')) {
            $warningDays = [int]$global:Config.defaults['threshold_days_warning']
        } elseif ($global:Config.defaults.threshold_days_warning) {
            $warningDays = [int]$global:Config.defaults.threshold_days_warning
        }
    } catch {
        $warningDays = 30
    }

    # 1. "Ausgewählte erneuern"
    if ($BtnRenewSelected) {
        $BtnRenewSelected.IsEnabled = $hasServices
        $BtnRenewSelected.ToolTip = if (-not $hasServices) { "Keine Service-Zertifikate vorhanden." } else { $null }
    }

    # 2. "Fällige erneuern"
    $hasDueServices = Test-HasDueServices -Services $services -WarningThreshold $warningDays

    if ($BtnRenewDue) {
        $BtnRenewDue.IsEnabled = $hasDueServices
        $BtnRenewDue.ToolTip = if (-not $hasDueServices) { "Keine fälligen (orange) oder abgelaufenen (roten) Service-Zertifikate vorhanden." } else { $null }
    }

    # CA-Status Aktualisierung
    if ($global:HasRootCA) {
        $TxtRootCaInfo.Text  = $global:Config.defaults.root_ca.common_name
        
        $rootColor = Get-StatusColor -Days $global:RootDaysRemaining
        $TxtRootCaExpiry.Text = "(Gültig bis: 2036-09-30, $global:RootDaysRemaining Tage restlich)"
        $TxtRootCaExpiry.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($rootColor)

        $PanelCaDetails.Visibility = "Visible"
        $TxtCaMissing.Visibility   = "Collapsed"
        $BtnShowCreateRootCA.Visibility = "Collapsed"
        $BtnRenewRootCA.Visibility = "Visible"
        Set-ButtonStyle -Button $BtnRenewRootCA -DaysRemaining $global:RootDaysRemaining

        if ($global:HasIntermediate) {
            $passState = if ($global:IntermediateHasPass) { "Passwortgeschützt" } else { "Passwortlos" }
            $TxtInterCaInfo.Text  = "$($global:Config.defaults.intermediate_ca.common_name) ($passState)"
            
            $interColor = Get-StatusColor -Days $global:InterDaysRemaining
            $TxtInterCaExpiry.Text = "(Gültig bis: 2026-10-25, $global:InterDaysRemaining Tage restlich)"
            $TxtInterCaExpiry.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($interColor)

            $TxtSignModeInfo.Text = "Aktiv signierende CA: Intermediate-CA"

            $BtnShowCreateIntermediate.Visibility = "Collapsed"
            $BtnRenewIntermediate.Visibility      = "Visible"
            Set-ButtonStyle -Button $BtnRenewIntermediate -DaysRemaining $global:InterDaysRemaining
        } else {
            $TxtInterCaInfo.Text   = "Nicht vorhanden"
            $TxtInterCaExpiry.Text = ""
            $TxtSignModeInfo.Text  = "Aktiv signierende CA: Root-CA"

            $BtnShowCreateIntermediate.Visibility = "Visible"
            $BtnRenewIntermediate.Visibility      = "Collapsed"
        }
    } else {
        $PanelCaDetails.Visibility = "Collapsed"
        $TxtCaMissing.Visibility   = "Visible"
        $BtnShowCreateRootCA.Visibility = "Visible"
        $BtnRenewRootCA.Visibility = "Collapsed"
        $BtnRenewIntermediate.Visibility = "Collapsed"
    }
}

# DEMO / MOCK DATA GRID (Beispieldaten inkl. SANs)
# DEMO / MOCK DATA GRID (Beispieldaten inkl. CN & SANs)
$mockServices = @(
    [PSCustomObject]@{ 
        DisplayName   = "Proxmox Cluster"
        CN            = "pve01.home.internal"
        SANs          = "pve01.home.internal, 192.168.1.10"
        Status        = "Gültig"
        ExpiryDate    = "2027-09-30"
        DaysRemaining = "365"
        StatusColor   = (Get-StatusColor -Days 365) 
    },
    [PSCustomObject]@{ 
        DisplayName   = "Home Assistant"
        CN            = "hass.home.internal"
        SANs          = "hass.home.internal, homeassistant.local, 192.168.1.15"
        Status        = "Warnung"
        ExpiryDate    = "2026-10-15"
        DaysRemaining = "15"
        StatusColor   = (Get-StatusColor -Days 15) 
    },
    [PSCustomObject]@{ 
        DisplayName   = "OPNsense Firewall"
        CN            = "router.home.internal"
        SANs          = "router.home.internal, 192.168.1.1"
        Status        = "Abgelaufen"
        ExpiryDate    = "2026-08-01"
        DaysRemaining = "-60"
        StatusColor   = (Get-StatusColor -Days -60) 
    }
)
$GridServices.ItemsSource = $mockServices
# ENDE DEMO / MOCK DATA GRID (Beispieldaten inkl. SANs)

Update-DashboardStatus

# --- 11. EVENT HANDLER ---
$BtnShowCreateRootCA.Add_Click({
    $MainTabControl.SelectedItem = $TabCreateRootCA
    $TxtStatus.Text = "Root-CA Konfiguration..."
})
$BtnCancelRootCA.Add_Click({
    $MainTabControl.SelectedItem = $TabDashboard
    $TxtStatus.Text = "Bereit."
})

$BtnShowCreateIntermediate.Add_Click({
    $MainTabControl.SelectedItem = $TabCreateIntermediate
    $TxtStatus.Text = "Intermediate-CA Konfiguration..."
})
$BtnCancelIntermediate.Add_Click({
    $MainTabControl.SelectedItem = $TabDashboard
    $TxtStatus.Text = "Bereit."
})

$BtnNewService.Add_Click({
    $MainTabControl.SelectedItem = $TabNewService
    $TxtStatus.Text = "Neues Service-Zertifikat..."
})
$BtnCancelNewService.Add_Click({
    $MainTabControl.SelectedItem = $TabDashboard
    $TxtStatus.Text = "Bereit."
})

$BtnOpenConfig.Add_Click({
    Update-ConfigTabState
    $MainTabControl.SelectedItem = $TabConfig
    $TxtStatus.Text = "Config-Editor geöffnet." 
})

# EXPORT HANDLER
$BtnExportConfig.Add_Click({
    $saveFileDialog = New-Object Microsoft.Win32.SaveFileDialog
    $saveFileDialog.Filter = "YAML-Dateien (*.yaml;*.yml)|*.yaml;*.yml|Alle Dateien (*.*)|*.*"
    $saveFileDialog.FileName = "config.yaml"
    $saveFileDialog.Title = "Konfiguration exportieren"

    if ($saveFileDialog.ShowDialog() -eq $true) {
        try {
            [System.IO.File]::WriteAllText($saveFileDialog.FileName, $TxtConfigEditor.Text, [System.Text.Encoding]::UTF8)
            [System.Windows.MessageBox]::Show("Konfiguration erfolgreich exportiert nach:`n$($saveFileDialog.FileName)", "Export erfolgreich", "OK", "Information")
            $TxtStatus.Text = "Konfiguration exportiert."
        } catch {
            [System.Windows.MessageBox]::Show("Fehler beim Exportieren:`n$_", "Fehler", "OK", "Error")
        }
    }
})

# IMPORT HANDLER (Nur aktiv solange keine Root-CA existiert)
$BtnImportConfig.Add_Click({
    if ($global:HasRootCA) {
        [System.Windows.MessageBox]::Show("Import nicht möglich: Es wurde bereits eine Root-CA angelegt.", "Sperre", "OK", "Warning")
        return
    }

    $openFileDialog = New-Object Microsoft.Win32.OpenFileDialog
    $openFileDialog.Filter = "YAML-Dateien (*.yaml;*.yml)|*.yaml;*.yml|Alle Dateien (*.*)|*.*"
    $openFileDialog.Title = "Konfiguration importieren"

    if ($openFileDialog.ShowDialog() -eq $true) {
        try {
            $importedText = [System.IO.File]::ReadAllText($openFileDialog.FileName, [System.Text.Encoding]::UTF8)
            
            # Syntax prüfen via powershell-yaml
            $parsed = ConvertFrom-Yaml -Yaml $importedText
            $global:Config = $parsed

            # Speichern und UI aktualisieren
            Save-ConfigToFile
            Load-ConfigToForm

            [System.Windows.MessageBox]::Show("Konfiguration erfolgreich importiert!", "Erfolg", "OK", "Information")
            $TxtStatus.Text = "Neue Konfiguration importiert."
        } catch {
            [System.Windows.MessageBox]::Show("Fehler beim Importieren oder ungültiges YAML-Format:`n$_", "Fehler", "OK", "Error")
        }
    }
})

$BtnBackFromConfig.Add_Click({
    $MainTabControl.SelectedItem = $TabDashboard
    $TxtStatus.Text = "Bereit."
})

# RENEW CA HANDLERS
$BtnRenewRootCA.Add_Click({
    $passwd = Get-CaPassword -PromptText "Root-CA Passwort zur Erneuerung erforderlich:"
    if ($passwd) {$global:RootDaysRemaining = 10957
        Update-DashboardStatus
        $TxtStatus.Text = "Root-CA wurde erfolgreich erneuert."
    }
})

$BtnRenewIntermediate.Add_Click({
    $passwd = Get-CaPassword -PromptText "Root-CA Passwort zur Signierung der Intermediate-CA erforderlich:"
    if ($passwd) {$global:InterDaysRemaining = 1826
        Update-DashboardStatus
        $TxtStatus.Text = "Intermediate-CA wurde erfolgreich erneuert."
    }
})

# AKTIONEN SPEICHERN & CONFIG SCHREIBEN
$BtnSaveRootCA.Add_Click({
    if ([string]::IsNullOrEmpty($PwdRootPass.Password)) {
        [System.Windows.MessageBox]::Show("Root-CA erfordert ein Passwort!", "Fehler", "OK", "Error")
        return
    }
    if ($PwdRootPass.Password -ne $PwdRootPassConfirm.Password) {
        [System.Windows.MessageBox]::Show("Passwörter stimmen nicht überein!", "Fehler", "OK", "Error")
        return
    }

    # Config im Speicher aktualisieren
    $global:Config.defaults.root_ca.common_name   = $TxtRootCn.Text
    $global:Config.defaults.organization          = $TxtRootOrg.Text
    $global:Config.defaults.root_ca.ou            = $TxtRootOu.Text
    $global:Config.defaults.country               = $TxtRootCountry.Text
    $global:Config.defaults.state                 = $TxtRootState.Text
    $global:Config.defaults.locality              = $TxtRootLocality.Text
    $global:Config.defaults.root_ca.validity_days = [int]$TxtRootDays.Text
    if ($CmbRootAlgorithm.SelectedItem) { $global:Config.defaults.root_ca.key_algorithm = $CmbRootAlgorithm.Text }
    if ($CmbRootKeyLength.SelectedItem) { $global:Config.defaults.root_ca.key_length    = [int]$CmbRootKeyLength.Text }

    # In Datei schreiben
    Save-ConfigToFile

    $global:HasRootCA = $true
    Update-DashboardStatus
    $MainTabControl.SelectedItem = $TabDashboard
    $TxtStatus.Text = "Root-CA Konfiguration gespeichert."
})

$BtnSaveIntermediate.Add_Click({
    if (-not $global:HasRootCA) {
        [System.Windows.MessageBox]::Show("Fehler: Es existiert keine Root-CA zum Signieren der Intermediate-CA!", "Keine Root-CA vorhanden", "OK", "Error")
        return
    }

    $rootPwd = Get-CaPassword -PromptText "Root-CA Passwort zur Signierung erforderlich:"
    if ([string]::IsNullOrEmpty($rootPwd)) { return }

    if ($PwdInterPass.Password -ne $PwdInterPassConfirm.Password) {
        [System.Windows.MessageBox]::Show("Passwörter stimmen nicht überein!", "Fehler", "OK", "Error")
        return
    }

    # Config im Speicher aktualisieren & Datei schreiben...
    $global:Config.defaults.intermediate_ca.common_name   = $TxtInterCn.Text
    $global:Config.defaults.organization                  = $TxtInterOrg.Text
    $global:Config.defaults.intermediate_ca.validity_days = [int]$TxtInterDays.Text
    if ($CmbInterAlgorithm.SelectedItem) { $global:Config.defaults.intermediate_ca.key_algorithm = $CmbInterAlgorithm.Text }
    if ($CmbInterKeyLength.SelectedItem) { $global:Config.defaults.intermediate_ca.key_length    = [int]$CmbInterKeyLength.Text }
    $global:Config.defaults.intermediate_ca.has_password  = (-not [string]::IsNullOrEmpty($PwdInterPass.Password))
    $global:Config.defaults.intermediate_ca.enabled       = $true

    Save-ConfigToFile

    $global:HasIntermediate = $true
    $global:IntermediateHasPass = $global:Config.defaults.intermediate_ca.has_password
    Update-DashboardStatus

    $MainTabControl.SelectedItem = $TabDashboard
    $TxtStatus.Text = "Intermediate-CA Konfiguration gespeichert!"
})

$BtnSaveNewService.Add_Click({
    if (-not $global:HasRootCA) {
        [System.Windows.MessageBox]::Show("Fehler: Es ist keine Root-CA vorhanden.", "Keine CA vorhanden", "OK", "Error")
        return
    }

    $cn = $TxtServiceCn.Text.Trim()
    if ([string]::IsNullOrEmpty($cn)) {
        [System.Windows.MessageBox]::Show("Bitte einen Common Name (CN) eingeben!", "Fehlende Eingabe", "OK", "Error")
        return
    }

    # SANs einlesen und säubern
    $rawSANs = $TxtServiceSANs.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

    # CN immer an erste Stelle setzen (Duplikate entfernen)
    $allSANs = @($cn) + ($rawSANs | Where-Object { $_ -ne $cn })
    $formattedSANs = ($allSANs | Select-Object -Unique) -join ", "

    # Neues Objekt für das Grid (Beispiel)
    $newService = [PSCustomObject]@{
        DisplayName   = if ($TxtServiceDisplayName.Text) { $TxtServiceDisplayName.Text } else { $cn }
        SANs          = $formattedSANs
        Status        = "Gültig"
        ExpiryDate    = (Get-Date).AddDays([int]$TxtServiceDays.Text).ToString("yyyy-MM-dd")
        DaysRemaining = $TxtServiceDays.Text
        StatusColor   = (Get-StatusColor -Days [int]$TxtServiceDays.Text)
    }

    # Dem Grid hinzufügen & Dashboard aktualisieren
    $currentList = [System.Collections.Generic.List[PSCustomObject]]::new($GridServices.ItemsSource)
    $currentList.Add($newService)
    $GridServices.ItemsSource = $currentList

    Update-DashboardStatus
    $MainTabControl.SelectedItem = $TabDashboard
})

$window.ShowDialog() | Out-Null