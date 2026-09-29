# ==========================================
# 1. SETUP & PFADE
# ==========================================
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

if (-not (Get-Module -ListAvailable -Name "powershell-yaml")) {
    Write-Host "Installiere 'powershell-yaml' Modul..." -ForegroundColor Yellow
    Install-Module -Name "powershell-yaml" -Scope CurrentUser -Force -AllowClobber
}
Import-Module "powershell-yaml"

$ScriptDir =$PSScriptRoot
if (-not $ScriptDir) {$ScriptDir = Get-Location }

$ConfigPath = Join-Path $ScriptDir "config.yaml"
$XamlPath   = Join-Path $ScriptDir "gui.xaml"

# ==========================================
# 2. XAML DATEI LADEN
# ==========================================
if (-not (Test-Path $XamlPath)) {
    [System.Windows.MessageBox]::Show("Fehler: MainWindow.xaml wurde nicht im Skriptordner gefunden!", "Fehler", "OK", "Error")
    exit
}

$xamlString   = [System.IO.File]::ReadAllText($XamlPath, [System.Text.Encoding]::UTF8)
$stringReader = New-Object System.IO.StringReader($xamlString)
$xmlReader    = [System.Xml.XmlReader]::Create($stringReader)
$window       = [Windows.Markup.XamlReader]::Load($xmlReader)

# UI-Elemente
$TxtRootCN       =$window.FindName("TxtRootCN")
$TxtRootOrg      =$window.FindName("TxtRootOrg")
$TxtRootYears    =$window.FindName("TxtRootYears")
$TxtServiceName  =$window.FindName("TxtServiceName")
$TxtServiceCN    =$window.FindName("TxtServiceCN")
$TxtSAN_DNS      =$window.FindName("TxtSAN_DNS")
$TxtSAN_IP       =$window.FindName("TxtSAN_IP")
$TxtYamlContent  =$window.FindName("TxtYamlContent")

$BtnSaveYaml     =$window.FindName("BtnSaveYaml")
$BtnCreateRootCA =$window.FindName("BtnCreateRootCA")
$BtnExportRootCA =$window.FindName("BtnExportRootCA")
$BtnIssueCert    =$window.FindName("BtnIssueCert")
$TxtStatus       =$window.FindName("TxtStatus")

# ==========================================
# 3. HELPER & PKI FUNKTIONEN
# ==========================================

function Get-AppConfig {
    if (Test-Path $ConfigPath) {
        $rawYaml = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)
        return ConvertFrom-Yaml -Yaml $rawYaml
    }
    return $null
}

# ------------------------------------------
# A. ROOT-CA ERSTELLEN
# ------------------------------------------
function New-RootCA {
    param(
        [SecureString]$Password
    )
    $config = Get-AppConfig
    if (-not $config) { throw "config.yaml nicht gefunden!" }

    $dataDir = Join-Path $ScriptDir $config.Settings.BaseDirectory
    if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }

    $subject = "CN=$($config.RootCA.CommonName), O=$($config.RootCA.Organization), C=$($config.RootCA.Country)"
    $validityDays = [int]$config.RootCA.ValidityDays

    $pfxPath = Join-Path $dataDir $config.RootCA.PrivateKeyFileName
    $crtPath = Join-Path $dataDir $config.RootCA.CertificateFileName

    # Root-CA in lokalem Speicher 'Cert:\CurrentUser\My' erstellen
    $rootCert = New-SelfSignedCertificate `
        -Subject $subject `
        -KeyLength $config.RootCA.KeyLength `
        -KeyAlgorithm $config.RootCA.KeyAlgorithm `
        -HashAlgorithm $config.RootCA.HashAlgorithm `
        -NotBefore (Get-Date) `
        -NotAfter (Get-Date).AddDays($validityDays) `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -KeyUsage CertSign, CRLSign, DigitalSignature

    # Plaintext-Passwort aus Credential auslesen
    $plainPassword = (New-Object System.Net.NetworkCredential("", $Password)).Password

    # PFX Exportieren (3 entspricht X509ContentType.Pfx)
    $pfxBytes = $rootCert.Export("Pfx", $plainPassword)
    [System.IO.File]::WriteAllBytes($pfxPath, $pfxBytes)

    # Public CRT Exportieren (1 entspricht X509ContentType.Cert)
    $crtBytes = $rootCert.Export("Cert")
    [System.IO.File]::WriteAllBytes($crtPath, $crtBytes)

    return $crtPath
}

# ------------------------------------------
# B. DIENST-ZERTIFIKAT AUSSTELLEN
# ------------------------------------------
function New-ServiceCertificate {
    param(
        [string]$ServiceName,
        [string]$CommonName,
        [string[]]$DnsNames,
        [string[]]$IpAddresses,
        [SecureString]$CaPassword
    )
    $config = Get-AppConfig
    if (-not $config) { throw "config.yaml nicht gefunden!" }

    $dataDir   = Join-Path $ScriptDir $config.Settings.BaseDirectory
    $exportDir = Join-Path $ScriptDir $config.Settings.ExportDirectory
    $pfxCaPath = Join-Path $dataDir $config.RootCA.PrivateKeyFileName

    if (-not (Test-Path $pfxCaPath)) {
        throw "Root-CA PFX-Datei nicht gefunden! Bitte zuerst Root-CA erstellen."
    }

    # Plaintext-Passwort aus Credential auslesen
    $plainPassword = (New-Object System.Net.NetworkCredential("", $Password)).Password

    # Root-CA aus PFX laden (60 = PersistKeySet + Exportable)
    $caCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
    $caCert.Import($pfxCaPath,$plainCaPassword, "Exportable")

    # SAN Extension aufbauen
    $sanList = @()
    foreach ($dns in $DnsNames) { if ($dns.Trim()) {$sanList += "dns=$($dns.Trim())" } }
    foreach ($ip in $IpAddresses) { if ($ip.Trim()) {$sanList += "ip=$($ip.Trim())" } }

    $validityDays = [int]$config.CertificateDefaults.ValidityDays

    # Neues Zertifikat signiert durch Root-CA erstellen
    $serviceCert = New-SelfSignedCertificate `
        -Subject "CN=$CommonName" `
        -Signer $caCert `
        -KeyLength $config.CertificateDefaults.KeyLength `
        -KeyAlgorithm $config.CertificateDefaults.KeyAlgorithm `
        -HashAlgorithm $config.CertificateDefaults.HashAlgorithm `
        -NotBefore (Get-Date) `
        -NotAfter (Get-Date).AddDays($validityDays) `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -DnsName ($DnsNames + $CommonName | Select-Object -Unique) `
        -TextExtension @(
            "2.5.29.37={text}1.3.6.1.5.5.7.3.1,1.3.6.1.5.5.7.3.2" # Server- & Client-Auth
        )

    # Ziel-Ordner im Export vorbereiten
    $targetDir = Join-Path $exportDir $ServiceName
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path$targetDir -Force | Out-Null }


    # EXPORT 1: PFX (Zertifikat + Key in einer Datei)
    $pfxBytes = $serviceCert.Export("Pfx", $plainCaPassword)
    [System.IO.File]::WriteAllBytes((Join-Path $targetDir "$ServiceName.pfx"), $pfxBytes)

    # EXPORT 2: CRT / PEM (NUR Öffentliches Zertifikat)
    $crtBytes =$serviceCert.Export("Cert")
    $certBase64 = [System.Convert]::ToBase64String($crtBytes, "InsertLineBreaks")
    $pemCertContent = "-----BEGIN CERTIFICATE-----`n$certBase64`n-----END CERTIFICATE-----"
    [System.IO.File]::WriteAllText((Join-Path $targetDir "$ServiceName.crt"), $pemCertContent)

    # EXPORT 3: KEY / PEM (NUR Privater Schlüssel)
    # Wir laden den Key direkt aus dem eben erzeugten Zertifikat im Zertifikatsspeicher
    $rsaKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($serviceCert)

    if ($rsaKey) {
        # Exportiert den Schlüssel unverschlüsselt im PKCS#8 Format (Standard für Nginx, Apache, Proxmox, Synology)
        $keyBytes =$rsaKey.ExportPkcs8PrivateKey()
        $keyBase64 = [System.Convert]::ToBase64String($keyBytes, "InsertLineBreaks")
        $pemKeyContent = "-----BEGIN PRIVATE KEY-----`n$keyBase64`n-----END PRIVATE KEY-----"
        
        [System.IO.File]::WriteAllText((Join-Path $targetDir "$ServiceName.key"), $pemKeyContent)
    } else {
        throw "Der private Schlüssel für '$ServiceName' konnte nicht ausgelesen werden."
    }

    # AUFRÄUMEN (Zertifikat aus 'Cert:\CurrentUser\My' löschen)
    Remove-Item -Path "Cert:\CurrentUser\My\$($serviceCert.Thumbprint)" -ErrorAction SilentlyContinue

    return $targetDir
}

# ==========================================
# 4. EVENT HANDLER (GUI REAKTIONEN)
# ==========================================

function Load-ConfigToUI {
    if (Test-Path $ConfigPath) {
        $rawYaml = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)
        $TxtYamlContent.Text =$rawYaml
        $config = ConvertFrom-Yaml -Yaml $rawYaml
        if ($config.RootCA) {
            $TxtRootCN.Text    =$config.RootCA.CommonName
            $TxtRootOrg.Text   =$config.RootCA.Organization
            $TxtRootYears.Text =$config.RootCA.ValidityDays
        }
        $TxtStatus.Text = "Konfiguration geladen."
    }
}

# Event: Root-CA Erstellen Button
$BtnCreateRootCA.Add_Click({
    try {
        # Passwort-Abfrage über Windows PowerShell Dialog
        $cred = Get-Credential -UserName "RootCA_Owner" -Message "Bitte ein sicheres Master-Passwort für den privaten Schlüssel der Root-CA eingeben:"
        if (-not $cred) { return }

        $crtPath = New-RootCA -Password $cred.Password
        $TxtStatus.Text = "Root-CA erfolgreich erstellt!"
        [System.Windows.MessageBox]::Show("Root-CA wurde erfolgreich erstellt!`n`nZertifikat: $crtPath", "Erfolg", "OK", "Information")
    } catch {
        [System.Windows.MessageBox]::Show("Fehler bei Root-CA Erstellung:`n$_", "Fehler", "OK", "Error")
    }
})

# Event: Dienst-Zertifikat Ausstellen Button
$BtnIssueCert.Add_Click({
    try {
        if (-not $TxtServiceName.Text -or -not $TxtServiceCN.Text) {
            [System.Windows.MessageBox]::Show("Bitte mindestens Dienstname und Common Name angeben.", "Achtung", "OK", "Warning")
            return
        }

        $cred = Get-Credential -UserName "RootCA_Owner" -Message "Bitte das Master-Passwort der Root-CA eingeben, um das Zertifikat zu signieren:"
        if (-not $cred) { return }

        $dnsArray = $TxtSAN_DNS.Text -split "," | ForEach-Object { $_.Trim() }
        $ipArray  = $TxtSAN_IP.Text -split "," | ForEach-Object { $_.Trim() }

        $outDir = New-ServiceCertificate `
            -ServiceName $TxtServiceName.Text `
            -CommonName $TxtServiceCN.Text `
            -DnsNames $dnsArray `
            -IpAddresses $ipArray `
            -CaPassword $cred.Password

        $TxtStatus.Text = "Zertifikat für '$($TxtServiceName.Text)' generiert!"
        [System.Windows.MessageBox]::Show("Zertifikat erfolgreich ausgestellt!`n`nDateien gespeichert unter:`n$outDir", "Erfolg", "OK", "Information")
    } catch {
        [System.Windows.MessageBox]::Show("Fehler beim Erstellen des Zertifikats:`n$_", "Fehler", "OK", "Error")
    }
})

# Event: Config Speichern Button
$BtnSaveYaml.Add_Click({
    try {
        # UTF-8 ohne BOM schreiben (Powershell-nativer Befehl ohne :: Syntax)
        Set-Content -Path $ConfigPath -Value $TxtYamlContent.Text -Encoding utf8 -Force
        
        $TxtStatus.Text = "config.yaml gespeichert."
        
        # WPF Dialog aufrufen (WPF Assembly muss am Skriptanfang geladen sein)
        [System.Windows.MessageBox]::Show("Konfiguration gespeichert.", "Erfolg", "OK", "Information") | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show("Fehler beim Speichern: $_", "Fehler", "OK", "Error") | Out-Null
    }
})

# Start-Initialisierung
Load-ConfigToUI

# ==========================================
# 5. FENSTER ÖFFNEN
# ==========================================
$window.ShowDialog() | Out-Null