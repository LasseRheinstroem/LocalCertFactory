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
    [System.Windows.MessageBox]::Show("Fehler: gui.xaml wurde nicht im Skriptordner gefunden!", "Fehler", "OK", "Error")
    exit
}

$xamlString   = [System.IO.File]::ReadAllText($XamlPath, [System.Text.Encoding]::UTF8)
$stringReader = New-Object System.IO.StringReader($xamlString)
$xmlReader    = [System.Xml.XmlReader]::Create($stringReader)
$window       = [Windows.Markup.XamlReader]::Load($xmlReader)

# UI-Elemente zuweisen
$TxtRootInfo     =$window.FindName("TxtRootInfo")
$GridServices    =$window.FindName("GridServices")
$TxtServiceName  =$window.FindName("TxtServiceName")
$TxtServiceCN    =$window.FindName("TxtServiceCN")
$TxtSAN_DNS      =$window.FindName("TxtSAN_DNS")
$TxtSAN_IP       =$window.FindName("TxtSAN_IP")
$TxtYamlContent  =$window.FindName("TxtYamlContent")

$BtnCreateRootCA =$window.FindName("BtnCreateRootCA")
$BtnExportRootCA =$window.FindName("BtnExportRootCA")
$BtnRenewSelected=$window.FindName("BtnRenewSelected")
$BtnRenewAll     =$window.FindName("BtnRenewAll")
$BtnIssueCert    =$window.FindName("BtnIssueCert")
$BtnSaveYaml     =$window.FindName("BtnSaveYaml")
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
        [Parameter(Mandatory=$true)]
        [SecureString]$Password
    )
    
    # Schutz vor leeren Password-Objekten
    if (-not $Password -or $Password.Length -eq 0) {
        throw "Es wurde kein Passwort für die Root-CA übergeben!"
    }

    $config = Get-AppConfig
    if (-not $config) { throw "config.yaml nicht gefunden!" }

    $dataDir = Join-Path $ScriptDir $config.Settings.CADirectory
    if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }

    $subject = "CN=$($config.RootCA.CommonName), O=$($config.RootCA.Organization), C=$($config.RootCA.Country)"
    $validityDays = [int]$config.RootCA.ValidityDays

    $pfxPath = Join-Path $dataDir $config.RootCA.PrivateKeyFileName
    $crtPath = Join-Path $dataDir $config.RootCA.CertificateFileName

    # 1. Root-CA in 'Cert:\CurrentUser\My' temporär erzeugen
    $rootCert = New-SelfSignedCertificate `
        -Subject $subject `
        -KeyLength $config.RootCA.KeyLength `
        -KeyAlgorithm $config.RootCA.KeyAlgorithm `
        -HashAlgorithm $config.RootCA.HashAlgorithm `
        -NotBefore (Get-Date) `
        -NotAfter (Get-Date).AddDays($validityDays) `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -KeyUsage CertSign, CRLSign, DigitalSignature

    try {
        # 2. PFX Exportieren (Mit erzwungenem Passwortschutz via SecureString)
        Export-PfxCertificate -Cert $rootCert -FilePath $pfxPath -Password $Password -Force | Out-Null

        # 3. Public CRT Exportieren (.crt als sauberes Base64/PEM Format)
        $crtBytes = $rootCert.Export("Cert")
        $certBase64 = [System.Convert]::ToBase64String($crtBytes, "InsertLineBreaks")
        $pemCertContent = "-----BEGIN CERTIFICATE-----`n$certBase64`n-----END CERTIFICATE-----"
        Set-Content -Path $crtPath -Value $pemCertContent -Encoding utf8 -Force
    }
    finally {
        # 4. Aufräumen: Root-CA IMMER aus 'Cert:\CurrentUser\My' entfernen
        Remove-Item -Path "Cert:\CurrentUser\My\$($rootCert.Thumbprint)" -ErrorAction SilentlyContinue
    }

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

    $dataDir   = Join-Path $ScriptDir $config.Settings.CADirectory
    $exportDir = Join-Path $ScriptDir $config.Settings.ServicesDirectory
    $pfxCaPath = Join-Path $dataDir $config.RootCA.PrivateKeyFileName

    if (-not (Test-Path $pfxCaPath)) {
        throw "Root-CA PFX-Datei nicht gefunden! Bitte zuerst Root-CA erstellen."
    }

    # BSTR-Entschlüsselung für exakte Zeichen (inkl. Sonderzeichen)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($CaPassword)
    try {
        $plainCaPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    # 1. Root-CA vorübergehend in den Windows-Cert-Store laden
    $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable -bor `
             [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet
             
    $caCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($pfxCaPath, $plainCaPassword,$flags)

    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("My", "CurrentUser")
    $store.Open("ReadWrite")
    $store.Add($caCert)
    $store.Close()

    try {
        $validityDays = [int]$config.CertificateDefaults.ValidityDays

        # 2. Dienst-Zertifikat signiert durch Root-CA erstellen
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
                "2.5.29.37={text}1.3.6.1.5.5.7.3.1,1.3.6.1.5.5.7.3.2"
            )

        $targetDir = Join-Path $exportDir $ServiceName
        if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }

        # EXPORT 1: PFX
        $pfxBytes = $serviceCert.Export("Pfx", $plainCaPassword)
        [System.IO.File]::WriteAllBytes((Join-Path $targetDir "$ServiceName.pfx"), $pfxBytes)

        # EXPORT 2: CRT / PEM
        $crtBytes =$serviceCert.Export("Cert")
        $certBase64 = [System.Convert]::ToBase64String($crtBytes, "InsertLineBreaks")
        $pemCertContent = "-----BEGIN CERTIFICATE-----`n$certBase64`n-----END CERTIFICATE-----"
        [System.IO.File]::WriteAllText((Join-Path $targetDir "$ServiceName.crt"), $pemCertContent)

        # EXPORT 3: KEY / PEM (Abwärtskompatibel für PS 5.1 & PS 7)
        $pfxFilePath = Join-Path $targetDir "$ServiceName.pfx"
        
        # KeyStorageFlags::Exportable entspricht dem Integer-Wert 4
        $exportableFlag = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
        $tempPfx = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
        $tempPfx.Import($pfxFilePath, $plainCaPassword,$exportableFlag)
        
        $rsaPrivateKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($tempPfx)
        
        if ($rsaPrivateKey) {
            $keyBytes = $null
            $header   = "-----BEGIN PRIVATE KEY-----"
            $footer   = "-----END PRIVATE KEY-----"

            # 1. PS 7 / .NET Core (.ExportPkcs8PrivateKey)
            if ($rsaPrivateKey.GetType().GetMethod("ExportPkcs8PrivateKey")) {
                $keyBytes =$rsaPrivateKey.ExportPkcs8PrivateKey()
            }
            
            # 2. PS 5.1 / CNG KSP via CngKey
            if (-not $keyBytes -and$rsaPrivateKey.Key) {
                try {
                    $cngFormat = [System.Security.Cryptography.CngKeyBlobFormat]::Pkcs8PrivateBlob
                    $keyBytes  = $rsaPrivateKey.Key.Export($cngFormat)
                } catch { }
            }

            # 3. PS 5.1 / Fallback via RSAParameters
            if (-not $keyBytes) {
                try {
                    $rsaCsp = New-Object System.Security.Cryptography.RSACryptoServiceProvider
                    $rsaCsp.ImportParameters($rsaPrivateKey.ExportParameters($true))
                    $keyBytes =$rsaCsp.ExportCspBlob($true)
                    $header   = "-----BEGIN RSA PRIVATE KEY-----"
                    $footer   = "-----END RSA PRIVATE KEY-----"
                } catch { }
            }

            # Key-Datei schreiben
            if ($keyBytes) {
                $keyBase64 = [System.Convert]::ToBase64String($keyBytes, "InsertLineBreaks")
                $pemKeyContent = "$header`n$keyBase64`n$footer"
                [System.IO.File]::WriteAllText((Join-Path $targetDir "$ServiceName.key"), $pemKeyContent)
            }
        }

        Remove-Item -Path "Cert:\CurrentUser\My\$($serviceCert.Thumbprint)" -ErrorAction SilentlyContinue

        return $targetDir
    }
    finally {
        # 3. AUFRÄUMEN: Root-CA aus dem Cert-Store entfernen
        $store.Open("ReadWrite")
        $store.Remove($caCert)
        $store.Close()
    }
}

# ------------------------------------------
# C. DASHBOARD STATUS ERNEUERN (KORRIGIERT)
# ------------------------------------------
function Update-Dashboard {
    $config = Get-AppConfig
    if (-not $config) { return }

    # 1. Root-CA Status prüfen
    $dataDir = Join-Path $ScriptDir $config.Settings.CADirectory
    
    # Sicherstellen, dass CertificateFileName definiert ist
    if ($config.RootCA -and $config.RootCA.CertificateFileName) {
        $crtPath = Join-Path $dataDir $config.RootCA.CertificateFileName
    } else {
        $crtPath = $null
    }

    # Nur ausführen, wenn Pfad existiert UND die Datei da ist
    if (-not [string]::IsNullOrWhiteSpace($crtPath) -and (Test-Path $crtPath)) {
        try {
            $rootCertObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($crtPath)
            $daysLeft = [math]::Round(($rootCertObj.NotAfter - (Get-Date)).TotalDays)
            $TxtRootInfo.Text = "Aktiv: '$($rootCertObj.Subject)' | Gültig bis: $($rootCertObj.NotAfter.ToString('dd.MM.yyyy')) ($daysLeft Tage verbleibend)"
        } catch {
            $TxtRootInfo.Text = "Fehler beim Lesen der Root-CA Zertifikatsdatei."
        }
    } else {
        $TxtRootInfo.Text = "Keine Root-CA vorhanden. Bitte 'Root-CA Erstellen' klicken."
    }

    # 2. Service-Zertifikate aus config.yaml prüfen
    $exportDir = Join-Path $ScriptDir $config.Settings.ServicesDirectory
    $servicesList = [System.Collections.Generic.List[PSObject]]::new()

    if ($config.ServiceTemplates) {
        foreach ($srv in $config.ServiceTemplates) {
            $srvCertPath = Join-Path $exportDir "$($srv.Id)\$($srv.Id).crt"
            
            $status = "Fehlt"
            $validTo = "-"
            $daysLeftStr = "-"

            if (Test-Path $srvCertPath) {
                try {
                    $certObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($srvCertPath)
                    $days = [math]::Round(($certObj.NotAfter - (Get-Date)).TotalDays)
                    $validTo = $certObj.NotAfter.ToString("dd.MM.yyyy")
                    $daysLeftStr = "$days"

                    if ($days -le 0) {
                        $status = "Abgelaufen"
                    } elseif ($days -lt 30) {
                        $status = "Läuft bald ab"
                    } else {
                        $status = "Gültig"
                    }
                } catch {
                    $status = "Fehler"
                }
            }

            $servicesList.Add([PSCustomObject]@{
                Id         = $srv.Id
                CommonName = $srv.CommonName
                Status     = $status
                ValidTo    = $validTo
                DaysLeft   = $daysLeftStr
            })
        }
    }
    $GridServices.ItemsSource = $servicesList
}

# ==========================================
# 4. EVENT HANDLER
# ==========================================

function Load-ConfigToUI {
    if (Test-Path $ConfigPath) {
        $rawYaml = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)
        $TxtYamlContent.Text =$rawYaml
        Update-Dashboard
        $TxtStatus.Text = "Konfiguration geladen."
    }
}

# Root-CA Erstellen
$BtnCreateRootCA.Add_Click({
    try {
        $cred = Get-Credential -UserName "RootCA_Owner" -Message "Bitte Master-Passwort für die Root-CA eingeben:"
        
        # Abbrechen, falls Dialog geschlossen oder Passwort leer gelassen wurde
        if (-not $cred -or -not $cred.Password -or $cred.Password.Length -eq 0) {
            [System.Windows.MessageBox]::Show("Erstellung abgebrochen: Es wurde kein Passwort eingegeben.", "Hinweis", "OK", "Warning")
            return
        }

        $crtPath = New-RootCA -Password $cred.Password
        Update-Dashboard
        $TxtStatus.Text = "Root-CA erfolgreich erstellt!"
        [System.Windows.MessageBox]::Show("Root-CA wurde erfolgreich erstellt!`n`nZertifikat: $crtPath", "Erfolg", "OK", "Information")
    } catch {
        [System.Windows.MessageBox]::Show("Fehler bei Root-CA Erstellung:`n$_", "Fehler", "OK", "Error")
    }
})

# EXPORT BUTTON FÜR ROOT CA (Gefehltes Feature)
$BtnExportRootCA.Add_Click({
    try {
        $config = Get-AppConfig $dataDir = Join-Path $ScriptDir $config.Settings.CADirectory
        $crtPath = Join-Path $dataDir $config.RootCA.CertificateFileName

        if (-not (Test-Path $crtPath)) {
            [System.Windows.MessageBox]::Show("Keine Root-CA (.crt) im Datenordner gefunden. Bitte erst eine erstellen.", "Achtung", "OK", "Warning")
            return
        }

        # SaveFileDialog zum Abspeichern auf USB-Stick oder Ordner
        $sfd = New-Object Microsoft.Win32.SaveFileDialog
        $sfd.FileName =$config.RootCA.CertificateFileName
        $sfd.Filter = "Zertifikate (*.crt)|*.crt|Alle Dateien (*.*)|*.*"
        
        if ($sfd.ShowDialog()) {
            Copy-Item -Path $crtPath -Destination $sfd.FileName -Force$TxtStatus.Text = "Root-CA exportiert nach: $($sfd.FileName)"
            [System.Windows.MessageBox]::Show("Root-CA erfolgreich exportiert!`n`nZiel: $($sfd.FileName)", "Erfolg", "OK", "Information")
        }
    } catch {
        [System.Windows.MessageBox]::Show("Fehler beim Exportieren:`n$_", "Fehler", "OK", "Error")
    }
})

# Ausgewählten Dienst erneuern
$BtnRenewSelected.Add_Click({
    try {
        $selected = $GridServices.SelectedItem
        if (-not $selected) {
            [System.Windows.MessageBox]::Show("Bitte wähle zuerst einen Dienst aus der Liste aus.", "Hinweis", "OK", "Warning")
            return
        }

        $config = Get-AppConfig
        $template = $config.ServiceTemplates | Where-Object { $_.Id -eq $selected.Id }

        if (-not $template) {
            [System.Windows.MessageBox]::Show("Kein Template für '$($selected.Id)' in config.yaml gefunden.", "Fehler", "OK", "Error")
            return
        }

        $cred = Get-Credential -UserName "RootCA_Owner" -Message "Root-CA Passwort eingeben für Erneuerung von '$($selected.Id)':"
        if (-not $cred) { return }

        New-ServiceCertificate `
            -ServiceName $template.Id `
            -CommonName $template.CommonName `
            -DnsNames $template.SAN.DnsNames `
            -IpAddresses $template.SAN.IPAddresses `
            -CaPassword $cred.Password

        Update-Dashboard
        $TxtStatus.Text = "Zertifikat für '$($template.Id)' erneuert."
        [System.Windows.MessageBox]::Show("Zertifikat für '$($template.Id)' wurde erfolgreich erneuert!", "Erfolg", "OK", "Information")
    } catch {
        [System.Windows.MessageBox]::Show("Fehler beim Erneuern:`n$_", "Fehler", "OK", "Error")
    }
})

# Alle abgelaufenen/fehlenden erneuern
$BtnRenewAll.Add_Click({
    try {
        $config = Get-AppConfig
        if (-not $config.ServiceTemplates) { return }

        $cred = Get-Credential -UserName "RootCA_Owner" -Message "Master-Passwort eingeben, um ALLE Dienst-Zertifikate zu erneuern:"
        if (-not $cred) { return }

        $count = 0
        foreach ($template in $config.ServiceTemplates) {
            New-ServiceCertificate `
                -ServiceName $template.Id `
                -CommonName $template.CommonName `
                -DnsNames $template.SAN.DnsNames `
                -IpAddresses $template.SAN.IPAddresses `
                -CaPassword $cred.Password
            $count++
        }

        Update-Dashboard
        $TxtStatus.Text = "$count Zertifikate erneuert."
        [System.Windows.MessageBox]::Show("Es wurden $count Zertifikate erfolgreich neu ausgestellt!", "Erfolg", "OK", "Information")
    } catch {
        [System.Windows.MessageBox]::Show("Fehler beim Erneuern aller Zertifikate:`n$_", "Fehler", "OK", "Error")
    }
})

# Einzelnes Zertifikat manuell ausstellen
$BtnIssueCert.Add_Click({
    try {
        if (-not $TxtServiceName.Text -or -not $TxtServiceCN.Text) {
            [System.Windows.MessageBox]::Show("Bitte mindestens Dienst ID/Name und Common Name angeben.", "Achtung", "OK", "Warning")
            return
        }

        $cred = Get-Credential -UserName "RootCA_Owner" -Message "Bitte Master-Passwort der Root-CA eingeben:"
        if (-not $cred) { return }

        $dnsArray = $TxtSAN_DNS.Text -split "," | ForEach-Object { $_.Trim() }
        $ipArray  = $TxtSAN_IP.Text -split "," | ForEach-Object { $_.Trim() }

        $outDir = New-ServiceCertificate `
            -ServiceName $TxtServiceName.Text `
            -CommonName $TxtServiceCN.Text `
            -DnsNames $dnsArray `
            -IpAddresses $ipArray `
            -CaPassword $cred.Password

        Update-Dashboard
        $TxtStatus.Text = "Zertifikat für '$($TxtServiceName.Text)' generiert!"
        [System.Windows.MessageBox]::Show("Zertifikat ausgestellt unter:`n$outDir", "Erfolg", "OK", "Information")
    } catch {
        [System.Windows.MessageBox]::Show("Fehler beim Erstellen:`n$_", "Fehler", "OK", "Error")
    }
})

# Config Speichern
$BtnSaveYaml.Add_Click({
    try {
        Set-Content -Path $ConfigPath -Value $TxtYamlContent.Text -Encoding utf8 -Force
        Update-Dashboard
        $TxtStatus.Text = "config.yaml gespeichert und Status aktualisiert."
        [System.Windows.MessageBox]::Show("Konfiguration gespeichert und Dashboard aktualisiert.", "Erfolg", "OK", "Information") | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show("Fehler beim Speichern: $_", "Fehler", "OK", "Error") | Out-Null
    }
})

# Init
Load-ConfigToUI

# GUI starten
$window.ShowDialog() | Out-Null