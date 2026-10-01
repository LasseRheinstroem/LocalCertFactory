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

# --- DEFAULT CONFIG & LOAD FUNCTION ---
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

$rawConfigText = Get-OrCreateConfig -FilePath $configPath -DefaultContent $defaultConfigText

# --- XAML LADEN ---
$xamlText = [System.IO.File]::ReadAllText($xamlPath, [System.Text.Encoding]::UTF8)
$reader   = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xamlText))
$window   = [System.Windows.Markup.XamlReader]::Load($reader)

# --- GLOBAL STATE ---
$global:CaPasswordCache     = $null
$global:HasRootCA           = $false   # Mock State
$global:RootDaysRemaining   = 400     # Mock Wert (> 30 Tage = Grün)
$global:HasIntermediate     = $false   # Mock State
$global:InterDaysRemaining  = 25      # Mock Wert (< 30 Tage = Orange für Test)
$global:IntermediateHasPass = $false

# --- PASSWORT DIALOG ---
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

# --- CONTROLS REINIZIALISIEREN & MAP PEN ---
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
$BtnRenewRootCA         = $window.FindName("BtnRenewRootCA")
$BtnRenewIntermediate   = $window.FindName("BtnRenewIntermediate")

$GridServices           = $window.FindName("GridServices")
$BtnNewService          = $window.FindName("BtnNewService")

# Form Controls
$TxtRootCn              = $window.FindName("TxtRootCn")
$TxtRootOrg             = $window.FindName("TxtRootOrg")
$TxtRootOu              = $window.FindName("TxtRootOu")
$TxtRootCountry         = $window.FindName("TxtRootCountry")
$TxtRootState           = $window.FindName("TxtRootState")
$TxtRootLocality        = $window.FindName("TxtRootLocality")
$TxtRootDays            = $window.FindName("TxtRootDays")
$PwdRootPass            = $window.FindName("PwdRootPass")
$PwdRootPassConfirm     = $window.FindName("PwdRootPassConfirm")
$BtnCancelRootCA        = $window.FindName("BtnCancelRootCA")
$BtnSaveRootCA          = $window.FindName("BtnSaveRootCA")

$TxtInterCn             = $window.FindName("TxtInterCn")
$TxtInterOrg            = $window.FindName("TxtInterOrg")
$TxtInterDays           = $window.FindName("TxtInterDays")
$PwdInterPass           = $window.FindName("PwdInterPass")
$PwdInterPassConfirm    = $window.FindName("PwdInterPassConfirm")
$BtnCancelIntermediate  = $window.FindName("BtnCancelIntermediate")
$BtnSaveIntermediate    = $window.FindName("BtnSaveIntermediate")

$TxtServiceDays         = $window.FindName("TxtServiceDays")
$ChkExportPfx           = $window.FindName("ChkExportPfx")
$ChkExportCrt           = $window.FindName("ChkExportCrt")
$ChkExportKey           = $window.FindName("ChkExportKey")
$ChkExportPemOnly       = $window.FindName("ChkExportPemOnly")
$ChkExportPemFull       = $window.FindName("ChkExportPemFull")
$BtnCancelNewService    = $window.FindName("BtnCancelNewService")
$BtnSaveNewService      = $window.FindName("BtnSaveNewService")

$TxtConfigEditor        = $window.FindName("TxtConfigEditor")
$BtnOpenConfig          = $window.FindName("BtnOpenConfig")
$BtnBackFromConfig      = $window.FindName("BtnBackFromConfig")
$BtnSaveConfig          = $window.FindName("BtnSaveConfig")

$TxtStatus              = $window.FindName("TxtStatus")

# Init Config Text
$TxtConfigEditor.Text   = $rawConfigText

# Helper: Farbcode basierend auf Resttagen ermitteln
function Get-StatusColor {
    param([int]$Days)
    if ($Days -le 0) { return "#D13438" }    # Rot / Abgelaufen
    if ($Days -lt 30) { return "#D97706" }   # Orange / Warnung
    return "#107C41"                        # Grün / Gut
}

# Helper: Button Style dynamisch anpassen
function Set-ButtonStyle {
    param(
        [System.Windows.Controls.Button]$Button,
        [int]$DaysRemaining
    )
    if ($DaysRemaining -lt 30) {
        # Hervorgehoben (Blauer CA Button Style)
        $Button.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0078D4")
        $Button.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("White")
        $Button.BorderThickness = New-Object System.Windows.Thickness(0)
    } else {
        # Normal (Outline Button Style)
        $Button.Background = [System.Windows.Media.Brushes]::Transparent
        $Button.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0078D4")
        $Button.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0078D4")
        $Button.BorderThickness = New-Object System.Windows.Thickness(1)
    }
}

# STATUS-AKTUALISIERUNG INFRASTRUKTUR
function Update-DashboardStatus {
    if ($global:HasRootCA) {
        $TxtRootCaInfo.Text  = "MeinHeimnetz Root CA"
        
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
            $TxtInterCaInfo.Text  = "Aktiv ($passState)"
            
            $interColor = Get-StatusColor -Days $global:InterDaysRemaining
            $TxtInterCaExpiry.Text = "(Gültig bis: 2026-10-25, $global:InterDaysRemaining Tage restlich)"
            $TxtInterCaExpiry.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($interColor)

            $TxtSignModeInfo.Text = "Aktiv signierende CA: Intermediate-CA"

            # Wenn Intermediate CA existiert -> Button zum Anlegen ausblenden & Renew anzeigen
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

Update-DashboardStatus

# DEMO / MOCK DATA GRID (Grün, Orange, Rot Beispiele)
$mockServices = @(
    [PSCustomObject]@{ DisplayName = "Proxmox Cluster (Gutes Zertifikat)"; Status = "Gültig"; ExpiryDate = "2027-09-30"; DaysRemaining = "365"; StatusColor = (Get-StatusColor -Days 365) },
    [PSCustomObject]@{ DisplayName = "Home Assistant (Fällig in Kürze)";    Status = "Warnung"; ExpiryDate = "2026-10-15"; DaysRemaining = "15";  StatusColor = (Get-StatusColor -Days 15) },
    [PSCustomObject]@{ DisplayName = "OPNsense Firewall (Abgelaufen)";     Status = "Abgelaufen"; ExpiryDate = "2026-08-01"; DaysRemaining = "-60"; StatusColor = (Get-StatusColor -Days -60) }
)
$GridServices.ItemsSource = $mockServices

# --- EVENT HANDLER ---
$BtnShowCreateRootCA.Add_Click({ $MainTabControl.SelectedItem = $TabCreateRootCA; $TxtStatus.Text = "Root-CA Konfiguration..." })
$BtnCancelRootCA.Add_Click({ $MainTabControl.SelectedItem = $TabDashboard; $TxtStatus.Text = "Bereit." })

$BtnShowCreateIntermediate.Add_Click({ $MainTabControl.SelectedItem = $TabCreateIntermediate; $TxtStatus.Text = "Intermediate-CA Konfiguration..." })
$BtnCancelIntermediate.Add_Click({ $MainTabControl.SelectedItem = $TabDashboard; $TxtStatus.Text = "Bereit." })

$BtnNewService.Add_Click({ $MainTabControl.SelectedItem = $TabNewService; $TxtStatus.Text = "Neues Service-Zertifikat..." })
$BtnCancelNewService.Add_Click({ $MainTabControl.SelectedItem = $TabDashboard; $TxtStatus.Text = "Bereit." })

$BtnOpenConfig.Add_Click({ $MainTabControl.SelectedItem = $TabConfig; $TxtStatus.Text = "Config-Editor geöffnet." })
$BtnBackFromConfig.Add_Click({ $MainTabControl.SelectedItem = $TabDashboard; $TxtStatus.Text = "Bereit." })

# CONFIG SPEICHERN
$BtnSaveConfig.Add_Click({
    [System.IO.File]::WriteAllText($configPath, $TxtConfigEditor.Text, [System.Text.Encoding]::UTF8)
    [System.Windows.MessageBox]::Show("config.yaml wurde gespeichert!", "Erfolg", "OK", "Information")
    $TxtStatus.Text = "Konfiguration gespeichert."
})

# RENEW CA HANDLERS
$BtnRenewRootCA.Add_Click({
    $pwd = Get-CaPassword -PromptText "Root-CA Passwort zur Erneuerung erforderlich:"
    if ($pwd) {
        $global:RootDaysRemaining = 10957
        Update-DashboardStatus
        $TxtStatus.Text = "Root-CA wurde erfolgreich erneuert."
    }
})

$BtnRenewIntermediate.Add_Click({
    $pwd = Get-CaPassword -PromptText "Root-CA Passwort zur Signierung der Intermediate-CA erforderlich:"
    if ($pwd) {
        $global:InterDaysRemaining = 1826
        Update-DashboardStatus
        $TxtStatus.Text = "Intermediate-CA wurde erfolgreich erneuert."
    }
})

# AKTIONEN SPEICHERN SIMULATION
$BtnSaveRootCA.Add_Click({
    if ([string]::IsNullOrEmpty($PwdRootPass.Password)) {
        [System.Windows.MessageBox]::Show("Root-CA erfordert ein Passwort!", "Fehler", "OK", "Error")
        return
    }
    $global:HasRootCA = $true
    Update-DashboardStatus
    $MainTabControl.SelectedItem = $TabDashboard
    $TxtStatus.Text = "Root-CA erfolgreich angelegt."
})

$BtnSaveIntermediate.Add_Click({
    $rootPwd = Get-CaPassword -PromptText "Root-CA Passwort zur Signierung erforderlich:"
    if ([string]::IsNullOrEmpty($rootPwd)) { return }

    $global:HasIntermediate = $true
    $global:IntermediateHasPass = (-not [string]::IsNullOrEmpty($PwdInterPass.Password))
    Update-DashboardStatus

    $MainTabControl.SelectedItem = $TabDashboard
    $TxtStatus.Text = "Intermediate-CA erfolgreich angelegt!"
})

$BtnSaveNewService.Add_Click({
    if ($global:HasIntermediate -and -not $global:IntermediateHasPass) {
        $TxtStatus.Text = "Zertifikat passwortlos via Intermediate-CA ausgestellt."
    } else {
        $pwd = Get-CaPassword -PromptText "CA-Passwort zur Signierung erforderlich:"
        if ([string]::IsNullOrEmpty($pwd)) { return }
        $TxtStatus.Text = "Service-Zertifikat signiert und ausgestellt."
    }
    $MainTabControl.SelectedItem = $TabDashboard
})

$window.ShowDialog() | Out-Null