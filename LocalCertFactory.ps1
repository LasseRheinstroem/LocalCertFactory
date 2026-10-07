# ==========================================
# LOCAL CERT FACTORY - MAIN SCRIPT
# ==========================================

Add-Type -AssemblyName PresentationFramework

# --- 0. SCRIPT ENVIRONMENT ---
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$xamlPath   = Join-Path $ScriptDir "gui.xaml"
$configPath = Join-Path $ScriptDir "config.yaml"

# --- 1. MODULE & DATEI-PRÜFUNG ---
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

# --- 3. DEFAULT CONFIG & DEKLARATION ---
$defaultConfigText = @"
# ==========================================
# LocalCertFactory Configuration
# ==========================================

paths:
  openssl_exe: "openssl"
  ca_directory: "CA"
  certs_directory: "CA/certs"

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
    validity_days: 10957
    key_algorithm: "RSA"
    key_length: 4096
    base_filename: "RootCA"

  intermediate_ca:
    enabled: true
    has_password: false
    common_name: "MeinHeimnetz Intermediate CA"
    ou: "Issuing CA"
    validity_days: 1826
    key_algorithm: "RSA"
    key_length: 2048
    pathlen: 0
    base_filename: "IntermediateCA"

  services:
    validity_days: 365
    key_algorithm: "RSA"
    key_length: 2048
    default_eku: "TLS Web Server Authentication (serverAuth)"
    exports:
      pfx: true
      crt: true
      key: true
      pem_cert: false
      pem_full: true

# Soll-Definition aller angelegten Services
service_certificates: []
"@

# --- 4. FUNKTIONEN (OPENSSL & CONFIG HELPER) ---

function Test-OpenBinary {
    param([string]$PathCandidate)
    try {
        if ([string]::IsNullOrWhiteSpace($PathCandidate)) { return $null }

        if (-not (Test-Path $PathCandidate -ErrorAction SilentlyContinue)) {
            $cmd = Get-Command $PathCandidate -ErrorAction SilentlyContinue
            if ($cmd) { $PathCandidate = $cmd.Source } else { return $null }
        }

        $tempFile = Join-Path $env:TEMP "openssl_ver.txt"
        $process = Start-Process -FilePath $PathCandidate -ArgumentList "version" -NoNewWindow -PassThru -RedirectStandardOutput $tempFile
        $null = $process.WaitForExit(3000) # Max 3 Sek warten

        if (Test-Path $tempFile) {
            $verOutput = Get-Content $tempFile -Raw
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

            if ($verOutput -match "OpenSSL\s+([0-9]+\.[0-9]+\.[0-9]+)") {
                return [PSCustomObject]@{
                    Path    = $PathCandidate
                    Version = [version]$matches[1]
                    RawText = $verOutput.Trim()
                }
            }
        }
    } catch {
        return $null
    }
    return $null
}

function Find-OpenSSL {
    param(
        [string]$ConfigPath,
        [version]$MinVersion = [version]"1.1.1"
    )

    $foundPath = $null
    $detectedVersion = $null

    # 1. Pfad aus Config prüfen
    if (-not [string]::IsNullOrEmpty($ConfigPath)) {
        $res = Test-OpenBinary -PathCandidate $ConfigPath
        if ($res) { $foundPath = $res.Path; $detectedVersion = $res.Version }
    }
    # 2. Im System-PATH suchen
    if (-not $foundPath) {
        $res = Test-OpenBinary -PathCandidate "openssl.exe"
        if ($res) {
            $foundPath = $res.Path;
            $detectedVersion = $res.Version
        }
    }
    # 3. Typische Standardpfade durchsuchen (inkl. Git)
    if (-not $foundPath) {
        $commonPaths = @(
            "C:\Program Files\Git\usr\bin\openssl.exe",
            "C:\Program Files (x86)\Git\usr\bin\openssl.exe",
            "C:\Program Files\OpenSSL-Win64\bin\openssl.exe",
            "C:\Program Files\OpenSSL-Win32\bin\openssl.exe",
            "C:\ProgramData\chocolatey\bin\openssl.exe"
        )
        foreach ($path in $commonPaths) {
            $res = Test-OpenBinary -PathCandidate $path
            if ($res) {
                $foundPath = $res.Path
                $detectedVersion = $res.Version
                break
            }
        }
    }
    # 4. Falls immer noch nichts gefunden: Dialog öffnen
    if (-not $foundPath) {
        [System.Windows.MessageBox]::Show(
            "OpenSSL wurde im System nicht automatisch gefunden.`nBitte wähle die 'openssl.exe' manuell aus.",
            "OpenSSL erforderlich", "OK", "Warning"
        ) | Out-Null

        $openFileDialog = New-Object Microsoft.Win32.OpenFileDialog
        $openFileDialog.Filter = "Ausführbare Dateien (*.exe)|*.exe|Alle Dateien (*.*)|*.*"
        $openFileDialog.Title = "Bitte 'openssl.exe' auswählen"
        $openFileDialog.FileName = "openssl.exe"

        if ($openFileDialog.ShowDialog() -eq $true) {
            $res = Test-OpenBinary -PathCandidate $openFileDialog.FileName
            if ($res) {
                $foundPath = $res.Path
                $detectedVersion = $res.Version
            } else {
                [System.Windows.MessageBox]::Show("Die ausgewählte Datei ist keine gültige OpenSSL-Binärdatei!", "Fehler", "OK", "Error") | Out-Null
                return $null
            }
        } else {
            return $null
        }
    }
    # 5. Mindestversion prüfen
    if ($detectedVersion -and $detectedVersion -lt $MinVersion) {
        [System.Windows.MessageBox]::Show(
            "Die gefundene OpenSSL-Version ($detectedVersion) ist zu alt!`nErforderlich ist mindestens Version $MinVersion.`nPfad: $foundPath",
            "Veraltete OpenSSL Version", "OK", "Error"
        ) | Out-Null
        return $null
    }

    return [PSCustomObject]@{
        Success = $true
        Path    = $foundPath
        Version = $detectedVersion
    }
}

function Get-AbsolutePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return [System.IO.Path]::GetFullPath((Join-Path $ScriptDir $Path))
}

function Get-CaFilePaths {
    param(
        [string]$CaDir,
        [string]$BaseName
    )

    if ([string]::IsNullOrWhiteSpace($BaseName)) { return $null }

    return @{
        BaseName = $BaseName
        CrtPath  = Join-Path $CaDir "$BaseName.crt"
        KeyPath  = Join-Path $CaDir "$BaseName.key"
        PfxPath  = Join-Path $CaDir "$BaseName.pfx"
    }
}

function Get-CertDetailsFromFile {
    param(
        [string]$CrtPath,
        $SigningCaCert = $null
    )

    if (-not (Test-Path $CrtPath)) { return $null }

    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CrtPath)
        $now = Get-Date
        $daysRemaining = [math]::Max(0, ($cert.NotAfter - $now).Days)

        # Sprachunabhängige SAN-Extraktion (OID 2.5.29.17)
        $sanList = @()
        $sanExt = $cert.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.17" }
        if ($sanExt) {
            $sanFormatted = $sanExt.Format($true)
            $lines = $sanFormatted -split "[\r\n,]+"
            foreach ($line in $lines) {
                $cleanLine = $line.Trim()
                if ([string]::IsNullOrWhiteSpace($cleanLine)) { continue }
                $val = $cleanLine -replace '^(DNS-Name|DNS Name|IP-Adresse|IP Address|URL|Registered ID)=', ''
                $val = $val.Trim()
                if ($val -and $sanList -notcontains $val) { $sanList += $val }
            }
        }

        # Statusermittlung
        $warnDays = if ($global:Config.defaults.threshold_days_warning) { [int]$global:Config.defaults.threshold_days_warning } else { 30 }
        $critDays = if ($global:Config.defaults.threshold_days_critical) { [int]$global:Config.defaults.threshold_days_critical } else { 7 }

        $status = "Gültig"
        $color  = "#107C41" # Grün

        # 1. Mismatch / Defekt-Prüfung gegen aktive CA
        $isChainValid = $true
        if ($SigningCaCert) {
            # Prüft, ob der Issuer des Zertifikats zum Subject der Unterzeichner-CA passt
            # sowie Abgleich des Authority Key Identifiers
            if ($cert.Issuer -ne $SigningCaCert.Subject) {
                $isChainValid = $false
            }
        }

        if (-not $isChainValid) {
            $status = "Defekt"
            $color  = "#A80000" # Dunkelrot
        } elseif ($daysRemaining -le 0) {
            $status = "Abgelaufen"
            $color  = "#D13438" # Rot
        } elseif ($daysRemaining -le $critDays) {
            $status = "Kritisch"
            $color  = "#D13438" # Rot
        } elseif ($daysRemaining -le $warnDays) {
            $status = "Warnung"
            $color  = "#D97706" # Orange
        }

        return [PSCustomObject]@{
            IsMissing      = $false
            Subject        = $cert.Subject
            Issuer         = $cert.Issuer
            CommonName     = ($cert.Subject -replace '.*CN=([^,]+).*', '$1')
            NotBefore      = $cert.NotBefore
            NotAfter       = $cert.NotAfter
            ExpiryDate     = $cert.NotAfter.ToString("yyyy-MM-dd")
            DaysRemaining  = $daysRemaining
            SerialNumber   = $cert.SerialNumber
            Thumbprint     = $cert.Thumbprint
            SANs           = ($sanList -join ", ")
            Status         = $status
            StatusColor    = $color
            RawCert        = $cert
        }
    } catch {
        return $null
    }
}

function Get-SystemPkiState {
    $caDir   = Get-AbsolutePath $global:Config.paths.ca_directory
    $certDir = Get-AbsolutePath $global:Config.paths.certs_directory

    # Dynamische Pfade aus Config-BaseNames ermitteln
    $rootBase  = if ($global:Config.defaults.root_ca.base_filename) { $global:Config.defaults.root_ca.base_filename } else { "RootCA" }
    $interBase = if ($global:Config.defaults.intermediate_ca.base_filename) { $global:Config.defaults.intermediate_ca.base_filename } else { "IntermediateCA" }

    $rootPaths  = Get-CaFilePaths -CaDir $caDir -BaseName $rootBase
    $interPaths = Get-CaFilePaths -CaDir $caDir -BaseName $interBase

    $rootCertDetails  = Get-CertDetailsFromFile -CrtPath $rootPaths.CrtPath
    $interCertDetails = Get-CertDetailsFromFile -CrtPath $interPaths.CrtPath

    # Aktive Unterzeichner-CA ermitteln (Intermediate bevorzugt, sonst Root)
    $activeSigningCert = if ($interCertDetails) { $interCertDetails.RawCert } elseif ($rootCertDetails) { $rootCertDetails.RawCert } else { $null }

    $state = @{
        RootCA         = $rootCertDetails
        IntermediateCA = $interCertDetails
        Services       = @()
    }

    if (Test-Path $interPaths.KeyPath) {
        $keyContent = Get-Content $interPaths.KeyPath -Raw
        $state.IntermediateHasPass = ($keyContent -match "ENCRYPTED")
    } else {
        $state.IntermediateHasPass = $false
    }

    # Tracking-Liste verarbeiteter Dateien
    $processedFiles = @()

    # 1. Alle in config.yaml definierten Services durchgehen (Soll-Zustand)
    if ($global:Config.service_certificates) {
        foreach ($cfgSvc in $global:Config.service_certificates) {
            $cn = $cfgSvc.common_name
            $safeFileName = $cn -replace '[^a-zA-Z0-9\.-]', '_'
            $expectedCrtPath = Join-Path $certDir "$safeFileName.crt"

            if (Test-Path $expectedCrtPath) {
                # Datei existiert -> Details mit CA-Matching laden
                $certInfo = Get-CertDetailsFromFile -CrtPath $expectedCrtPath -SigningCaCert $activeSigningCert
                $processedFiles += $expectedCrtPath
            } else {
                # Status 1: FEHLT (Phase 3)
                $dnsSANs = if ($cfgSvc.sans_dns) { $cfgSvc.sans_dns -join ", " } else { "" }
                $ipSANs  = if ($cfgSvc.sans_ip)  { $cfgSvc.sans_ip -join ", " }  else { "" }
                $allSANs = @($dnsSANs, $ipSANs) | Where-Object { $_ -ne "" } | Join-String -Separator ", "

                $certInfo = [PSCustomObject]@{
                    IsMissing      = $true
                    Subject        = "CN=$cn"
                    Issuer         = "N/A"
                    CommonName     = $cn
                    NotBefore      = $null
                    NotAfter       = $null
                    ExpiryDate     = "N/A (Fehlt)"
                    DaysRemaining  = $null
                    SerialNumber   = "N/A"
                    Thumbprint     = "N/A"
                    SANs           = $allSANs
                    Status         = "Fehlt"
                    StatusColor    = "#7A7A7A" # Grau
                    RawCert        = $null
                }
            }

            $displayName = if ($cfgSvc.display_name) { $cfgSvc.display_name } else { $cn }
            $ekuVal      = if ($cfgSvc.eku) { $cfgSvc.eku } else { "Server Certificate" }

            $certInfo | Add-Member -NotePropertyName "DisplayName" -NotePropertyValue $displayName -Force
            $certInfo | Add-Member -NotePropertyName "EKU" -NotePropertyValue $ekuVal -Force

            $state.Services += $certInfo
        }
    }

    # 2. Waise .crt-Dateien erfassen, die auf der Festplatte liegen, aber nicht in der Config stehen
    if (Test-Path $certDir) {
        $allCrtFiles = Get-ChildItem -Path $certDir -Filter "*.crt"
        foreach ($file in $allCrtFiles) {
            if ($processedFiles -notcontains $file.FullName) {
                $certInfo = Get-CertDetailsFromFile -CrtPath $file.FullName -SigningCaCert $activeSigningCert
                if ($certInfo) {
                    $certInfo | Add-Member -NotePropertyName "DisplayName" -NotePropertyValue $certInfo.CommonName -Force
                    $certInfo | Add-Member -NotePropertyName "EKU" -NotePropertyValue "Unbekannt (Orphan)" -Force
                    $state.Services += $certInfo
                }
            }
        }
    }

    return $state
}

function Repair-ServiceCertificates {
    param(
        [array]$CertificatesToRepair,
        [string]$CaPassword = $null
    )

    foreach ($certItem in $CertificatesToRepair) {
        # Suche passende Soll-Konfiguration in der config.yaml
        $cfgMatch = $global:Config.service_certificates | Where-Object { $_.common_name -eq $certItem.CommonName }

        if (-not $cfgMatch) {
            Write-Warning "Keine Soll-Konfiguration für '$($certItem.CommonName)' in config.yaml gefunden. Überspringe..."
            continue
        }

        # Parameter für Neuausstellung zusammenbauen
        $params = @{
            DisplayName  = if ($cfgMatch.display_name) { $cfgMatch.display_name } else { $cfgMatch.common_name }
            CommonName   = $cfgMatch.common_name
            Organization = $global:Config.defaults.organization
            OU           = $global:Config.defaults.root_ca.ou
            Country      = $global:Config.defaults.country
            Locality     = $global:Config.defaults.locality
            SANsDNS      = $cfgMatch.sans_dns
            SANsIP       = $cfgMatch.sans_ip
            EKU          = if ($cfgMatch.eku) { $cfgMatch.eku } else { "TLS Web Server Authentication (serverAuth)" }
            ValidityDays = [int]$global:Config.defaults.services.validity_days
            KeyAlgorithm = $global:Config.defaults.services.key_algorithm
            KeyLength    = $global:Config.defaults.services.key_length
            Exports      = $global:Config.defaults.services.exports
        }

        $splat = @{ Params = $params }
        if ($CaPassword) { $splat['CaPassword'] = $CaPassword }

        # Erneute Ausstellung ausführen (überschreibt defekte/abgelaufene Dateien sauber)
        New-ServiceCertificate @splat
    }
}

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

function Save-ConfigToFile {
    $yamlString = ConvertTo-Yaml -Data $global:Config
    [System.IO.File]::WriteAllText($configPath, $yamlString, [System.Text.Encoding]::UTF8)
    if ($TxtConfigEditor) { $TxtConfigEditor.Text = $yamlString }
}

# --- 5. FUNKTIONEN (GUI HELPER & DIALOGE) ---

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
    for ($i = 0; $i -lt $ComboBox.Items.Count; $i++) {
        $item = $ComboBox.Items[$i]
        $content = if ($item -is [System.Windows.Controls.ComboBoxItem]) { $item.Content.ToString() } else { $item.ToString() }
        if ($content -eq $Value) {
            $ComboBox.SelectedIndex = $i
            return
        }
    }
}

function LoadConfigToForm {
    $cfg = $global:Config
    $pkiState = Get-SystemPkiState

    $global:HasRootCA           = ($null -ne $pkiState.RootCA)
    $global:HasIntermediate     = ($null -ne $pkiState.IntermediateCA)
    $global:IntermediateHasPass = $pkiState.IntermediateHasPass

    # Formularfelder füllen
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
    if ($TxtRootBaseFilename) { $TxtRootBaseFilename.Text = $cfg.defaults.root_ca.base_filename }

    # Intermediate CA
    if ($TxtInterCn)      { $TxtInterCn.Text      = $cfg.defaults.intermediate_ca.common_name }
    if ($TxtInterOrg)     { $TxtInterOrg.Text     = $cfg.defaults.organization }
    if ($TxtInterDays)    { $TxtInterDays.Text    = $cfg.defaults.intermediate_ca.validity_days.ToString() }
    if ($TxtInterPathLen -and $null -ne $cfg.defaults.intermediate_ca.pathlen) { 
        $TxtInterPathLen.Text = $cfg.defaults.intermediate_ca.pathlen.ToString() 
    }
    Set-ComboBoxByText -ComboBox $CmbInterAlgorithm -Value $cfg.defaults.intermediate_ca.key_algorithm
    Set-ComboBoxByText -ComboBox $CmbInterKeyLength -Value $cfg.defaults.intermediate_ca.key_length.ToString()
    if ($TxtInterBaseFilename) { $TxtInterBaseFilename.Text = $cfg.defaults.intermediate_ca.base_filename }

    # Service Defaults & Identitätsattribute
    if ($TxtServiceOrg)      { $TxtServiceOrg.Text      = $cfg.defaults.organization }
    if ($TxtServiceOu)       { $TxtServiceOu.Text       = $cfg.defaults.root_ca.ou }
    if ($TxtServiceCountry)  { $TxtServiceCountry.Text  = $cfg.defaults.country }
    if ($TxtServiceLocality) { $TxtServiceLocality.Text = $cfg.defaults.locality }
    if ($TxtServiceDays)     { $TxtServiceDays.Text     = $cfg.defaults.services.validity_days.ToString() }
    
    Set-ComboBoxByText -ComboBox $CmbServiceAlgorithm -Value $cfg.defaults.services.key_algorithm
    Set-ComboBoxByText -ComboBox $CmbServiceKeyLength -Value $cfg.defaults.services.key_length.ToString()
    
    if ($ChkExportPfx)     { $ChkExportPfx.IsChecked     = [bool]$cfg.defaults.services.exports.pfx }
    if ($ChkExportCrt)     { $ChkExportCrt.IsChecked     = [bool]$cfg.defaults.services.exports.crt }
    if ($ChkExportKey)     { $ChkExportKey.IsChecked     = [bool]$cfg.defaults.services.exports.key }
    if ($ChkExportPemOnly) { $ChkExportPemOnly.IsChecked = [bool]$cfg.defaults.services.exports.pem_cert }
    if ($ChkExportPemFull) { $ChkExportPemFull.IsChecked = [bool]$cfg.defaults.services.exports.pem_full }

    if ($TxtConfigEditor) { $TxtConfigEditor.Text = ConvertTo-Yaml -Data $cfg }
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
                if ($daysVal -le $WarningThreshold) { return $true }
            }
        }
    }
    return $false
}

function Update-DashboardStatus {
    $pkiState = Get-SystemPkiState

    $global:HasRootCA           = ($null -ne $pkiState.RootCA)
    $global:HasIntermediate     = ($null -ne $pkiState.IntermediateCA)
    $global:IntermediateHasPass = $pkiState.IntermediateHasPass

    $canIssueCertificates = $global:HasRootCA

    # UI-Sperren
    if ($BtnNewService) {
        $BtnNewService.IsEnabled = $canIssueCertificates
        $BtnNewService.ToolTip = if (-not $canIssueCertificates) { "Es muss zuerst eine Root-CA angelegt werden." } else { $null }
    }
    if ($PanelNoCaWarning) { $PanelNoCaWarning.Visibility = if ($canIssueCertificates) { "Collapsed" } else { "Visible" } }

    if ($BtnShowCreateIntermediate) {
        $BtnShowCreateIntermediate.IsEnabled = $canIssueCertificates
    }
    if ($PanelNoRootForInterWarning) { $PanelNoRootForInterWarning.Visibility = if ($canIssueCertificates) { "Collapsed" } else { "Visible" } }

    # Grid Datenbindung
    if ($GridServices) {
        $GridServices.ItemsSource = $pkiState.Services
    }

    # Root-CA Details anzeigen
    if ($global:HasRootCA) {
        $root = $pkiState.RootCA
        $global:RootDaysRemaining = $root.DaysRemaining

        $TxtRootCaInfo.Text  = $root.CommonName
        $TxtRootCaExpiry.Text = "(Gültig bis: $($root.ExpiryDate), $($root.DaysRemaining) Tage restlich)"
        $TxtRootCaExpiry.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($root.StatusColor)

        $PanelCaDetails.Visibility = "Visible"
        $TxtCaMissing.Visibility   = "Collapsed"
        $BtnShowCreateRootCA.Visibility = "Collapsed"
        $BtnRenewRootCA.Visibility = "Visible"
        Set-ButtonStyle -Button $BtnRenewRootCA -DaysRemaining $root.DaysRemaining

        # Intermediate-CA Details
        if ($global:HasIntermediate) {
            $inter = $pkiState.IntermediateCA
            $global:InterDaysRemaining = $inter.DaysRemaining

            $passState = if ($global:IntermediateHasPass) { "Passwortgeschützt" } else { "Passwortlos" }
            $TxtInterCaInfo.Text  = "$($inter.CommonName) ($passState)"
            $TxtInterCaExpiry.Text = "(Gültig bis: $($inter.ExpiryDate), $($inter.DaysRemaining) Tage restlich)"
            $TxtInterCaExpiry.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($inter.StatusColor)

            $TxtSignModeInfo.Text = "Aktiv signierende CA: Intermediate-CA"
            $BtnShowCreateIntermediate.Visibility = "Collapsed"
            $BtnRenewIntermediate.Visibility      = "Visible"
            Set-ButtonStyle -Button $BtnRenewIntermediate -DaysRemaining $inter.DaysRemaining
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

    # Erneuerungsbuttons
    $hasServices = ($pkiState.Services.Count -gt 0)
    if ($BtnRenewSelected) { $BtnRenewSelected.IsEnabled = $hasServices }
    if ($BtnRenewDue) { 
        $hasDue = Test-HasDueServices -Services $pkiState.Services
        $BtnRenewDue.IsEnabled = $hasDue 
    }
}

function Invoke-OpenSSL {
    param(
        [string[]]$Arguments,
        [string]$StdInput = $null
    )

    $openSslExe = $global:Config.paths.openssl_exe

    if ([string]::IsNullOrWhiteSpace($openSslExe)) {
        throw "Der OpenSSL-Pfad ist nicht konfiguriert."
    }

    # Falls nur "openssl" bzw. "openssl.exe" konfiguriert ist,
    # den tatsächlichen Pfad auflösen.
    if (-not (Test-Path $openSslExe -ErrorAction SilentlyContinue)) {
        $cmd = Get-Command $openSslExe -ErrorAction SilentlyContinue
        if ($cmd) { $openSslExe = $cmd.Source } else { throw "OpenSSL Executable nicht gefunden unter: $openSslExe" }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $openSslExe

    if ($psi.PSObject.Properties.Name -contains "ArgumentList") {
        foreach ($arg in $Arguments) {
            $psi.ArgumentList.Add([string]$arg)
        }
    } else {
        $escapedArguments = foreach ($arg in $Arguments) {
            $arg = [string]$arg
            if ($arg -match '[\s"]') {
                $escaped = $arg -replace '(\\*)"', '$1$1\"'
                $escaped = $escaped -replace '(\\+)$', '$1$1'
                '"' + $escaped + '"'
            } else {
                $arg
            }
        }
        $psi.Arguments = ($escapedArguments -join ' ')
    }

    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = ($null -ne $StdInput)
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    try {
        $process = [System.Diagnostics.Process]::Start($psi)

        if ($null -ne $StdInput) {
            $writer = $process.StandardInput
            $writer.WriteLine($StdInput)
            $writer.Flush()
            $writer.Close()
        }

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()

        $process.WaitForExit()

        if ($process.ExitCode -ne 0) {
            throw "OpenSSL-Fehler (Code $($process.ExitCode)):`n$stderr"
        }

        return $stdout
    } catch {
        throw "Fehler beim Aufruf von OpenSSL:`n$($_.Exception.Message)"
    }
}

function New-RootCA {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingPlainTextForPassword", "")]
    param(
        [Parameter(Mandatory=$true)][string]$Password,
        [hashtable]$Params
    )

    $caDir = Get-AbsolutePath $global:Config.paths.ca_directory
    if (-not (Test-Path $caDir)) { New-Item -ItemType Directory -Path $caDir -Force | Out-Null }

    $baseName = if ($Params.BaseFilename) { $Params.BaseFilename } else { "RootCA" }
    $keyPath  = Join-Path $caDir "$baseName.key"
    $crtPath  = Join-Path $caDir "$baseName.crt"
    $pfxPath  = Join-Path $caDir "$baseName.pfx"

    $subj = "/C=$($Params.Country)/ST=$($Params.State)/L=$($Params.Locality)/O=$($Params.Organization)/OU=$($Params.OU)/CN=$($Params.CommonName)"

    # Temp OpenSSL Config für Root Extensions
    $cnfPath = Join-Path $env:TEMP "root_ca.cnf"
    $cnfContent = @"
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = v3_ca
prompt = no
default_days = $($Params.ValidityDays)

[ req_distinguished_name ]
CN = $($Params.CommonName)

[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
"@
    Set-Content -Path $cnfPath -Value $cnfContent -Encoding UTF8

    try {
        # 1. Schlüssel & Selbstsigniertes Zertifikat in einem Schritt
        $openSslArgs = @(
            "req", "-new", "-x509",
            "-config", $cnfPath,
            "-newkey", "rsa:$($Params.KeyLength)",
            "-keyout", $keyPath,
            "-out", $crtPath,
            "-days", $Params.ValidityDays.ToString(),
            "-subj", $subj
        )

        # Passwort-Optionen für den neuen Key
        if (-not [string]::IsNullOrWhiteSpace($Password)) {
            $openSslArgs += "-passout"
            $openSslArgs += "pass:$Password"
        } else {
            $openSslArgs += "-nodes"
        }

        Invoke-OpenSSL -Arguments $openSslArgs | Out-Null

        # Prüfung: Würde sonst bei X509Certificate2 abstürzen
        if (-not (Test-Path $crtPath)) {
            throw "OpenSSL hat die Zertifikatsdatei '$crtPath' nicht erzeugt."
        }

        # 2. Erstelle Root PFX
        $pfxPass = if (-not [string]::IsNullOrWhiteSpace($Password)) { "pass:$Password" } else { "pass:" }
        $pfxArgs = @(
            "pkcs12", "-export",
            "-out", $pfxPath,
            "-inkey", $keyPath,
            "-in", $crtPath,
            "-passin", $pfxPass,
            "-passout", $pfxPass
        )

        Invoke-OpenSSL -Arguments $pfxArgs | Out-Null

    } finally {
        if (Test-Path $cnfPath) { Remove-Item $cnfPath -Force -ErrorAction SilentlyContinue }
    }
}

function Renew-RootCA {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingPlainTextForPassword", "")]
    param(
        [Parameter(Mandatory=$true)][string]$Password,
        [hashtable]$Params
    )

    $caDir    = Get-AbsolutePath $global:Config.paths.ca_directory
    $baseName = if ($Params.BaseFilename) { $Params.BaseFilename } else { "RootCA" }
    
    $rootKeyPath = Join-Path $caDir "$baseName.key"
    $rootCrtPath = Join-Path $caDir "$baseName.crt"
    $cnfPath     = Join-Path $caDir "temp_root_renew.cnf"

    if (-not (Test-Path $rootKeyPath)) {
        throw "Der private Schlüssel ($rootKeyPath) existiert nicht. Renew nicht möglich!"
    }

    $days = $Params.ValidityDays
    $configContent = @"
[ req ]
default_bits       = $($Params.KeyLength)
distinguished_name = req_distinguished_name
x509_extensions    = v3_ca
prompt             = no

[ req_distinguished_name ]
C  = $($Params.Country)
ST = $($Params.State)
L  = $($Params.Locality)
O  = $($Params.Organization)
OU = $($Params.OU)
CN = $($Params.CommonName)

[ v3_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:true
keyUsage               = critical, digitalSignature, cRLSign, keyCertSign
"@
    Set-Content -Path $cnfPath -Value $configContent -Encoding UTF8

    try {
        $args = @(
            "req", "-new", "-x509", "-sha256",
            "-days", $days.ToString(),
            "-key", $rootKeyPath,
            "-out", $rootCrtPath,
            "-config", $cnfPath,
            "-passin", "pass:$Password"
        )
        Invoke-OpenSSL -Arguments $args | Out-Null
    }
    finally {
        if (Test-Path $cnfPath) { Remove-Item $cnfPath -Force -ErrorAction SilentlyContinue }
    }
}

function New-IntermediateCA {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingPlainTextForPassword", "")]
    param(
        [Parameter(Mandatory=$true)][string]$RootPassword,
        [string]$IntermediatePassword = $null,
        [hashtable]$Params
    )

    $caDir = Get-AbsolutePath $global:Config.paths.ca_directory
    # Root-Dateiname aus der Config holen
    $rootbaseName = if ($global:Config.defaults.root_ca.base_filename) { $global:Config.defaults.root_ca.base_filename } else { "RootCA" }
    $rootKeyPath  = Join-Path $caDir "$rootbaseName.key"
    $rootCrtPath  = Join-Path $caDir "$rootbaseName.crt"

    # Intermediate-Dateiname aus den übergebenen Parametern
    $baseName     = if ($Params.BaseFilename) { $Params.BaseFilename } else { "IntermediateCA" }
    $interKeyPath = Join-Path $caDir "$baseName.key"
    $interCsrPath = Join-Path $caDir "$baseName.csr"
    $interCrtPath = Join-Path $caDir "$baseName.crt"
    $interPfxPath = Join-Path $caDir "$baseName.pfx"
    $cnfPath      = Join-Path $caDir "temp_inter.cnf"

    $pathLen = if ($Params.ContainsKey('PathLen') -and $null -ne $Params.PathLen) { $Params.PathLen } else { 0 }

    $configContent = @"
[ req ]
default_bits       = $($Params.KeyLength)
distinguished_name = req_distinguished_name
prompt             = no

[ req_distinguished_name ]
C  = $($Params.Country)
ST = $($Params.State)
L  = $($Params.Locality)
O  = $($Params.Organization)
OU = $($Params.OU)
CN = $($Params.CommonName)

[ v3_intermediate_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:true, pathlen:$pathLen
keyUsage               = critical, digitalSignature, cRLSign, keyCertSign
"@
    Set-Content -Path $cnfPath -Value $configContent -Encoding ASCII

    $subj = "/C=$($Params.Country)/ST=$($Params.State)/L=$($Params.Locality)/O=$($Params.Organization)/OU=$($Params.OU)/CN=$($Params.CommonName)"
    $hasInterPassword = -not [string]::IsNullOrWhiteSpace($IntermediatePassword)

    try {
        # 1. Key erzeugen
        if ($hasInterPassword) {
            $keyArgs = @("genrsa", "-aes256", "-passout", "pass:$IntermediatePassword", "-out", $interKeyPath, $Params.KeyLength.ToString())
        } else {
            $keyArgs = @(
                "genrsa",
                "-out", $interKeyPath,
                $Params.KeyLength.ToString()
            )
        }
        Invoke-OpenSSL -Arguments $keyArgs | Out-Null

        # 2. CSR erzeugen
        $csrArgs = @(
            "req", "-new",
            "-config", $cnfPath,
            "-key", $interKeyPath,
            "-out", $interCsrPath,
            "-subj", $subj
        )
        if ($hasInterPassword) {
            $csrArgs += @("-passin", "pass:$IntermediatePassword")
        }
        Invoke-OpenSSL -Arguments $csrArgs | Out-Null

        # 3. Signieren durch Root-CA
        $signArgs = @(
            "x509", "-req",
            "-in", $interCsrPath,
            "-CA", $rootCrtPath,
            "-CAkey", $rootKeyPath,
            "-CAcreateserial",
            "-out", $interCrtPath,
            "-days", $Params.ValidityDays.ToString(),
            "-extfile", $cnfPath,
            "-extensions", "v3_intermediate_ca"
        )
        if (-not [string]::IsNullOrWhiteSpace($RootPassword)) {
            $signArgs += @("-passin", "pass:$RootPassword")
        }
        Invoke-OpenSSL -Arguments $signArgs | Out-Null

        # 4. PFX Exportieren (inkl. Root CA Chain)
        $pfxArgs = @(
            "pkcs12", "-export",
            "-out", $interPfxPath,
            "-inkey", $interKeyPath,
            "-in", $interCrtPath,
            "-certfile", $rootCrtPath
        )
        if ($hasInterPassword) {
            $pfxArgs += @("-passin", "pass:$IntermediatePassword")
            $pfxArgs += @("-passout", "pass:$IntermediatePassword")
        } else {
            $pfxArgs += @("-passout", "pass:")
        }
        Invoke-OpenSSL -Arguments $pfxArgs | Out-Null

    } finally {
        if (Test-Path $cnfPath) { Remove-Item $cnfPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $interCsrPath) { Remove-Item $interCsrPath -Force -ErrorAction SilentlyContinue }
    }
}

function Renew-IntermediateCA {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingPlainTextForPassword", "")]
    param(
        [Parameter(Mandatory=$true)][string]$RootPassword,
        [string]$IntermediatePassword = $null,
        [hashtable]$Params
    )

    $caDir         = Get-AbsolutePath $global:Config.paths.ca_directory
    $rootBaseName  = if ($global:Config.defaults.root_ca.base_filename) { $global:Config.defaults.root_ca.base_filename } else { "RootCA" }
    $rootKeyPath   = Join-Path $caDir "$rootBaseName.key"
    $rootCrtPath   = Join-Path $caDir "$rootBaseName.crt"

    $interBaseName = if ($Params.BaseFilename) { $Params.BaseFilename } else { "IntermediateCA" }
    $interKeyPath  = Join-Path $caDir "$interBaseName.key"
    $interCsrPath  = Join-Path $caDir "$interBaseName.csr"
    $interCrtPath  = Join-Path $caDir "$interBaseName.crt"
    $cnfPath       = Join-Path $caDir "temp_inter_renew.cnf"

    if (-not (Test-Path $interKeyPath)) {
        throw "Der private Schlüssel der Intermediate-CA ($interKeyPath) existiert nicht!"
    }
    if (-not (Test-Path $rootKeyPath) -or -not (Test-Path $rootCrtPath)) {
        throw "Root CA Schlüssel oder Zertifikat fehlt!"
    }

    $days    = $Params.ValidityDays
    $pathLen = $Params.PathLen

    $configContent = @"
[ req ]
default_bits       = $($Params.KeyLength)
distinguished_name = req_distinguished_name
prompt             = no

[ req_distinguished_name ]
C  = $($Params.Country)
ST = $($Params.State)
L  = $($Params.Locality)
O  = $($Params.Organization)
OU = $($Params.OU)
CN = $($Params.CommonName)

[ v3_intermediate_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:true, pathlen:$pathLen
keyUsage               = critical, digitalSignature, cRLSign, keyCertSign
"@
    Set-Content -Path $cnfPath -Value $configContent -Encoding UTF8

    try {
        # 1. Neuen CSR aus dem BESTEHENDEN Intermediate-Key erzeugen
        $csrArgs = @(
            "req", "-new",
            "-key", $interKeyPath,
            "-out", $interCsrPath,
            "-config", $cnfPath
        )
        if (-not [string]::IsNullOrEmpty($IntermediatePassword)) {
            $csrArgs += @("-passin", "pass:$IntermediatePassword")
        }
        Invoke-OpenSSL -Arguments $csrArgs | Out-Null

        $signArgs = @(
            "x509", "-req",
            "-in", $interCsrPath,
            "-CA", $rootCrtPath,
            "-CAkey", $rootKeyPath,
            "-CAcreateserial",
            "-out", $interCrtPath,
            "-days", $days.ToString(),
            "-sha256", "-extfile",
            $cnfPath, "-extensions",
            "v3_intermediate_ca",
            "-passin", "pass:$RootPassword"
        )
        Invoke-OpenSSL -Arguments $signArgs | Out-Null
    }
    finally {
        if (Test-Path $cnfPath) { Remove-Item $cnfPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $interCsrPath) { Remove-Item $interCsrPath -Force -ErrorAction SilentlyContinue }
    }
}

function New-ServiceCertificate {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingPlainTextForPassword", "")]
    param(
        [Parameter(Mandatory=$false)][string]$CaPassword,
        [string]$PfxPassword = $null,
        [hashtable]$Params
    )

    $caDir   = Get-AbsolutePath $global:Config.paths.ca_directory
    $certDir = Get-AbsolutePath $global:Config.paths.certs_directory
    if (-not (Test-Path $certDir)) { New-Item -ItemType Directory -Path $certDir -Force | Out-Null }

    $pkiState = Get-SystemPkiState
    $useInter = ($null -ne $pkiState.IntermediateCA)

    if ($useInter) {
        $interBase    = if ($global:Config.defaults.intermediate_ca.base_filename) { $global:Config.defaults.intermediate_ca.base_filename } else { "IntermediateCA" }
        $signingKeyPath = Join-Path $caDir "$interBase.key"
        $signingCrtPath = Join-Path $caDir "$interBase.crt"
    } else {
        $rootBase     = if ($global:Config.defaults.root_ca.base_filename) { $global:Config.defaults.root_ca.base_filename } else { "RootCA" }
        $signingKeyPath = Join-Path $caDir "$rootBase.key"
        $signingCrtPath = Join-Path $caDir "$rootBase.crt"
    }

    $safeName = $Params.CommonName -replace '[^a-zA-Z0-9\.-]', '_'
    $svcKeyPath  = Join-Path $certDir "$safeName.key"
    $svcCsrPath  = Join-Path $certDir "$safeName.csr"
    $svcCrtPath  = Join-Path $certDir "$safeName.crt"
    $svcPfxPath  = Join-Path $certDir "$safeName.pfx"
    $certPemOnly = Join-Path $certDir "$safeName.pem"
    $certPemFull = Join-Path $certDir "$safeName.full.pem"

    $subj = "/C=$($Params.Country)/ST=$($Params.State)/L=$($Params.Locality)/O=$($Params.Organization)/OU=$($Params.OU)/CN=$($Params.CommonName)"

    # 1. Service Key (unverschlüsselt für Server-Dienste)
    $keyArgs = @(
        "genrsa", "-out",
        $svcKeyPath, $Params.KeyLength.ToString()
    )
    Invoke-OpenSSL -Arguments $keyArgs | Out-Null

    # 2. CSR Erzeugen
    $csrArgs = @(
        "req", "-new",
        "-key", $svcKeyPath,
        "-out", $svcCsrPath,
        "-subj", $subj
    )
    Invoke-OpenSSL -Arguments $csrArgs | Out-Null

    # 3. SAN und Extension Config
    $cnfPath = Join-Path $env:TEMP "svc_ext.cnf"
    $sanList = @("DNS:$($Params.CommonName)")
    
    if ($Params.SANsDNS) {
        foreach ($dns in $Params.SANsDNS) { $sanList += "DNS:$dns" }
    }
    if ($Params.SANsIP) {
        foreach ($ip in $Params.SANsIP) { $sanList += "IP:$ip" }
    }
    $sanString = $sanList -join ","

    $kuString = if ($Params.KeyUsages -and $Params.KeyUsages.Count -gt 0) { $Params.KeyUsages -join ", " } else { "digitalSignature, keyEncipherment" }

    $cnfContent = @"
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = critical, $kuString
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = $sanString
"@
    Set-Content -Path $cnfPath -Value $cnfContent -Encoding UTF8

    try {
        # 4. Zertifikat signieren
        $signArgs = @(
            "x509", "-req",
            "-in", $svcCsrPath,
            "-CA", $signingCrtPath,
            "-CAkey", $signingKeyPath,
            "-CAcreateserial",
            "-out", $svcCrtPath,
            "-days", $Params.ValidityDays.ToString(),
            "-extfile", $cnfPath,
            "-extensions", "v3_req"
        )

        # Nimmt CaPassword wenn übergeben, erzwingt sonst pass: (verhindert interaktiven Prompt)
        if (-not [string]::IsNullOrWhiteSpace($CaPassword)) {
            $signArgs += "-passin"
            $signArgs += "pass:$CaPassword"
        } else {
            $signArgs += "-passin"
            $signArgs += "pass:"
        }

        Invoke-OpenSSL -Arguments $signArgs | Out-Null

        # 5. PFX erstellen (optional geschützt)
        if ($Params.Exports.pfx) {
            $pfxPassArg = if (-not [string]::IsNullOrWhiteSpace($PfxPassword)) { "pass:$PfxPassword" } else { "pass:" }
            $pfxArgs = @(
                "pkcs12", "-export",
                "-out", $svcPfxPath,
                "-inkey", $svcKeyPath,
                "-in", $svcCrtPath,
                "-certfile", $signingCrtPath,
                "-passin", "pass:",            # Der Service-Key selbst ist immer unverschlüsselt
                "-passout", $pfxPassArg
            )
            Invoke-OpenSSL -Arguments $pfxArgs | Out-Null
        }

        # 6. PEM-Exporte (Cert Only & Fullchain)
        if ($Params.Exports.pem_cert) {
            Copy-Item -Path $svcCrtPath -Destination $certPemOnly -Force
        }

        if ($Params.Exports.pem_full) {
            $crtContent = Get-Content -Path $svcCrtPath -Raw
            $signingCrtContent = Get-Content -Path $signingCrtPath -Raw
            Set-Content -Path $certPemFull -Value "$crtContent`n$signingCrtContent" -Encoding UTF8
        }

    } finally {
        if (Test-Path $cnfPath) { Remove-Item $cnfPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $svcCsrPath) { Remove-Item $svcCsrPath -Force -ErrorAction SilentlyContinue }
    }
}

function Show-PasswordDialog {
    param(
        [string]$Title = "Passwort eingeben",
        [string]$Prompt = "Bitte gib das Passwort ein:"
    )

    $dialog = New-Object System.Windows.Window
    $dialog.Title = $Title
    $dialog.Width = 400
    $dialog.Height = 180
    $dialog.WindowStartupLocation = "CenterOwner"
    $dialog.Owner = $window
    $dialog.ResizeMode = "NoResize"
    $dialog.ShowInTaskbar = $false

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = New-Object System.Windows.Thickness(15)
    $dialog.Content = $grid

    $row1 = New-Object System.Windows.Controls.RowDefinition
    $row1.Height = [System.Windows.GridLength]::Auto
    $row2 = New-Object System.Windows.Controls.RowDefinition
    $row2.Height = [System.Windows.GridLength]::Auto
    $row3 = New-Object System.Windows.Controls.RowDefinition
    $row3.Height = [System.Windows.GridLength]::Auto

    $grid.RowDefinitions.Add($row1)
    $grid.RowDefinitions.Add($row2)
    $grid.RowDefinitions.Add($row3)

    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = $Prompt
    $lbl.TextWrapping = "Wrap"
    $lbl.Margin = New-Object System.Windows.Thickness(0, 0, 0, 10)
    [System.Windows.Controls.Grid]::SetRow($lbl, 0)
    $grid.Children.Add($lbl) | Out-Null

    $txtPass = New-Object System.Windows.Controls.PasswordBox
    $txtPass.Margin = New-Object System.Windows.Thickness(0, 0, 0, 15)
    [System.Windows.Controls.Grid]::SetRow($txtPass, 1)
    $grid.Children.Add($txtPass) | Out-Null

    $btnStack = New-Object System.Windows.Controls.StackPanel
    $btnStack.Orientation = "Horizontal"
    $btnStack.HorizontalAlignment = "Right"
    [System.Windows.Controls.Grid]::SetRow($btnStack, 2)

    $btnOk = New-Object System.Windows.Controls.Button
    $btnOk.Content = "OK"
    $btnOk.Width = 75
    $btnOk.IsDefault = $true
    $btnOk.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
    $btnOk.Add_Click({
        $dialog.DialogResult = $true
        $dialog.Close()
    })

    $btnCancel = New-Object System.Windows.Controls.Button
    $btnCancel.Content = "Abbrechen"
    $btnCancel.Width = 75
    $btnCancel.IsCancel = $true

    $btnStack.Children.Add($btnOk) | Out-Null
    $btnStack.Children.Add($btnCancel) | Out-Null
    $grid.Children.Add($btnStack) | Out-Null

    $txtPass.Focus() | Out-Null

    $result = $dialog.ShowDialog()
    if ($result -eq $true) {
        return $txtPass.Password
    }
    return $null
}

# --- 6. CONFIGURATION LOAD ---
$rawConfigText = Get-OrCreateConfig -FilePath $configPath -DefaultContent $defaultConfigText

try {
    $global:Config = ConvertFrom-Yaml -Yaml $rawConfigText
} catch {
    Write-Warning "Fehler beim Parsen der config.yaml, verwende Fallback: $_"
    $global:Config = ConvertFrom-Yaml -Yaml $defaultConfigText
}

if ($global:Config -and $global:Config.paths) {
    # 1. CA-Ordner erstellen (für Root & Intermediate Schlüssel/Zertifikate)
    $caAbs = Get-AbsolutePath $global:Config.paths.ca_directory
    if ($caAbs -and -not (Test-Path $caAbs)) {
        New-Item -ItemType Directory -Path $caAbs -Force | Out-Null
    }
    # 2. Zertifikats-Ordner erstellen (für die Service-Zertifikate)
    $certAbs = Get-AbsolutePath $global:Config.paths.certs_directory
    if ($certAbs -and -not (Test-Path $certAbs)) {
        New-Item -ItemType Directory -Path $certAbs -Force | Out-Null
    }
}

# --- 7. OPENSSL CHECK (BEFORE GUI INIT) ---
$openSslResult = Find-OpenSSL -ConfigPath $global:Config.paths.openssl_exe -MinVersion "1.1.1"

if ($openSslResult -and $openSslResult.Success) {
    $global:Config.paths.openssl_exe = $openSslResult.Path
} else {
    [System.Windows.MessageBox]::Show(
        "OpenSSL konnte nicht gefunden oder nicht gestartet werden.",
        "OpenSSL Fehler", "OK", "Error"
    ) | Out-Null
    exit
}

# --- 8. XAML GUI LOAD & ELEMENT MAPPING ---
$xamlText = [System.IO.File]::ReadAllText($xamlPath, [System.Text.Encoding]::UTF8)
$reader   = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xamlText))
$window   = [System.Windows.Markup.XamlReader]::Load($reader)

# Controls Mappen
$MainTabControl             = $window.FindName("MainTabControl")
$TabDashboard               = $window.FindName("TabDashboard")
$TabCreateRootCA            = $window.FindName("TabCreateRootCA")
$TabCreateIntermediate      = $window.FindName("TabCreateIntermediate")
$TabNewService              = $window.FindName("TabNewService")
$TabConfig                  = $window.FindName("TabConfig")

$PanelCaDetails             = $window.FindName("PanelCaDetails")
$TxtCaMissing               = $window.FindName("TxtCaMissing")

$TxtRootCaInfo              = $window.FindName("TxtRootCaInfo")
$TxtRootCaExpiry            = $window.FindName("TxtRootCaExpiry")
$TxtInterCaInfo             = $window.FindName("TxtInterCaInfo")
$TxtInterCaExpiry           = $window.FindName("TxtInterCaExpiry")
$TxtSignModeInfo            = $window.FindName("TxtSignModeInfo")

$BtnShowCreateRootCA        = $window.FindName("BtnShowCreateRootCA")
$BtnShowCreateIntermediate  = $window.FindName("BtnShowCreateIntermediate")
$PanelNoRootForInterWarning = $window.FindName("PanelNoRootForInterWarning")
$BtnRenewRootCA             = $window.FindName("BtnRenewRootCA")
$BtnRenewIntermediate       = $window.FindName("BtnRenewIntermediate")

$BtnRenewSelected           = $window.FindName("BtnRenewSelected")
$BtnRenewDue                = $window.FindName("BtnRenewDue")
$GridServices               = $window.FindName("GridServices")
$BtnNewService              = $window.FindName("BtnNewService")
$PanelNoCaWarning           = $window.FindName("PanelNoCaWarning")

# Form Controls - Root CA
$TxtRootCn                  = $window.FindName("TxtRootCn")
$TxtRootOrg                 = $window.FindName("TxtRootOrg")
$TxtRootOu                  = $window.FindName("TxtRootOu")
$TxtRootCountry             = $window.FindName("TxtRootCountry")
$TxtRootState               = $window.FindName("TxtRootState")
$TxtRootLocality            = $window.FindName("TxtRootLocality")
$TxtRootDays                = $window.FindName("TxtRootDays")
$CmbRootAlgorithm           = $window.FindName("CmbRootAlgorithm")
$CmbRootKeyLength           = $window.FindName("CmbRootKeyLength")
$TxtRootBaseFilename        = $window.FindName("TxtRootBaseFilename")
$PwdRootPass                = $window.FindName("PwdRootPass")
$PwdRootPassConfirm         = $window.FindName("PwdRootPassConfirm")
$BtnCancelRootCA            = $window.FindName("BtnCancelRootCA")
$BtnSaveRootCA              = $window.FindName("BtnSaveRootCA")

# Form Controls - Intermediate CA
$TxtInterCn                 = $window.FindName("TxtInterCn")
$TxtInterOrg                = $window.FindName("TxtInterOrg")
$TxtInterDays               = $window.FindName("TxtInterDays")
$TxtInterPathLen            = $window.FindName("TxtInterPathLen")
$CmbInterAlgorithm          = $window.FindName("CmbInterAlgorithm")
$CmbInterKeyLength          = $window.FindName("CmbInterKeyLength")
$TxtInterBaseFilename       = $window.FindName("TxtInterBaseFilename")
$PwdInterPass               = $window.FindName("PwdInterPass")
$PwdInterPassConfirm        = $window.FindName("PwdInterPassConfirm")
$BtnCancelIntermediate      = $window.FindName("BtnCancelIntermediate")
$BtnSaveIntermediate        = $window.FindName("BtnSaveIntermediate")

# Form Controls - Service Certificate
$TxtServiceDisplayName      = $window.FindName("TxtServiceDisplayName")
$TxtServiceCn               = $window.FindName("TxtServiceCn")
$TxtServiceOrg              = $window.FindName("TxtServiceOrg")
$TxtServiceOu               = $window.FindName("TxtServiceOu")
$TxtServiceCountry          = $window.FindName("TxtServiceCountry")
$TxtServiceLocality         = $window.FindName("TxtServiceLocality")
$TxtServiceDnsSANs          = $window.FindName("TxtServiceDnsSANs")
$TxtServiceIpSANs           = $window.FindName("TxtServiceIpSANs")
$CmbServiceEku              = $window.FindName("CmbServiceEku")
$CmbServiceAlgorithm        = $window.FindName("CmbServiceAlgorithm")
$CmbServiceKeyLength        = $window.FindName("CmbServiceKeyLength")
$ChkKuDigitalSignature      = $window.FindName("ChkKuDigitalSignature")
$ChkKuKeyEncipherment       = $window.FindName("ChkKuKeyEncipherment")
$ChkKuDataEncipherment      = $window.FindName("ChkKuDataEncipherment")
$ChkKuKeyAgreement          = $window.FindName("ChkKuKeyAgreement")
$TxtServiceDays             = $window.FindName("TxtServiceDays")
$ChkExportPfx               = $window.FindName("ChkExportPfx")
$ChkExportCrt               = $window.FindName("ChkExportCrt")
$ChkExportKey               = $window.FindName("ChkExportKey")
$ChkExportPemOnly           = $window.FindName("ChkExportPemOnly")
$ChkExportPemFull           = $window.FindName("ChkExportPemFull")
$BtnCancelNewService        = $window.FindName("BtnCancelNewService")
$BtnSaveNewService          = $window.FindName("BtnSaveNewService")

# Config Editor Controls
$TxtConfigEditor            = $window.FindName("TxtConfigEditor")
$TxtConfigNotice            = $window.FindName("TxtConfigNotice")
$BtnOpenConfig              = $window.FindName("BtnOpenConfig")
$BtnBackFromConfig          = $window.FindName("BtnBackFromConfig")
$BtnImportConfig            = $window.FindName("BtnImportConfig")
$BtnExportConfig            = $window.FindName("BtnExportConfig")

$TxtStatus                  = $window.FindName("TxtStatus")

# --- 9. INITIALISIERUNG ---
LoadConfigToForm

if (-not $openSslResult -or -not $openSslResult.Success) {
    if ($TxtStatus) { $TxtStatus.Text = "🚨 OpenSSL fehlt oder ist veraltet. Zertifikatserstellung nicht möglich." }
    if ($BtnNewService) { $BtnNewService.IsEnabled = $false }
    if ($BtnShowCreateRootCA) { $BtnShowCreateRootCA.IsEnabled = $false }
} else {
    $global:Config.paths.openssl_exe = $openSslResult.Path
    Save-ConfigToFile
    if ($TxtStatus) {
        $TxtStatus.Text = "✅ OpenSSL $($openSslResult.Version) gefunden: $($openSslResult.Path)" 
    }
}

Update-DashboardStatus

# --- 10. EVENT HANDLER ---
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
            LoadConfigToForm
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
    try {
        $passwd = Get-CaPassword -PromptText "Root-CA Passwort zur Erneuerung erforderlich:"
        if ([string]::IsNullOrWhiteSpace($passwd)) { return }

        $params = @{
            CommonName   = $global:Config.defaults.root_ca.common_name
            Organization = $global:Config.defaults.organization
            OU           = $global:Config.defaults.root_ca.ou
            Country      = $global:Config.defaults.country
            State        = $global:Config.defaults.state
            Locality     = $global:Config.defaults.locality
            ValidityDays = ([int]$global:Config.defaults.root_ca.validity_days)
            KeyLength    = [int]$global:Config.defaults.root_ca.key_length
            BaseFilename = $global:Config.defaults.root_ca.base_filename
        }

        Renew-RootCA -Password $passwd -Params $params
        Update-DashboardStatus
        $TxtStatus.Text = "Root-CA erfolgreich verlängert."
    } catch {
        [System.Windows.MessageBox]::Show("Fehler beim Verlängern der Root-CA: $_", "Fehler", "OK", "Error")
    }
})

$BtnRenewIntermediate.Add_Click({
    try {
        $rootPasswd = Get-CaPassword -PromptText "Root-CA Passwort zur Signierung erforderlich:"
        if ([string]::IsNullOrWhiteSpace($rootPasswd)) { return }

    # Falls laut Config ein Passwort existiert, fragen wir danach, sonst entfällt die Abfrage
    if ($global:Config.defaults.intermediate_ca.has_password) {
        $interPasswd = Get-CaPassword -PromptText "Intermediate-CA Key-Passwort (falls vergeben, sonst Enter):"
    } else {
        $interPasswd = $null # bzw. ConvertTo-SecureString "" -AsPlainText -Force (je nachdem, was Get-CaPassword zurückgibt)
    }

        $params = @{
            CommonName   = $global:Config.defaults.intermediate_ca.common_name
            Organization = $global:Config.defaults.organization
            OU           = $global:Config.defaults.intermediate_ca.ou
            Country      = $global:Config.defaults.country
            State        = $global:Config.defaults.state
            Locality     = $global:Config.defaults.locality
            ValidityDays = ([int]$global:Config.defaults.intermediate_ca.validity_days)
            KeyLength    = [int]$global:Config.defaults.intermediate_ca.key_length
            PathLen      = [int]$global:Config.defaults.intermediate_ca.pathlen
            BaseFilename = $global:Config.defaults.intermediate_ca.base_filename
        }

        Renew-IntermediateCA -RootPassword $rootPasswd -IntermediatePassword $interPasswd -Params $params
        Update-DashboardStatus
        $TxtStatus.Text = "Intermediate-CA erfolgreich verlängert."
    } catch {
        [System.Windows.MessageBox]::Show("Fehler beim Verlängern der Intermediate-CA: $_", "Fehler", "OK", "Error")
    }
})

# Root CA Erstellen Handler
$BtnSaveRootCA.Add_Click({
    try {
        # Validierung der Passwortfelder
        $pass1 = $PwdRootPass.Password
        $pass2 = $PwdRootPassConfirm.Password

        if ([string]::IsNullOrWhiteSpace($pass1)) {
            [System.Windows.MessageBox]::Show("Bitte gib ein Passwort für die Root-CA ein.", "Validierungsfehler", "OK", "Warning")
            return
        }

        if ($pass1 -ne $pass2) {
            [System.Windows.MessageBox]::Show("Die eingegebenen Root-CA Passwörter stimmen nicht überein!", "Validierungsfehler", "OK", "Error")
            return
        }

        # Parameter aus den Formularfeldern der GUI auslesen
        $params = @{
            CommonName   = $TxtRootCn.Text
            Organization = $TxtRootOrg.Text
            OU           = $TxtRootOu.Text
            Country      = $TxtRootCountry.Text
            State        = $TxtRootState.Text
            Locality     = $TxtRootLocality.Text
            ValidityDays = [int]$TxtRootDays.Text
            KeyAlgorithm = if ($CmbRootAlgorithm -and $CmbRootAlgorithm.Text) { $CmbRootAlgorithm.Text } else { "RSA" }
            KeyLength    = if ($CmbRootKeyLength -and $CmbRootKeyLength.Text) { $CmbRootKeyLength.Text } else { "4096" }
            BaseFilename = $TxtRootBaseFilename.Text.Trim()
        }

        # OpenSSL-Funktion aufrufen
        New-RootCA -Password $pass1 -Params $params

        # Config aktualisieren
        $global:Config.defaults.root_ca.base_filename = $params.BaseFilename
        $global:Config.defaults.root_ca.common_name   = $params.CommonName
        $global:Config.defaults.organization          = $params.Organization
        $global:Config.defaults.country               = $params.Country
        $global:Config.defaults.state                 = $params.State
        $global:Config.defaults.locality              = $params.Locality
        
        # Konfigurationsdatei speichern
        Save-ConfigToFile
        # Oberfläche aktualisieren
        Update-DashboardStatus

        # Zurück zum Dashboard
        $MainTabControl.SelectedItem = $TabDashboard
        [System.Windows.MessageBox]::Show("Root-CA wurde erfolgreich mit OpenSSL erstellt!", "Erfolg", "OK", "Information")
    } catch {
        [System.Windows.MessageBox]::Show("Fehler beim Erstellen der Root-CA:`n$($_.Exception.Message)", "Fehler", "OK", "Error")
    }
})

# Intermediate CA Erstellen Handler
$BtnSaveIntermediate.Add_Click({
    try {
        # Root-Passwort zur Signierung per Dialog abfragen
        $rootPass = Show-PasswordDialog -Title "Root-CA Passwort erforderlich" -Prompt "Gib das Passwort der Root-CA ein, um die Intermediate-CA zu signieren:"
        if ([string]::IsNullOrWhiteSpace($rootPass)) { return }

        # Optionales Passwort der Intermediate CA direkt aus der GUI lesen
        $interPass1 = $PwdInterPass.Password
        $interPass2 = $PwdInterPassConfirm.Password

        if ($interPass1 -ne $interPass2) {
            [System.Windows.MessageBox]::Show("Die eingegebenen Intermediate-CA Passwörter stimmen nicht überein!", "Validierungsfehler", "OK", "Error")
            return
        }

        # Parameter aus den Formularfeldern der GUI auslesen
        $params = @{
            CommonName   = $TxtInterCn.Text
            Organization = $TxtInterOrg.Text
            OU           = if ($TxtInterOu) { $TxtInterOu.Text } else { $global:Config.defaults.organization }
            Country      = $global:Config.defaults.country
            State        = $global:Config.defaults.state
            Locality     = $global:Config.defaults.locality
            ValidityDays = [int]$TxtInterDays.Text
            KeyAlgorithm = if ($CmbInterAlgorithm -and $CmbInterAlgorithm.Text) { $CmbInterAlgorithm.Text } else { "RSA" }
            KeyLength    = if ($CmbInterKeyLength -and $CmbInterKeyLength.Text) { $CmbInterKeyLength.Text } else { "2048" }
            PathLen      = if ($TxtInterPathLen.Text) { [int]$TxtInterPathLen.Text } else { 0 }
            BaseFilename = $TxtInterBaseFilename.Text.Trim()
        }
        # OpenSSL-Funktion aufrufen
        New-IntermediateCA -RootPassword $rootPass -IntermediatePassword $interPass1 -Params $params

        $global:Config.defaults.intermediate_ca.base_filename = $params.BaseFilename
        $global:Config.defaults.intermediate_ca.common_name   = $params.CommonName
        $global:Config.defaults.intermediate_ca.has_password  = (-not [string]::IsNullOrWhiteSpace($interPass1))
        
        Save-ConfigToFile
        Update-DashboardStatus

        # Zurück zum Dashboard
        $MainTabControl.SelectedItem = $TabDashboard
        [System.Windows.MessageBox]::Show("Intermediate-CA wurde erfolgreich erstellt und von der Root-CA signiert!", "Erfolg", "OK", "Information")
    } catch {
        [System.Windows.MessageBox]::Show("Fehler beim Erstellen der Intermediate-CA:`n$($_.Exception.Message)", "Fehler", "OK", "Error")
    }
})

# Service Zertifikat Erstellen Handler
$BtnSaveNewService.Add_Click({
    try {
        $pkiState = Get-SystemPkiState
        $useInter = ($null -ne $pkiState.IntermediateCA)
        $caPass   = $null

        if ($useInter -and $pkiState.IntermediateHasPass) {
            $caPass = Show-PasswordDialog -Title "Intermediate-CA Passwort" -Prompt "Gib das Passwort der Intermediate-CA ein:"
            if ([string]::IsNullOrWhiteSpace($caPass)) { return }
        } elseif (-not $useInter) {
            $caPass = Show-PasswordDialog -Title "Root-CA Passwort" -Prompt "Gib das Passwort der Root-CA ein:"
            if ([string]::IsNullOrWhiteSpace($caPass)) { return }
        }

        $dnsInput = if ($TxtServiceDnsSANs) { $TxtServiceDnsSANs.Text } else { "" }
        $dnsList  = $dnsInput.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

        $ipInput  = if ($TxtServiceIpSANs)  { $TxtServiceIpSANs.Text }  else { "" }
        $ipList   = $ipInput.Split(',')  | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

        $selectedKeyUsages = @()
        if ($ChkKuDigitalSignature -and $ChkKuDigitalSignature.IsChecked) { $selectedKeyUsages += "digitalSignature" }
        if ($ChkKuKeyEncipherment  -and $ChkKuKeyEncipherment.IsChecked)  { $selectedKeyUsages += "keyEncipherment" }
        if ($ChkKuDataEncipherment -and $ChkKuDataEncipherment.IsChecked) { $selectedKeyUsages += "dataEncipherment" }
        if ($ChkKuKeyAgreement    -and $ChkKuKeyAgreement.IsChecked)    { $selectedKeyUsages += "keyAgreement" }

        $keyAlgo = if ($CmbServiceAlgorithm -and $CmbServiceAlgorithm.Text) { $CmbServiceAlgorithm.Text } else { "RSA" }
        $keyLen  = if ($CmbServiceKeyLength -and $CmbServiceKeyLength.Text) { $CmbServiceKeyLength.Text } else { "2048" }
        $ekuVal  = if ($CmbServiceEku -and $CmbServiceEku.Text) { $CmbServiceEku.Text } else { "TLS Web Server Authentication (serverAuth)" }

        $params = @{
            DisplayName  = $TxtServiceDisplayName.Text
            CommonName   = $TxtServiceCn.Text
            Organization = $TxtServiceOrg.Text
            OU           = $TxtServiceOu.Text
            Country      = $TxtServiceCountry.Text
            Locality     = $TxtServiceLocality.Text
            SANsDNS      = $dnsList
            SANsIP       = $ipList
            EKU          = $ekuVal
            KeyUsages    = $selectedKeyUsages
            KeyAlgorithm = $keyAlgo
            KeyLength    = $keyLen
            ValidityDays = [int]$TxtServiceDays.Text
            Exports      = @{
                pfx      = [bool]$ChkExportPfx.IsChecked
                crt      = [bool]$ChkExportCrt.IsChecked
                key      = [bool]$ChkExportKey.IsChecked
                pem_cert = [bool]$ChkExportPemOnly.IsChecked
                pem_full = [bool]$ChkExportPemFull.IsChecked
            }
        }
        # Splatting-Hashtable für den Funktionsaufruf vorbereiten
        $splat = @{
            Params = $params
        }

        # Passwort nur übergeben, wenn laut Config eines existiert und gesetzt ist
        if ($global:Config.defaults.intermediate_ca.has_password -and $caPass) {
            $splat['CaPassword'] = $caPass
        }

        # OpenSSL-Funktion mit Splatting aufrufen
        New-ServiceCertificate @splat

        # In Soll-Zustand (service_certificates) eintragen, falls nicht vorhanden
        $exists = $global:Config.service_certificates | Where-Object { $_.common_name -eq $params.CommonName }
        if (-not $exists) {
            $newEntry = @{
                display_name = $params.DisplayName
                common_name  = $params.CommonName
                eku          = $params.EKU
                sans_dns     = $params.SANsDNS
                sans_ip      = $params.SANsIP
            }
            if ($null -eq $global:Config.service_certificates) {
                $global:Config.service_certificates = @()
            }
            $global:Config.service_certificates += $newEntry

        }

        Save-ConfigToFile
        Update-DashboardStatus

        $MainTabControl.SelectedItem = $TabDashboard
        [System.Windows.MessageBox]::Show("Service-Zertifikat '$($params.CommonName)' wurde erfolgreich erstellt!", "Erfolg", "OK", "Information")
    } catch {
        [System.Windows.MessageBox]::Show("Fehler beim Erstellen des Zertifikats:`n$($_.Exception.Message)", "Fehler", "OK", "Error")
    }
})

# Reparatur aller fehlerhaften/fehlenden/abgelaufenen Zertifikate
$BtnRenewDue.Add_Click({
    try {
        $pkiState = Get-SystemPkiState
        
        # Filtert auf Fehlt, Defekt, Abgelaufen oder Warnung
        $toRepair = $pkiState.Services | Where-Object { 
            $_.Status -in @("Fehlt", "Defekt", "Abgelaufen", "Warnung", "Kritisch") 
        }

        if (-not $toRepair -or $toRepair.Count -eq 0) {
            [System.Windows.MessageBox]::Show("Alle Zertifikate sind gültig. Keine Reparatur erforderlich.", "Info", "OK", "Information")
            return
        }

        # Passwort-Abfrage bei Bedarf
        $caPass = $null
        $useInter = ($null -ne $pkiState.IntermediateCA)
        if ($useInter -and $pkiState.IntermediateHasPass) {
            $caPass = Show-PasswordDialog -Title "Intermediate-CA Passwort" -Prompt "Gib das Passwort der Intermediate-CA ein:"
            if ([string]::IsNullOrWhiteSpace($caPass)) { return }
        } elseif (-not $useInter) {
            $caPass = Show-PasswordDialog -Title "Root-CA Passwort" -Prompt "Gib das Passwort der Root-CA ein:"
            if ([string]::IsNullOrWhiteSpace($caPass)) { return }
        }

        # Ausführen der Re-Issue Engine
        Repair-ServiceCertificates -CertificatesToRepair $toRepair -CaPassword $caPass

        Update-DashboardStatus
        $TxtStatus.Text = "Reparatur abgeschlossen: $($toRepair.Count) Zertifikat(e) neu ausgestellt."
        [System.Windows.MessageBox]::Show("$($toRepair.Count) Zertifikat(e) wurden erfolgreich repariert / neu ausgestellt!", "Erfolg", "OK", "Information")

    } catch {
        [System.Windows.MessageBox]::Show("Fehler bei der Reparatur:`n$($_.Exception.Message)", "Fehler", "OK", "Error")
    }
})

# --- 11. ANZEIGE DER BENUTZEROBERFLÄCHE ---
$window.ShowDialog() | Out-Null