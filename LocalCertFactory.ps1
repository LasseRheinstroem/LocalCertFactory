# ==========================================
# LOCAL CERT FACTORY - MAIN SCRIPT
# ==========================================
# Konsolenfenster verstecken
$asyncMethods = '[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow); [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();'
$type = Add-Type -MemberDefinition $asyncMethods -Name 'WinApi' -Namespace 'GUI' -PassThru
$type::ShowWindow($type::GetConsoleWindow(), 0) | Out-Null
Add-Type -AssemblyName PresentationFramework

# --- 0. SCRIPT ENVIRONMENT ---
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configPath = Join-Path $ScriptDir "config.yaml"
$xamlPath   = Join-Path $ScriptDir "gui.xaml"

if (-not (Test-Path $xamlPath)) {
    Write-Error "gui.xaml nicht gefunden!"
    exit
}

# --- 1. MODULE-PRÜFUNG ---
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

# --- 2. DEFAULT CONFIG ---
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
    ou: Service Certificate
    exports:
      pfx: false
      crt: true
      key: true
      pem_cert: false
      pem_full: false
      chain: false
      fullchain: false

service_certificates: []
"@

# --- 3. CRYPTO FUNKTIONEN (Niedergeschriebene Kernlogik zur Erstellung von Zertifikaten und direkten Schnittstellen zu OpenSSL.) ---
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

function Test-OpenSslVerify {
    param(
        [string]$CertPath,
        [string]$CaFile,
        [string]$UntrustedFile = $null
    )
    if (-not (Test-Path $CertPath) -or -not (Test-Path $CaFile)) {
        return $false
    }
    try {
        $argsList = @("verify", "-CAfile", $CaFile)
        if (-not [string]::IsNullOrWhiteSpace($UntrustedFile) -and (Test-Path $UntrustedFile)) {
            $argsList += @("-untrusted", $UntrustedFile)
        }
        $argsList += $CertPath
        
        $output = Invoke-OpenSSL -Arguments $argsList
        return ($output -match "OK")
    } catch {
        return $false
    }
}

function New-RootCA {
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingPlainTextForPassword", "")]
    param(
        [Parameter(Mandatory=$true)][string]$Password,
        [hashtable]$Params,
        [switch]$Renew
    )

    $caDir = Get-AbsolutePath $global:Config.paths.ca_directory
    if (-not (Test-Path $caDir)) { New-Item -ItemType Directory -Path $caDir -Force | Out-Null }

    $baseName = if ($Params.BaseFilename) { $Params.BaseFilename } else { "RootCA" }
    $keyPath  = Join-Path $caDir "$baseName.key"
    $crtPath  = Join-Path $caDir "$baseName.crt"
    $pfxPath  = Join-Path $caDir "$baseName.pfx"
    $cnfPath  = Join-Path $env:TEMP "root_ca_$([Guid]::NewGuid().ToString('N')).cnf"

    $hasPassword = -not [string]::IsNullOrWhiteSpace($Password)

    # Validierung im Renew-Fall
    if ($Renew -and -not (Test-Path $keyPath)) {
        throw "Der private Schlüssel ($keyPath) existiert nicht. Erneuerung nicht möglich!"
    }

    $subj = "/C=$($Params.Country)/ST=$($Params.State)/L=$($Params.Locality)/O=$($Params.Organization)/OU=$($Params.OU)/CN=$($Params.CommonName)"

    $cnfContent = @"
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
    Set-Content -Path $cnfPath -Value $cnfContent -Encoding UTF8

    try {
        # 1. Zertifikat erstellen oder erneuern
        $openSslArgs = @(
            "req", "-new", "-x509", "-sha256",
            "-config", $cnfPath,
            "-days", $Params.ValidityDays.ToString(),
            "-subj", $subj
        )

        if ($Renew) {
            # Bestehenden Schlüssel verwenden
            $openSslArgs += @("-key", $keyPath)
            if ($hasPassword) { $openSslArgs += @("-passin", "pass:$Password") }
        } else {
            # Neuen Schlüssel erzeugen
            $openSslArgs += @("-newkey", "rsa:$($Params.KeyLength)", "-keyout", $keyPath, "-out", $crtPath)
            if ($hasPassword) {
                $openSslArgs += @("-passout", "pass:$Password")
            } else {
                $openSslArgs += "-nodes"
            }
        }

        # Bei Renew muss -out explizit gesetzt werden (falls oben nicht in den Args)
        if ($Renew) { $openSslArgs += @("-out", $crtPath) }

        Invoke-OpenSSL -Arguments $openSslArgs | Out-Null

        if (-not (Test-Path $crtPath)) {
            throw "OpenSSL hat die Zertifikatsdatei '$crtPath' nicht erzeugt."
        }

        # 2. PFX-Datei erzeugen / aktualisieren
        $pfxPass = if ($hasPassword) { "pass:$Password" } else { "pass:" }
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

function New-IntermediateCA {
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingPlainTextForPassword", "")]
    param(
        [Parameter(Mandatory=$true)][string]$RootPassword,
        [string]$IntermediatePassword = $null,
        [hashtable]$Params,
        [switch]$Renew
    )

    $caDir = Get-AbsolutePath $global:Config.paths.ca_directory
    if (-not (Test-Path $caDir)) { New-Item -ItemType Directory -Path $caDir -Force | Out-Null }

    # Pfade für Root-CA
    $rootBaseName = if ($global:Config.defaults.root_ca.base_filename) { $global:Config.defaults.root_ca.base_filename } else { "RootCA" }
    $rootKeyPath  = Join-Path $caDir "$rootBaseName.key"
    $rootCrtPath  = Join-Path $caDir "$rootBaseName.crt"

    # Pfade für Intermediate-CA
    $baseName     = if ($Params.BaseFilename) { $Params.BaseFilename } else { "IntermediateCA" }
    $interKeyPath = Join-Path $caDir "$baseName.key"
    $interCsrPath = Join-Path $caDir "$baseName.csr"
    $interCrtPath = Join-Path $caDir "$baseName.crt"
    $interPfxPath = Join-Path $caDir "$baseName.pfx"
    $cnfPath      = Join-Path $env:TEMP "inter_ca_$([Guid]::NewGuid().ToString('N')).cnf"

    # Validierungen
    if (-not (Test-Path $rootKeyPath) -or -not (Test-Path $rootCrtPath)) {
        throw "Root CA Schlüssel oder Zertifikat fehlen im Pfad '$caDir'!"
    }
    if ($Renew -and -not (Test-Path $interKeyPath)) {
        throw "Der private Schlüssel der Intermediate-CA ($interKeyPath) existiert nicht. Erneuerung nicht möglich!"
    }

    $pathLen = if ($Params.ContainsKey('PathLen') -and $null -ne $Params.PathLen) { $Params.PathLen } else { 0 }
    $hasInterPassword = -not [string]::IsNullOrWhiteSpace($IntermediatePassword)
    $subj = "/C=$($Params.Country)/ST=$($Params.State)/L=$($Params.Locality)/O=$($Params.Organization)/OU=$($Params.OU)/CN=$($Params.CommonName)"

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
        # 1. Private Key erzeugen (nur bei Ersterstellung)
        if (-not $Renew) {
            $keyArgs = @("genrsa", "-out", $interKeyPath)
            if ($hasInterPassword) {
                $keyArgs = @("genrsa", "-aes256", "-passout", "pass:$IntermediatePassword", "-out", $interKeyPath)
            }
            $keyArgs += $Params.KeyLength.ToString()
            Invoke-OpenSSL -Arguments $keyArgs | Out-Null
        }

        # 2. CSR erzeugen (nutzt neuen oder bestehenden Key)
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

        # 3. Zertifikat durch Root-CA signieren
        $signArgs = @(
            "x509", "-req",
            "-in", $interCsrPath,
            "-CA", $rootCrtPath,
            "-CAkey", $rootKeyPath,
            "-CAcreateserial",
            "-out", $interCrtPath,
            "-days", $Params.ValidityDays.ToString(),
            "-sha256",
            "-extfile", $cnfPath,
            "-extensions", "v3_intermediate_ca"
        )
        if (-not [string]::IsNullOrWhiteSpace($RootPassword)) {
            $signArgs += @("-passin", "pass:$RootPassword")
        }
        Invoke-OpenSSL -Arguments $signArgs | Out-Null

        if (-not (Test-Path $interCrtPath)) {
            throw "OpenSSL hat die Zertifikatsdatei '$interCrtPath' nicht erzeugt."
        }

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
    $useInter = ($null -ne $pkiState.IntermediateCA -and $pkiState.IntermediateCA.Status -ne "Defekt")

    if ($useInter) {
        $interBase      = if ($global:Config.defaults.intermediate_ca.base_filename) { $global:Config.defaults.intermediate_ca.base_filename } else { "IntermediateCA" }
        $signingKeyPath = Join-Path $caDir "$interBase.key"
        $signingCrtPath = Join-Path $caDir "$interBase.crt"
    } else {
        $rootBase       = if ($global:Config.defaults.root_ca.base_filename) { $global:Config.defaults.root_ca.base_filename } else { "RootCA" }
        $signingKeyPath = Join-Path $caDir "$rootBase.key"
        $signingCrtPath = Join-Path $caDir "$rootBase.crt"
    }

    $safeName       = $Params.CommonName -replace '[^a-zA-Z0-9\.-]', '_'
    $svcKeyPath     = Join-Path $certDir "$safeName.key"
    $svcCsrPath     = Join-Path $certDir "$safeName.csr"
    $svcCrtPath     = Join-Path $certDir "$safeName.crt"
    $svcPfxPath     = Join-Path $certDir "$safeName.pfx"
    $certPemOnly    = Join-Path $certDir "$safeName.pem"
    $certPemFull    = Join-Path $certDir "$safeName.full.pem"
    $certChain      = Join-Path $certDir "$safeName.chain.crt"
    $certFullChain  = Join-Path $certDir "$safeName.fullchain.crt"

    $subj    = "/OU=$($Params.OU)/CN=$($Params.CommonName)"

    # 1. Key & CSR Generierung ...
    $keyArgs = @("genrsa", "-out", $svcKeyPath, $Params.KeyLength.ToString())
    Invoke-OpenSSL -Arguments $keyArgs | Out-Null

    $csrArgs = @(
        "req", "-new",
        "-key", $svcKeyPath,
        "-out", $svcCsrPath,
        "-subj", $subj
    )
    Invoke-OpenSSL -Arguments $csrArgs | Out-Null

    # 2. OpenSSL Extensions Config
    $cnfPath = Join-Path $env:TEMP "svc_ext.cnf"
    $sanList = @("DNS:$($Params.CommonName)")
    if ($Params.SANsDNS) { foreach ($dns in $Params.SANsDNS) { $sanList += "DNS:$dns" } }
    if ($Params.SANsIP)  { foreach ($ip in $Params.SANsIP)   { $sanList += "IP:$ip" } }
    $sanString = ($sanList | Select-Object -Unique) -join ","

    $kuString = if ($Params.KeyUsages -and $Params.KeyUsages.Count -gt 0) { $Params.KeyUsages -join ", " } else { "digitalSignature, keyEncipherment" }

    # Mapping von GUI-Langtext auf OpenSSL-Syntax
    $ekuOpenSSL = switch -Wildcard ($Params.EKU) {
        "*serverAuth*" { "serverAuth" }
        "*clientAuth*" { "clientAuth" }
        "*Beides*"     { "serverAuth, clientAuth" }
        "*codeSigning*"{ "codeSigning" }
        "*Kein EKU*"   { "none" }
        "*none*"       { "none" }
        Default        { $Params.EKU } # Falls bereits ein kurzes Keyword übergeben wurde
    }
    $ekuLine = if ($ekuOpenSSL -and $ekuOpenSSL -ne "none") { "extendedKeyUsage = $ekuOpenSSL" } else { "" }

    $cnfContent = @"
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = critical, $kuString
$ekuLine
subjectAltName = $sanString
"@
    Set-Content -Path $cnfPath -Value $cnfContent -Encoding UTF8

    try {
        # 3. Signierung
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
        if (-not [string]::IsNullOrWhiteSpace($CaPassword)) {
            $signArgs += @("-passin", "pass:$CaPassword")
        } else {
            $signArgs += @("-passin", "pass:")
        }
        Invoke-OpenSSL -Arguments $signArgs | Out-Null

        # 4. PFX Export (falls in Config/GUI gewählt)
        if ($Params.Exports.pfx) {
            $pfxPassArg = if (-not [string]::IsNullOrWhiteSpace($PfxPassword)) { "pass:$PfxPassword" } else { "pass:" }
            $pfxArgs = @(
                "pkcs12", "-export",
                "-out", $svcPfxPath,
                "-inkey", $svcKeyPath,
                "-in", $svcCrtPath,
                "-certfile", $signingCrtPath,
                "-passin", "pass:",
                "-passout", $pfxPassArg
            )
            Invoke-OpenSSL -Arguments $pfxArgs | Out-Null
        }

        # 5. PEM / Chain / Fullchain Exporte
        if ($Params.Exports.pem_cert) {
            Copy-Item -Path $svcCrtPath -Destination $certPemOnly -Force
        }

        if ($Params.Exports.chain) {
            # Nur die Zertifikatskette der herausgebenden CAs
            Copy-Item -Path $signingCrtPath -Destination $certChain -Force
        }

        if ($Params.Exports.fullchain -or $Params.Exports.pem_full) {
            # Service-Zertifikat + Signing-CA Zertifikat
            $crtContent = Get-Content -Path $svcCrtPath -Raw
            $signingCrtContent = Get-Content -Path $signingCrtPath -Raw
            $fullContent = "$crtContent`n$signingCrtContent"

            if ($Params.Exports.fullchain) { Set-Content -Path $certFullChain -Value $fullContent -Encoding UTF8 }
            if ($Params.Exports.pem_full) { Set-Content -Path $certPemFull -Value $fullContent -Encoding UTF8 }
        }

    } finally {
        if (Test-Path $cnfPath) { Remove-Item $cnfPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $svcCsrPath) { Remove-Item $svcCsrPath -Force -ErrorAction SilentlyContinue }
    }
}

# --- 4. SERVICES FUNKTIONEN (High-Level Business-Logik zur Verwaltung, Validierung und Wiederherstellung von Zertifikaten.) ---
function Get-CertDetailsFromFile {
    param(
        [string]$CrtPath
    )

    if (-not (Test-Path $CrtPath)) { return $null }

    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CrtPath)
        $now = Get-Date
        $daysRemaining = [math]::Max(0, ($cert.NotAfter - $now).Days)
        $issuerCN = ($cert.Issuer -replace '.*CN=([^,]+).*', '$1')

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

        # Statusermittlung (Grundstatus ohne Chain-Prüfung, diese erfolgt in Get-SystemPkiState)
        $warnDays = if ($global:Config.defaults.threshold_days_warning) { [int]$global:Config.defaults.threshold_days_warning } else { 30 }
        $critDays = if ($global:Config.defaults.threshold_days_critical) { [int]$global:Config.defaults.threshold_days_critical } else { 7 }

        $status = "Gültig"
        $color  = "#107C41" # Grün

        if ($daysRemaining -le 0) {
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
            IsMissing        = $false
            Subject          = $cert.Subject
            Issuer           = $cert.Issuer
            CommonName       = ($cert.Subject -replace '.*CN=([^,]+).*', '$1')
            IssuerCommonName = $issuerCN
            NotBefore        = $cert.NotBefore
            NotAfter         = $cert.NotAfter
            ExpiryDate       = $cert.NotAfter.ToString("yyyy-MM-dd")
            DaysRemaining    = $daysRemaining
            SerialNumber     = $cert.SerialNumber
            Thumbprint       = $cert.Thumbprint
            SANs             = ($sanList -join ", ")
            Status           = $status
            StatusColor      = $color
            RawCert          = $cert
        }
    } catch {
        return $null
    }
}

function Get-FormattedEkuFromCert {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)

    if (-not $Cert) { return "Kein EKU" }

    # Extended Key Usage Extension (OID 2.5.29.37) suchen
    $ekuExt = $Cert.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.37" }
    
    if (-not $ekuExt) {
        return "Kein EKU"
    }

    # Formatierte OIDs/Namen auslesen (z.B. "1.3.6.1.5.5.7.3.1" oder "Server Authentication")
    $ekuParsed = [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]$ekuExt
    $usages = $ekuParsed.EnhancedKeyUsages | ForEach-Object { $_.Value }

    $hasServer = $usages -contains "1.3.6.1.5.5.7.3.1"
    $hasClient = $usages -contains "1.3.6.1.5.5.7.3.2"
    $hasCode   = $usages -contains "1.3.6.1.5.5.7.3.3"

    if ($hasServer -and $hasClient) {
        return "Beides (Server + Client Auth)"
    } elseif ($hasServer) {
        return "TLS Web Server Authentication (serverAuth)"
    } elseif ($hasClient) {
        return "TLS Web Client Authentication (clientAuth)"
    } elseif ($hasCode) {
        return "Code Signing (codeSigning)"
    } else {
        # Falls eine unbekannte/andere OID enthalten ist, als Fallback den Format-String nutzen
        return $ekuParsed.Format($false)
    }
}

function Repair-ServiceCertificates {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingPlainTextForPassword", "")]
    param(
        [Parameter(Mandatory=$true)][array]$CertificatesToRepair,
        [string]$CaPassword = $null
    )

    if ($CertificatesToRepair.Count -eq 0) { return }

    foreach ($certItem in $CertificatesToRepair) {
        $cn = if ($certItem.CommonName) { $certItem.CommonName } else { $certItem.ToString() }

        # Soll-Eintrag aus config.yaml laden
        $cfgMatch = $global:Config.service_certificates | Where-Object { $_.common_name -eq $cn }

        if (-not $cfgMatch) {
            Write-Warning "Keine Soll-Konfiguration für '$cn' in config.yaml gefunden. Erneuerung wird übersprungen."
            continue
        }

        # Parameter mit Fallbacks aus $global:Config.defaults bestimmen
        $validDays = if ($cfgMatch.validity_days) { [int]$cfgMatch.validity_days } else { [int]$global:Config.defaults.services.validity_days }
        $keyAlg    = if ($cfgMatch.key_algorithm) { $cfgMatch.key_algorithm } else { $global:Config.defaults.services.key_algorithm }
        $keyLen    = if ($cfgMatch.key_length)    { [int]$cfgMatch.key_length } else { [int]$global:Config.defaults.services.key_length }
        $ekuRaw    = if ($cfgMatch.eku)           { $cfgMatch.eku } else { $global:Config.defaults.services.default_eku }
        $usages    = if ($cfgMatch.key_usages)    { $cfgMatch.key_usages } else { @("digitalSignature", "keyEncipherment") }
        $exports   = if ($cfgMatch.exports)       { $cfgMatch.exports } else { $global:Config.defaults.services.exports }

        # EKU-Mapping für OpenSSL (wandelt Freitext/Klartext in OpenSSL-Kürzel um)
        $ekuVal = switch -Wildcard ($ekuRaw) {
            "*serverAuth*" { "serverAuth" }
            "*clientAuth*" { "clientAuth" }
            "*Beides*"     { "serverAuth, clientAuth" }
            "*codeSigning*"{ "codeSigning" }
            "*Kein EKU*"   { "none" }
            "*none*"       { "none" }
            Default        { $ekuRaw } # Falls bereits korrekt als "serverAuth" hinterlegt
        }

        $params = @{
            DisplayName  = if ($cfgMatch.display_name) { $cfgMatch.display_name } else { $cn }
            CommonName   = $cn
            OU           = if ($cfgMatch.ou) { $cfgMatch.ou } else { "Service Certificate" }
            SANsDNS      = if ($cfgMatch.sans_dns) { $cfgMatch.sans_dns } else { @() }
            SANsIP       = if ($cfgMatch.sans_ip)  { $cfgMatch.sans_ip }  else { @() }
            EKU          = $ekuVal
            ValidityDays = $validDays
            KeyAlgorithm = $keyAlg
            KeyLength    = $keyLen
            KeyUsages    = $usages
            Exports      = $exports
        }

        $splat = @{
            Params = $params
        }

        if ($CaPassword) {
            $splat['CaPassword'] = $CaPassword
        }

        # Zertifikat neu erzeugen
        New-ServiceCertificate @splat
    }
}

function Test-HasDueServices {
    param(
        $Services,
        [int]$WarningThreshold = 30
    )
    if ($null -eq $Services) { return $false }
    foreach ($item in $Services) {
        if ($item.Status -in @("Fehlt", "Defekt", "Abgelaufen", "Warnung", "Kritisch")) {
            return $true
        }
    }
    return $false
}

# --- 5. CONFIG FUNKTIONEN (Verwaltung der Anwendungs-Konfiguration, Dateipfade und Systemzustände.) ---
function Initialize-AppConfiguration {
    param (
        [string]$ConfigPath,
        [string]$DefaultConfigText
    )

    $rawText = Get-OrCreateConfig -FilePath $ConfigPath -DefaultContent $DefaultConfigText
    try {
        $config = ConvertFrom-Yaml -Yaml $rawText
    } catch {
        Write-Warning "Fehler beim Parsen der config.yaml, verwende Fallback: $_"
        $config = ConvertFrom-Yaml -Yaml $DefaultConfigText
    }

    # Ordnerstrukturen sicherstellen
    if ($config.paths) {
        foreach ($dirKey in @('ca_directory', 'certs_directory')) {
            if ($config.paths.$dirKey) {
                $absPath = Get-AbsolutePath $config.paths.$dirKey
                if ($absPath -and -not (Test-Path $absPath)) {
                    New-Item -ItemType Directory -Path $absPath -Force | Out-Null
                }
            }
        }
    }

    return $config
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
    if ($UI.TxtConfigEditor) { $UI.TxtConfigEditor.Text = $yamlString }
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

function Get-SystemPkiState {
    $caDir   = Get-AbsolutePath $global:Config.paths.ca_directory
    $certDir = Get-AbsolutePath $global:Config.paths.certs_directory

    # Dynamische Pfade aus Config-BaseNames ermitteln
    $rootBase  = if ($global:Config.defaults.root_ca.base_filename) { $global:Config.defaults.root_ca.base_filename } else { "RootCA" }
    $interBase = if ($global:Config.defaults.intermediate_ca.base_filename) { $global:Config.defaults.intermediate_ca.base_filename } else { "IntermediateCA" }

    $rootPaths  = Get-CaFilePaths -CaDir $caDir -BaseName $rootBase
    $interPaths = Get-CaFilePaths -CaDir $caDir -BaseName $interBase

    # 1. Root-CA laden und per OpenSSL selbst verifizieren (Self-Signed / Key-Mismatch-Erkennung)
    $rootCertDetails  = Get-CertDetailsFromFile -CrtPath $rootPaths.CrtPath
    if ($rootCertDetails) {
        $rootValid = Test-OpenSslVerify -CertPath $rootPaths.CrtPath -CaFile $rootPaths.CrtPath
        if (-not $rootValid) {
            $rootCertDetails.Status = "Defekt"
            $rootCertDetails.StatusColor = "#A80000" # Dunkelrot
        }
    }

    # 2. Intermediate-CA laden und per OpenSSL gegen Root-CA verifizieren
    $interCertDetails = Get-CertDetailsFromFile -CrtPath $interPaths.CrtPath
    if ($interCertDetails) {
        $interValid = $false
        if ($rootCertDetails -and $rootCertDetails.Status -ne "Defekt") {
            $interValid = Test-OpenSslVerify -CertPath $interPaths.CrtPath -CaFile $rootPaths.CrtPath
        }
        if (-not $interValid) {
            $interCertDetails.Status = "Defekt"
            $interCertDetails.StatusColor = "#A80000" # Dunkelrot
        }
    }

    # Aktive Unterzeichner-CA ermitteln (Intermediate bevorzugt, aber nur wenn nicht Defekt)
    $useInterSigning = ($null -ne $interCertDetails -and $interCertDetails.Status -ne "Defekt")

    $state = @{
        RootCA         = $rootCertDetails
        IntermediateCA = $interCertDetails
        Services       = @()
    }

    # Prüfen, ob Intermediate-CA passwortgeschützt ist
    if (Test-Path $interPaths.KeyPath) {
        $keyContent = Get-Content $interPaths.KeyPath -Raw
        $state.IntermediateHasPass = ($keyContent -match "ENCRYPTED")
    } else {
        $state.IntermediateHasPass = $false
    }
    # Prüfen, ob Root-CA passwortgeschützt ist
    if (Test-Path $rootPaths.KeyPath) {
        $keyContent = Get-Content $rootPaths.KeyPath -Raw
        $state.RootHasPass = ($keyContent -match "ENCRYPTED")
    } else {
        $state.RootHasPass = $false
    }

    # Tracking-Liste verarbeiteter Dateien
    $processedFiles = @()

    # 3. Alle in config.yaml definierten Services durchgehen (Soll-Zustand) & kryptografisch prüfen
    if ($global:Config.service_certificates) {
        foreach ($cfgSvc in $global:Config.service_certificates) {
            $cn = $cfgSvc.common_name
            $safeFileName = $cn -replace '[^a-zA-Z0-9\.-]', '_'
            $expectedCrtPath = Join-Path $certDir "$safeFileName.crt"

            if (Test-Path $expectedCrtPath) {
                $certInfo = Get-CertDetailsFromFile -CrtPath $expectedCrtPath

                # Kryptografische Kette per OpenSSL prüfen
                if ($certInfo -and $rootCertDetails -and $rootCertDetails.Status -ne "Defekt") {
                    $chainValid = $false
                    if ($useInterSigning) {
                        # Signiert durch Intermediate-CA (Trust Anchor = Root, Untrusted = Intermediate)
                        $chainValid = Test-OpenSslVerify -CertPath $expectedCrtPath -CaFile $rootPaths.CrtPath -UntrustedFile $interPaths.CrtPath
                    } else {
                        # Signiert direkt durch Root-CA
                        $chainValid = Test-OpenSslVerify -CertPath $expectedCrtPath -CaFile $rootPaths.CrtPath
                    }

                    if (-not $chainValid) {
                        $certInfo.Status = "Defekt"
                        $certInfo.StatusColor = "#A80000" # Dunkelrot
                    }
                } elseif ($certInfo) {
                    $certInfo.Status = "Defekt"
                    $certInfo.StatusColor = "#A80000"
                }

                $processedFiles += $expectedCrtPath
            } else {
                # Status: FEHLT
                $dnsSANs = if ($cfgSvc.sans_dns) { $cfgSvc.sans_dns -join ", " } else { "" }
                $ipSANs  = if ($cfgSvc.sans_ip)  { $cfgSvc.sans_ip -join ", " }  else { "" }
                $allSANs = (@($dnsSANs, $ipSANs) | Where-Object { $_ -ne "" }) -join ", "

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

    # 4. Waise .crt-Dateien erfassen & kryptografisch prüfen
    if (Test-Path $certDir) {
        $allCrtFiles = Get-ChildItem -Path $certDir -Filter "*.crt" | 
            Where-Object { $_.Name -notmatch '\.(chain|fullchain)\.crt$' }

        foreach ($file in $allCrtFiles) {
            if ($processedFiles -notcontains $file.FullName) {
                $certInfo = Get-CertDetailsFromFile -CrtPath $file.FullName
                
                if ($certInfo -and $rootCertDetails -and $rootCertDetails.Status -ne "Defekt") {
                    $chainValid = $false
                    if ($useInterSigning) {
                        $chainValid = Test-OpenSslVerify -CertPath $file.FullName -CaFile $rootPaths.CrtPath -UntrustedFile $interPaths.CrtPath
                    } else {
                        $chainValid = Test-OpenSslVerify -CertPath $file.FullName -CaFile $rootPaths.CrtPath
                    }

                    if (-not $chainValid) {
                        $certInfo.Status = "Defekt"
                        $certInfo.StatusColor = "#A80000"
                    }
                } elseif ($certInfo) {
                    $certInfo.Status = "Defekt"
                    $certInfo.StatusColor = "#A80000"
                }

                if ($certInfo) {
                    $detectedEku = Get-FormattedEkuFromCert -Cert $certInfo.RawCert

                    $certInfo | Add-Member -NotePropertyName "DisplayName" -NotePropertyValue $certInfo.CommonName -Force
                    $certInfo | Add-Member -NotePropertyName "EKU" -NotePropertyValue $detectedEku -Force
                    
                    if ($certInfo.Status -ne "Defekt") {
                        $certInfo.Status = "Orphan"
                        $certInfo.StatusColor = "#8A8886"
                    }
                    $state.Services += $certInfo
                }
            }
        }
    }

    return $state
}

# --- 6. UI FUNKTIONEN (WPF-Interaktion: Synchronisation zwischen Anwendungskontext und UI-Steuerelementen.) ---
function Initialize-GUI {
    param (
        [string]$XamlPath
    )

    $xamlText = [System.IO.File]::ReadAllText($XamlPath, [System.Text.Encoding]::UTF8)
    $reader   = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xamlText))
    $window   = [System.Windows.Markup.XamlReader]::Load($reader)

    # Auto-Mapping aller benannten Controls
    $uiMap = @{ Window = $window }
    $nodes = [System.Collections.Queue]::new()
    $nodes.Enqueue($window)

    while ($nodes.Count -gt 0) {
        $node = $nodes.Dequeue()

        # Name in Hashtable erfassen, falls vorhanden
        if ($node -is [System.Windows.FrameworkElement] -and $node.Name) {
            $uiMap[$node.Name] = $node
        }

        # 1. Kontextmenü explizit in die Warteschlange aufnehmen (da nicht im LogicalTree)
        if ($node -is [System.Windows.FrameworkElement] -and $node.ContextMenu) {
            $nodes.Enqueue($node.ContextMenu)
        }

        # 2. Falls das Element Unterpunkte besitzt (z.B. ContextMenu oder MenuItem)
        if ($node -is [System.Windows.Controls.ItemsControl]) {
            foreach ($item in $node.Items) {
                if ($item -is [System.Windows.DependencyObject]) { $nodes.Enqueue($item) }
            }
        }

        # 3. Standard-Kinder im Logical Tree durchsuchen
        if ($node -is [System.Windows.DependencyObject]) {
            [System.Windows.LogicalTreeHelper]::GetChildren($node) | ForEach-Object {
                if ($_ -is [System.Windows.DependencyObject]) { $nodes.Enqueue($_) }
            }
        }
    }

    return $uiMap
}

function LoadConfigToForm {
    $cfg = $global:Config
    $pkiState = Get-SystemPkiState

    $global:HasRootCA           = ($null -ne $pkiState.RootCA)
    $global:HasIntermediate     = ($null -ne $pkiState.IntermediateCA)
    $global:IntermediateHasPass = $pkiState.IntermediateHasPass

    # Formularfelder füllen
    # Root CA
    $UI.TxtRootCn.Text       = $cfg.defaults.root_ca.common_name
    $UI.TxtRootOrg.Text      = $cfg.defaults.organization
    $UI.TxtRootOu.Text       = $cfg.defaults.root_ca.ou
    $UI.TxtRootCountry.Text  = $cfg.defaults.country
    $UI.TxtRootState.Text    = $cfg.defaults.state
    $UI.TxtRootLocality.Text = $cfg.defaults.locality
    $UI.TxtRootDays.Text     = $cfg.defaults.root_ca.validity_days.ToString()
    Set-ComboBoxByText -ComboBox $UI.CmbRootAlgorithm -Value $cfg.defaults.root_ca.key_algorithm
    Set-ComboBoxByText -ComboBox $UI.CmbRootKeyLength -Value $cfg.defaults.root_ca.key_length.ToString()
    $UI.TxtRootBaseFilename.Text = $cfg.defaults.root_ca.base_filename

    # Intermediate CA
    $UI.TxtInterCn.Text      = $cfg.defaults.intermediate_ca.common_name
    $UI.TxtInterOrg.Text     = $cfg.defaults.organization
    $UI.TxtInterDays.Text    = $cfg.defaults.intermediate_ca.validity_days.ToString()
    if ($UI.TxtInterPathLen -and $null -ne $cfg.defaults.intermediate_ca.pathlen) {
        $UI.TxtInterPathLen.Text = $cfg.defaults.intermediate_ca.pathlen.ToString()
    }
    Set-ComboBoxByText -ComboBox $UI.CmbInterAlgorithm -Value $cfg.defaults.intermediate_ca.key_algorithm
    Set-ComboBoxByText -ComboBox $UI.CmbInterKeyLength -Value $cfg.defaults.intermediate_ca.key_length.ToString()
    $UI.TxtInterBaseFilename.Text = $cfg.defaults.intermediate_ca.base_filename

    # Service Defaults & Identitätsattribute
    $UI.TxtServiceOu.Text   = $cfg.defaults.services.ou
    $UI.TxtServiceDays.Text = $cfg.defaults.services.validity_days.ToString()
    
    Set-ComboBoxByText -ComboBox $UI.CmbServiceAlgorithm -Value $cfg.defaults.services.key_algorithm
    Set-ComboBoxByText -ComboBox $UI.CmbServiceKeyLength -Value $cfg.defaults.services.key_length.ToString()

    $UI.ChkExportPfx.IsChecked       = [bool] $cfg.defaults.services.exports.pfx
    $UI.ChkExportCrt.IsChecked       = [bool] $cfg.defaults.services.exports.crt
    $UI.ChkExportKey.IsChecked       = [bool] $cfg.defaults.services.exports.key
    $UI.ChkExportPemOnly.IsChecked   = [bool] $cfg.defaults.services.exports.pem_cert
    $UI.ChkExportPemFull.IsChecked   = [bool] $cfg.defaults.services.exports.pem_full
    $UI.ChkExportChain.IsChecked     = [bool] $cfg.defaults.services.exports.chain
    $UI.ChkExportFullChain.IsChecked = [bool] $cfg.defaults.services.exports.fullchain

    $UI.TxtConfigEditor.Text = ConvertTo-Yaml -Data $cfg
}

function LoadServiceCertToForm {
    param($ServiceItem)

    # 1. Soll-Konfiguration aus config.yaml suchen
    $cfgMatch = $global:Config.service_certificates | Where-Object { $_.common_name -eq $ServiceItem.CommonName }

    # Fallbacks aus defaults laden, falls Einzelwerte fehlen
    $defSvc = $global:Config.defaults.services

    $dispName = if ($cfgMatch.display_name)  { $cfgMatch.display_name }  else { $ServiceItem.DisplayName }
    $cn       = if ($cfgMatch.common_name)   { $cfgMatch.common_name }   else { $ServiceItem.CommonName }
    $ou       = if ($cfgMatch.ou)            { $cfgMatch.ou }            else { $defSvc.ou }
    $days     = if ($cfgMatch.validity_days) { $cfgMatch.validity_days } else { $defSvc.validity_days }
    $ekuVal   = if ($cfgMatch.eku)           { $cfgMatch.eku }           else { $defSvc.default_eku }
    $keyAlg   = if ($cfgMatch.key_algorithm) { $cfgMatch.key_algorithm } else { $defSvc.key_algorithm }
    $keyLen   = if ($cfgMatch.key_length)    { $cfgMatch.key_length }    else { $defSvc.key_length }

    # Formularfelder belegen
    $UI.TxtServiceDisplayName.Text = $dispName
    $UI.TxtServiceCn.Text          = $cn
    $UI.TxtServiceOu.Text          = $ou
    $UI.TxtServiceDays.Text        = $days.ToString()

    # SANs laden
    $dnsSANs = if ($cfgMatch.sans_dns) { $cfgMatch.sans_dns -join ", " } else { "" }
    $ipSANs  = if ($cfgMatch.sans_ip)  { $cfgMatch.sans_ip -join ", " }  else { "" }
    $UI.TxtServiceDnsSANs.Text = $dnsSANs
    $UI.TxtServiceIpSANs.Text  = $ipSANs

    # ComboBoxen setzen
    Set-ComboBoxByText -ComboBox $UI.CmbServiceEku       -Value $ekuVal
    Set-ComboBoxByText -ComboBox $UI.CmbServiceAlgorithm -Value $keyAlg
    Set-ComboBoxByText -ComboBox $UI.CmbServiceKeyLength -Value $keyLen.ToString()

    # Key Usages setzen
    $usages = if ($cfgMatch.key_usages) { $cfgMatch.key_usages } else { @("digitalSignature", "keyEncipherment") }
    $UI.ChkKuDigitalSignature.IsChecked = ($usages -contains "digitalSignature")
    $UI.ChkKuKeyEncipherment.IsChecked  = ($usages -contains "keyEncipherment")
    $UI.ChkKuDataEncipherment.IsChecked = ($usages -contains "dataEncipherment")
    $UI.ChkKuKeyAgreement.IsChecked     = ($usages -contains "keyAgreement")

    # Exporte setzen
    $exp = if ($cfgMatch.exports) { $cfgMatch.exports } else { $defSvc.exports }
    $UI.ChkExportPfx.IsChecked       = [bool]$exp.pfx
    $UI.ChkExportCrt.IsChecked       = [bool]$exp.crt
    $UI.ChkExportKey.IsChecked       = [bool]$exp.key
    $UI.ChkExportPemOnly.IsChecked   = [bool]$exp.pem_cert
    $UI.ChkExportPemFull.IsChecked   = [bool]$exp.pem_full
    $UI.ChkExportChain.IsChecked     = [bool]$exp.chain
    $UI.ChkExportFullChain.IsChecked = [bool]$exp.fullchain
}

function Update-ConfigTabState {
    if ($global:HasRootCA) {
        $UI.BtnImportConfig.IsEnabled = $false
        $UI.TxtConfigNotice.Text = "🔒 Die Konfiguration ist gesperrt, da bereits eine aktive Root-CA existiert. So werden versehentliche Fehlkonfigurationen vermieden. Du kannst die aktuelle Konfiguration weiterhin exportieren."
    } else {
        $UI.BtnImportConfig.IsEnabled = $true
        $UI.TxtConfigNotice.Text = "ℹ️ Noch keine Root-CA angelegt: Du kannst eine bestehende 'config.yaml' importieren, um Voreinstellungen für eine Neuinstallation zu übernehmen."
    }
}

function Update-DashboardStatus {
    $pkiState = Get-SystemPkiState

    $global:HasRootCA           = ($null -ne $pkiState.RootCA)
    $global:HasIntermediate     = ($null -ne $pkiState.IntermediateCA)
    $global:IntermediateHasPass = $pkiState.IntermediateHasPass

    $canIssueCertificates = $global:HasRootCA

    # UI-Sperren
    
    $UI.BtnNewService.IsEnabled = $canIssueCertificates
    $UI.BtnNewService.ToolTip = if (-not $canIssueCertificates) { "Es muss zuerst eine Root-CA angelegt werden." } else { $null }
    if ($UI.PanelNoCaWarning) { $UI.PanelNoCaWarning.Visibility = if ($canIssueCertificates) { "Collapsed" } else { "Visible" } }

    $UI.BtnShowCreateIntermediate.IsEnabled = $canIssueCertificates
    if ($UI.PanelNoRootForInterWarning) { $UI.PanelNoRootForInterWarning.Visibility = if ($canIssueCertificates) { "Collapsed" } else { "Visible" } }

    # Grid Datenbindung
    $UI.GridServices.ItemsSource = $pkiState.Services

    # Root-CA Details anzeigen
    if ($global:HasRootCA) {
        $root = $pkiState.RootCA
        $global:RootDaysRemaining = $root.DaysRemaining

        $UI.TxtRootCaInfo.Text  = $root.CommonName
        $UI.TxtRootCaExpiry.Text = "(Gültig bis: $($root.ExpiryDate), $($root.DaysRemaining) Tage restlich)"
        $UI.TxtRootCaExpiry.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($root.StatusColor)

        $UI.PanelCaDetails.Visibility = "Visible"
        $UI.TxtCaMissing.Visibility   = "Collapsed"
        $UI.BtnShowCreateRootCA.Visibility = "Collapsed"
        $UI.BtnRenewRootCA.Visibility = "Visible"
        Set-ButtonStyle -Button $UI.BtnRenewRootCA -DaysRemaining $root.DaysRemaining

        # Intermediate-CA Details
        if ($global:HasIntermediate) {
            $inter = $pkiState.IntermediateCA
            $global:InterDaysRemaining = $inter.DaysRemaining

            $passState = if ($global:IntermediateHasPass) { "Passwortgeschützt" } else { "Passwortlos" }
            $UI.TxtInterCaInfo.Text  = "$($inter.CommonName) ($passState)"
            $UI.TxtInterCaExpiry.Text = "(Gültig bis: $($inter.ExpiryDate), $($inter.DaysRemaining) Tage restlich)"
            $UI.TxtInterCaExpiry.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($inter.StatusColor)

            $isInterUsable = ($inter.Status -ne "Defekt")
            $UI.TxtSignModeInfo.Text = if ($isInterUsable) { "Aktiv signierende CA: Intermediate-CA" } else { "⚠️ Intermediate-CA ist DEFEKT (Kette ungültig)!" }
            $UI.TxtSignModeInfo.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($(if ($isInterUsable) { "#0078D4" } else { "#D13438" }))

            $UI.BtnShowCreateIntermediate.Visibility = "Collapsed"
            $UI.BtnRenewIntermediate.Visibility      = "Visible"
            Set-ButtonStyle -Button $UI.BtnRenewIntermediate -DaysRemaining $inter.DaysRemaining
        } else {
            $UI.TxtInterCaInfo.Text   = "Nicht vorhanden"
            $UI.TxtInterCaExpiry.Text = ""
            $UI.TxtSignModeInfo.Text  = "Aktiv signierende CA: Root-CA"
            $UI.TxtSignModeInfo.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0078D4")
            $UI.BtnShowCreateIntermediate.Visibility = "Visible"
            $UI.BtnRenewIntermediate.Visibility      = "Collapsed"
        }
    } else {
        $UI.PanelCaDetails.Visibility = "Collapsed"
        $UI.TxtCaMissing.Visibility   = "Visible"
        $UI.BtnShowCreateRootCA.Visibility = "Visible"
        $UI.BtnRenewRootCA.Visibility = "Collapsed"
        $UI.BtnRenewIntermediate.Visibility = "Collapsed"
    }

    if ($UI.BtnRenewDue) { 
        $hasDue = Test-HasDueServices -Services $pkiState.Services
        $UI.BtnRenewDue.IsEnabled = $hasDue 
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

# --- 7. UTILS FUNKTIONEN (Allgemeine Helper-Funktionen für Pfadauflösung, Dateiüberprüfung und Passwort-Handling.) ---
function Get-OpenSSLPath {
    param (
        [Parameter(Mandatory= $true)] $Config,
        [version]$MinVersion = [version]"1.1.1"
    )

    # Hilfsskriptblock zur Prüfung einzelner Kandidaten
    $TestBinary = {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        
        # Falls kein direkter Pfad, im System-PATH suchen
        if (-not (Test-Path $Path -ErrorAction SilentlyContinue)) {
            $cmd = Get-Command $Path -ErrorAction SilentlyContinue
            if ($cmd) { $Path = $cmd.Source } else { return $null }
        }

        try {
            # Version direkt abfangen (ohne Temp-Datei)
            $pinfo = New-Object System.Diagnostics.ProcessStartInfo
            $pinfo.FileName = $Path
            $pinfo.Arguments = "version"
            $pinfo.RedirectStandardOutput = $true
            $pinfo.UseShellExecute = $false
            $pinfo.CreateNoWindow = $true

            $process = [System.Diagnostics.Process]::Start($pinfo)
            $verOutput = $process.StandardOutput.ReadToEnd()
            $null = $process.WaitForExit(3000)

            if ($verOutput -match "OpenSSL\s+([0-9]+\.[0-9]+\.[0-9]+)") {
                return [PSCustomObject]@{
                    Path    = $Path
                    Version = [version]$matches[1]
                }
            }
        } catch {}
        return $null
    }

    # 1. Kandidaten sammeln (Config, System-PATH, Standardpfade)
    $candidates = @(
        $Config.paths.openssl_exe,
        "openssl.exe",
        "C:\Program Files\Git\usr\bin\openssl.exe",
        "C:\Program Files (x86)\Git\usr\bin\openssl.exe",
        "C:\Program Files\OpenSSL-Win64\bin\openssl.exe",
        "C:\Program Files\OpenSSL-Win32\bin\openssl.exe",
        "C:\ProgramData\chocolatey\bin\openssl.exe"
    )

    $result = $null

    # 2. Automatische Suche durchführen
    foreach ($cand in $candidates) {
        $res = &$TestBinary -Path $cand
        if ($res) { $result = $res; break }
    }

    # 3. Fallback: Manueller Dialog, falls automatisch nichts gefunden wurde
    if (-not $result) {
        [System.Windows.MessageBox]::Show(
            "OpenSSL wurde im System nicht automatisch gefunden.`nBitte wähle die 'openssl.exe' manuell aus.",
            "OpenSSL erforderlich", "OK", "Warning"
        ) | Out-Null

        $openFileDialog = New-Object Microsoft.Win32.OpenFileDialog
        $openFileDialog.Filter = "Ausführbare Dateien (*.exe)|*.exe|Alle Dateien (*.*)|*.*"
        $openFileDialog.Title = "Bitte 'openssl.exe' auswählen"
        $openFileDialog.FileName = "openssl.exe"

        if ($openFileDialog.ShowDialog() -eq $true) {$result = &$TestBinary -Path$openFileDialog.FileName
            if (-not $result) {
                [System.Windows.MessageBox]::Show("Die ausgewählte Datei ist keine gültige OpenSSL-Binärdatei!", "Fehler", "OK", "Error") | Out-Null
            }
        }
    }

    # 4. Mindestversion prüfen & Ergebnis auswerten
    if ($result -and $result.Version -ge $MinVersion) {
        $Config.paths.openssl_exe =$result.Path
        return [PSCustomObject]@{ Success = $true; Path = $result.Path; Version = $result.Version }
    } elseif ($result) {
        [System.Windows.MessageBox]::Show(
            "Die gefundene OpenSSL-Version ($($result.Version)) ist zu alt!`nErforderlich ist mindestens Version $MinVersion.`nPfad: $($result.Path)",
            "Veraltete OpenSSL Version", "OK", "Error"
        ) | Out-Null
    } else {
        [System.Windows.MessageBox]::Show(
            "OpenSSL konnte nicht gefunden oder nicht gestartet werden.",
            "OpenSSL Fehler", "OK", "Error"
        ) | Out-Null
    }

    return [PSCustomObject]@{ Success = $false; Path = $null; Version =$null }
}

function Get-AbsolutePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return [System.IO.Path]::GetFullPath((Join-Path $ScriptDir $Path))
}

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

# --- 8. CONFIGURATION LOAD ---
$global:Config = Initialize-AppConfiguration -ConfigPath $configPath -DefaultConfigText $defaultConfigText

# --- 9. OPENSSL CHECK (BEFORE GUI INIT) ---
$openSslResult = Get-OpenSSLPath -Config $global:Config

# --- 10. XAML GUI LOAD & ELEMENT MAPPING ---
$script:UI = Initialize-GUI -XamlPath $xamlPath

# --- 11. INITIALISIERUNG ---
LoadConfigToForm

if ($openSslResult.Success) {
    Save-ConfigToFile
    $UI.TxtStatus.Text = "✅ OpenSSL $($openSslResult.Version) gefunden: $($openSslResult.Path)"
} else {
    $UI.TxtStatus.Text = "🚨 OpenSSL fehlt oder ist veraltet."
    $UI.BtnNewService.IsEnabled = $false
    $UI.BtnShowCreateRootCA.IsEnabled = $false
}

Update-DashboardStatus

# --- 12. Root & Intermediate CA Management (Aktionen zur Neuerstellung, Verlängerung und Navigation für die Root- und Intermediate-CAs.) ---
# Öffnet das Formular / die Ansicht zur Erstellung einer neuen Root CA.
$UI.BtnShowCreateRootCA.Add_Click({
    $UI.MainTabControl.SelectedItem = $UI.TabCreateRootCA
    $UI.TxtStatus.Text = "Root-CA Konfiguration..."
})

# Speichert die Konfiguration und generiert/speichert die neue Root CA.
$UI.BtnSaveRootCA.Add_Click({
    try {
        # Validierung der Passwortfelder
        $pass1 = $UI.PwdRootPass.Password
        $pass2 = $UI.PwdRootPassConfirm.Password

        if ([string]::IsNullOrWhiteSpace($pass1)) {
            [System.Windows.MessageBox]::Show("Bitte gib das Passwort der Root-CA ein.", "Validierungsfehler", "OK", "Warning")
            return
        }

        if ($pass1 -ne $pass2) {
            [System.Windows.MessageBox]::Show("Die eingegebenen Passwörter stimmen nicht überein!", "Validierungsfehler", "OK", "Error")
            return
        }

        # Parameter aus den Formularfeldern der GUI auslesen (inkl. eventuell geänderter Laufzeit/Subj-Daten)
        $params = @{
            CommonName   = $UI.TxtRootCn.Text
            Organization = $UI.TxtRootOrg.Text
            OU           = $UI.TxtRootOu.Text
            Country      = $UI.TxtRootCountry.Text
            State        = $UI.TxtRootState.Text
            Locality     = $UI.TxtRootLocality.Text
            ValidityDays = [int]$UI.TxtRootDays.Text
            KeyAlgorithm = if ($UI.CmbRootAlgorithm -and $UI.CmbRootAlgorithm.Text) { $UI.CmbRootAlgorithm.Text } else { "RSA" }
            KeyLength    = if ($UI.CmbRootKeyLength -and $UI.CmbRootKeyLength.Text) { $UI.CmbRootKeyLength.Text } else { "4096" }
            BaseFilename = $UI.TxtRootBaseFilename.Text.Trim()
        }

        # Unterscheidung zwischen Neuerstellung und Erneuerung (Renew)
        if ($global:IsRootRenewMode) {
            # 1. OpenSSL Renew mit den ggf. neu eingestellten Parametern ausführen
            New-RootCA -Password $pass1 -Params $params -Renew
            $msgSuccess = "Root-CA wurde erfolgreich mit den neuen Parametern erneuert!"
        } else {
            # 1. Neue Root-CA erstellen
            New-RootCA -Password $pass1 -Params $params
            $msgSuccess = "Root-CA wurde erfolgreich mit OpenSSL erstellt!"
        }

        # 2. Geänderte Daten in die Config übernehmen
        $global:Config.defaults.root_ca.base_filename = $params.BaseFilename
        $global:Config.defaults.root_ca.common_name   = $params.CommonName
        $global:Config.defaults.root_ca.ou            = $params.OU
        $global:Config.defaults.root_ca.validity_days = $params.ValidityDays
        $global:Config.defaults.root_ca.key_algorithm = $params.KeyAlgorithm
        $global:Config.defaults.root_ca.key_length    = [int]$params.KeyLength
        $global:Config.defaults.organization          = $params.Organization
        $global:Config.defaults.country               = $params.Country
        $global:Config.defaults.state                 = $params.State
        $global:Config.defaults.locality              = $params.Locality
        
        # 3. Konfiguration auf der Festplatte speichern (config.yaml)
        Save-ConfigToFile

        # 4. GUI & Status zurücksetzen
        $global:IsRootRenewMode           = $false
        $UI.TxtRootBaseFilename.IsEnabled = $true
        $UI.CmbRootAlgorithm.IsEnabled    = $true
        $UI.CmbRootKeyLength.IsEnabled    = $true

        $UI.TxtRootCaTitle.Text           = "Neue Root-CA Erstellen"
        $UI.BtnSaveRootCA.Content         = "🔐 Root-CA Erstellen"

        Update-DashboardStatus

        # Zurück zum Dashboard
        $UI.MainTabControl.SelectedItem = $UI.TabDashboard
        [System.Windows.MessageBox]::Show($msgSuccess, "Erfolg", "OK", "Information")
    } catch {
        [System.Windows.MessageBox]::Show("Fehler beim Verarbeiten der Root-CA:`n$($_.Exception.Message)", "Fehler", "OK", "Error")
    }
})

# Stößt die Verlängerung/Erneuerung der bestehenden Root CA an.
$UI.BtnRenewRootCA.Add_Click({
    # Modus auf Erneuerung setzen
    $global:IsRootRenewMode = $true
    
    # Formularfelder mit aktuellen Werten aus der Config vorbelegen
    LoadConfigToForm
    
    # Passwort-Felder zurücksetzen
    $UI.PwdRootPass.Password = ""
    $UI.PwdRootPassConfirm.Password = ""
    
    # Button-Text und Überschrift für den Renew-Kontext anpassen
    $UI.TxtRootCaTitle.Text   = "Root-CA Erneuern / Verlängern"
    $UI.BtnSaveRootCA.Content = "🔄 Root-CA Erneuern & Speichern"
    
    # Schlüssel-Parameter sperren (bei Renew von bestehendem Key/Cert sollten Algorithmus & Filename gleich bleiben)
    $UI.TxtRootBaseFilename.IsEnabled = $false
    $UI.CmbRootAlgorithm.IsEnabled    = $false
    $UI.CmbRootKeyLength.IsEnabled    = $false
    
    # Zum Erstellungs-/Erneuerungs-Tab wechseln
    $UI.MainTabControl.SelectedItem = $UI.TabCreateRootCA
    $UI.TxtStatus.Text = "Root-CA Daten für Erneuerung anpassen..."
})

# Bricht die Erstellung/Bearbeitung der Root CA ab und schließt die Ansicht.
$UI.BtnCancelRootCA.Add_Click({
    $global:IsRootRenewMode = $false
    $UI.TxtRootBaseFilename.IsEnabled = $true
    $UI.CmbRootAlgorithm.IsEnabled    = $true
    $UI.CmbRootKeyLength.IsEnabled    = $true

    $UI.TxtRootCaTitle.Text           = "Neue Root-CA Erstellen"
    $UI.BtnSaveRootCA.Content         = "🔐 Root-CA Erstellen"

    $UI.MainTabControl.SelectedItem = $UI.TabDashboard
    $UI.TxtStatus.Text = "Bereit."
})

# Öffnet das Formular zur Erstellung einer Intermediate CA.
$UI.BtnShowCreateIntermediate.Add_Click({
    $UI.MainTabControl.SelectedItem = $UI.TabCreateIntermediate
    $UI.TxtStatus.Text = "Intermediate-CA Konfiguration..."
})

# Speichert die Konfiguration und generiert die Intermediate CA.
$UI.BtnSaveIntermediate.Add_Click({
    try {
        # Root-Passwort zur Signierung per Dialog abfragen
        $rootPass = Show-PasswordDialog -Title "Root-CA Passwort erforderlich" -Prompt "Gib das Passwort der Root-CA ein, um die Intermediate-CA zu signieren:"
        if ([string]::IsNullOrWhiteSpace($rootPass)) { return }

        # Optionales Passwort der Intermediate CA direkt aus der GUI lesen
        $interPass1 = $UI.PwdInterPass.Password
        $interPass2 = $UI.PwdInterPassConfirm.Password

        if ($interPass1 -ne $interPass2) {
            [System.Windows.MessageBox]::Show("Die eingegebenen Intermediate-CA Passwörter stimmen nicht überein!", "Validierungsfehler", "OK", "Error")
            return
        }

        # Parameter aus den Formularfeldern der GUI auslesen
        $params = @{
            CommonName   = $UI.TxtInterCn.Text
            Organization = $UI.TxtInterOrg.Text
            OU           = if ($TxtInterOu) { $TxtInterOu.Text } else { $global:Config.defaults.organization }
            Country      = $global:Config.defaults.country
            State        = $global:Config.defaults.state
            Locality     = $global:Config.defaults.locality
            ValidityDays = [int]$UI.TxtInterDays.Text
            KeyAlgorithm = if ($UI.CmbInterAlgorithm -and $UI.CmbInterAlgorithm.Text) { $UI.CmbInterAlgorithm.Text } else { "RSA" }
            KeyLength    = if ($UI.CmbInterKeyLength -and $UI.CmbInterKeyLength.Text) { $UI.CmbInterKeyLength.Text } else { "2048" }
            PathLen      = if ($UI.TxtInterPathLen.Text) { [int]$UI.TxtInterPathLen.Text } else { 0 }
            BaseFilename = $UI.TxtInterBaseFilename.Text.Trim()
        }

        # Unterscheidung zwischen Neuerstellung und Erneuerung (Renew)
        if ($global:IsInterRenewMode) {
            New-IntermediateCA -RootPassword $rootPass -IntermediatePassword $interPass1 -Params $params -Renew
            $msgSuccess = "Intermediate-CA wurde erfolgreich mit den neuen Parametern erneuert!"
        } else {
            New-IntermediateCA -RootPassword $rootPass -IntermediatePassword $interPass1 -Params $params
            $msgSuccess = "Intermediate-CA wurde erfolgreich erstellt und von der Root-CA signiert!"
        }

        # Config-Werte mit den ggf. angepassten Daten aktualisieren
        $global:Config.defaults.intermediate_ca.base_filename = $params.BaseFilename
        $global:Config.defaults.intermediate_ca.common_name   = $params.CommonName
        $global:Config.defaults.intermediate_ca.ou            = $params.OU
        $global:Config.defaults.intermediate_ca.validity_days = $params.ValidityDays
        $global:Config.defaults.intermediate_ca.key_algorithm = $params.KeyAlgorithm
        $global:Config.defaults.intermediate_ca.key_length    = [int]$params.KeyLength
        $global:Config.defaults.intermediate_ca.pathlen       = $params.PathLen
        $global:Config.defaults.intermediate_ca.has_password  = (-not [string]::IsNullOrWhiteSpace($interPass1))

        # Konfiguration speichern und UI aktualisieren
        Save-ConfigToFile

        # Modus & Steuerelemente zurücksetzen
        $global:IsInterRenewMode           = $false
        $UI.TxtInterBaseFilename.IsEnabled = $true
        $UI.CmbInterAlgorithm.IsEnabled    = $true
        $UI.CmbInterKeyLength.IsEnabled    = $true

        $UI.TxtInterCaTitle.Text           = "Neue Intermediate-CA Erstellen"
        $UI.BtnSaveIntermediate.Content    = "🔑 Intermediate-CA Erstellen"

        Update-DashboardStatus

        # Zurück zum Dashboard
        $UI.MainTabControl.SelectedItem = $UI.TabDashboard
        [System.Windows.MessageBox]::Show($msgSuccess, "Erfolg", "OK", "Information")
    } catch {
        [System.Windows.MessageBox]::Show("Fehler beim Verarbeiten der Intermediate-CA:`n$($_.Exception.Message)", "Fehler", "OK", "Error")
    }
})

# Stößt die Verlängerung/Erneuerung der Intermediate CA an.
$UI.BtnRenewIntermediate.Add_Click({
    # Modus auf Erneuerung setzen
    $global:IsInterRenewMode = $true

    # Formularfelder mit aktuellen Werten aus der Config vorbelegen
    LoadConfigToForm

    # Passwort-Felder zurücksetzen
    $UI.PwdInterPass.Password = ""
    $UI.PwdInterPassConfirm.Password = ""

    # Titel und Button-Text für den Renew-Kontext anpassen
    if ($UI.TxtInterCaTitle) { $UI.TxtInterCaTitle.Text = "Intermediate-CA Erneuern / Verlängern" }
    $UI.BtnSaveIntermediate.Content = "🔄 Intermediate-CA Erneuern & Speichern"

    # Unveränderliche Schlüssel-Parameter beim Renew sperren
    $UI.TxtInterBaseFilename.IsEnabled = $false
    $UI.CmbInterAlgorithm.IsEnabled    = $false
    $UI.CmbInterKeyLength.IsEnabled    = $false

    # Zum Erstellungs-/Erneuerungs-Tab wechseln
    $UI.MainTabControl.SelectedItem = $UI.TabCreateIntermediate
    $UI.TxtStatus.Text = "Intermediate-CA Daten für Erneuerung anpassen..."
})

# Bricht die Erstellung/Bearbeitung der Intermediate CA ab.
$UI.BtnCancelIntermediate.Add_Click({
    $global:IsInterRenewMode           = $false
    $UI.TxtInterBaseFilename.IsEnabled = $true
    $UI.CmbInterAlgorithm.IsEnabled    = $true
    $UI.CmbInterKeyLength.IsEnabled    = $true

    # Titel und Button auf Standard zurücksetzen
    $UI.TxtInterCaTitle.Text           = "Neue Intermediate-CA Erstellen"
    $UI.BtnSaveIntermediate.Content    = "🔑 Intermediate-CA Erstellen"

    $UI.MainTabControl.SelectedItem    = $UI.TabDashboard
    $UI.TxtStatus.Text                 = "Bereit."
})

# --- 13. Service Certificate Management (Aktionen für die Erstellung, Speicherung und das Stornieren von Endbenutzer-/Service-Zertifikaten.) ---
# Öffnet den Dialog/die Maske zur Erstellung eines neuen Service-Zertifikats.
$UI.BtnNewService.Add_Click({
    $UI.MainTabControl.SelectedItem = $UI.TabNewService
    $UI.TxtStatus.Text = "Neues Service-Zertifikat..."
})

# Globaler Menü-/Shortcuttag zum Anlegen eines neuen Service-Zertifikats.
$UI.MenuGlobalNewService.Add_Click({
    $UI.BtnNewService.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
})

# Generiert und speichert das neue Service-Zertifikat ab.
$UI.BtnSaveNewService.Add_Click({
    try {
        # 1. Validierung
        if ([string]::IsNullOrWhiteSpace($UI.TxtServiceCn.Text)) {
            [System.Windows.MessageBox]::Show("Bitte gib einen Common Name (CN) ein.", "Validierungsfehler", "OK", "Warning")
            return
        }

        # 2. CA-Passwortabfrage basierend auf PKI-Status
        $pkiState = Get-SystemPkiState
        $useInter = ($null -ne $pkiState.IntermediateCA -and $pkiState.IntermediateCA.Status -ne "Defekt")
        $caPass   = $null

        if ($useInter) {
            # Es soll die Intermediate-CA genutzt werden
            if ($pkiState.IntermediateHasPass) {
                $caPass = Show-PasswordDialog -Title "Intermediate-CA Passwort" -Prompt "Gib das Passwort der Intermediate-CA ein:"
                if ([string]::IsNullOrWhiteSpace($caPass)) { return }
            }
            # Wenn IntermediateHasPass $false ist, bleibt $caPass einfach $null/leer und es gibt kein Popup!
        } else {
            # Es soll direkt die Root-CA genutzt werden
            if ($pkiState.RootHasPass) {
                $caPass = Show-PasswordDialog -Title "Root-CA Passwort" -Prompt "Gib das Passwort der Root-CA ein:"
                if ([string]::IsNullOrWhiteSpace($caPass)) { return }
            }
        }

        # NEU: 2b. Optionales PFX-Passwort abfragen, wenn PFX-Export aktiviert ist
        $pfxPass = $null
        if ($UI.ChkExportPfx -and $UI.ChkExportPfx.IsChecked) {
            $pfxPass = Show-PasswordDialog -Title "PFX Passwort vergeben" -Prompt "Passwort für die PFX-Datei eingeben (Leer lassen für kein Passwort):"
            # Falls der Benutzer den Dialog abgebrochen hat (Cancel)
            if ($null -eq $pfxPass) { return }
        }

        # 3. SANs aufbereiten
        $dnsInput = if ($UI.TxtServiceDnsSANs) { $UI.TxtServiceDnsSANs.Text } else { "" }
        $dnsList  = $dnsInput.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

        $ipInput  = if ($UI.TxtServiceIpSANs)  { $UI.TxtServiceIpSANs.Text }  else { "" }
        $ipList   = $ipInput.Split(',')  | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

        # 4. Key Usages sammeln
        $selectedKeyUsages = @()
        if ($UI.ChkKuDigitalSignature -and $UI.ChkKuDigitalSignature.IsChecked) { $selectedKeyUsages += "digitalSignature" }
        if ($UI.ChkKuKeyEncipherment  -and $UI.ChkKuKeyEncipherment.IsChecked)  { $selectedKeyUsages += "keyEncipherment" }
        if ($UI.ChkKuDataEncipherment -and $UI.ChkKuDataEncipherment.IsChecked) { $selectedKeyUsages += "dataEncipherment" }
        if ($UI.ChkKuKeyAgreement     -and $UI.ChkKuKeyAgreement.IsChecked)     { $selectedKeyUsages += "keyAgreement" }

        # 5. Algorithmus, Schlüssellänge & EKU-Mapping
        $keyAlgo = if ($UI.CmbServiceAlgorithm -and $UI.CmbServiceAlgorithm.Text) { $UI.CmbServiceAlgorithm.Text } else { "RSA" }
        $keyLen  = if ($UI.CmbServiceKeyLength -and $UI.CmbServiceKeyLength.Text) { $UI.CmbServiceKeyLength.Text } else { "2048" }
        # Welches EKU-Label gewählt wurde (behält den langen GUI-String bei)
        $ekuText = if ($UI.CmbServiceEku -and $UI.CmbServiceEku.Text) { $UI.CmbServiceEku.Text } else { "TLS Web Server Authentication (serverAuth)" }

        # 6. Export-Optionen
        $exportsMap = [ordered]@{
            pfx       = [bool]$UI.ChkExportPfx.IsChecked
            crt       = [bool]$UI.ChkExportCrt.IsChecked
            key       = [bool]$UI.ChkExportKey.IsChecked
            pem_cert  = [bool]$UI.ChkExportPemOnly.IsChecked
            pem_full  = [bool]$UI.ChkExportPemFull.IsChecked
            chain     = [bool]$UI.ChkExportChain.IsChecked
            fullchain = [bool]$UI.ChkExportFullChain.IsChecked
        }

        # 7. Parameter-Hashtable aufbauen
        $params = @{
            DisplayName  = if ($UI.TxtServiceDisplayName) { $UI.TxtServiceDisplayName.Text } else { $UI.TxtServiceCn.Text }
            CommonName   = $UI.TxtServiceCn.Text
            OU           = $UI.TxtServiceOu.Text
            SANsDNS      = $dnsList
            SANsIP       = $ipList
            EKU          = $ekuText
            KeyUsages    = $selectedKeyUsages
            KeyAlgorithm = $keyAlgo
            KeyLength    = $keyLen
            ValidityDays = [int]$UI.TxtServiceDays.Text
            Exports      = $exportsMap
        }

        # 8. Splatting vorbereiten & New-ServiceCertificate aufrufen
        $splat = @{
            Params = $params
        }
        if ($caPass)  { $splat['CaPassword']  = $caPass }
        if ($pfxPass) { $splat['PfxPassword'] = $pfxPass } # Pass-Through an New-ServiceCertificate

        # OpenSSL-Funktion aufrufen
        New-ServiceCertificate @splat

        # 9. Soll-Eintrag in config.yaml aktualisieren
        $newEntry = [ordered]@{
            display_name  = $params.DisplayName
            common_name   = $params.CommonName
            ou            = $params.OU
            eku           = $params.EKU
            validity_days = $params.ValidityDays
            key_algorithm = $params.KeyAlgorithm
            key_length    = $params.KeyLength
            key_usages    = $params.KeyUsages
            exports       = $params.Exports
            sans_dns      = $params.SANsDNS
            sans_ip       = $params.SANsIP
        }

        if ($null -eq $global:Config.service_certificates) {
            $global:Config.service_certificates = @()
        }

        # Aktualisieren falls vorhanden, ansonsten neu anhängen
        $existingIdx = -1
        for ($i = 0; $i -lt $global:Config.service_certificates.Count; $i++) {
            if ($global:Config.service_certificates[$i].common_name -eq $params.CommonName) {
                $existingIdx = $i
                break
            }
        }

        if ($existingIdx -ge 0) {
            $global:Config.service_certificates[$existingIdx] = $newEntry
        } else {
            $global:Config.service_certificates += $newEntry
        }

        # 10. Konfiguration speichern & UI zurücksetzen
        Save-ConfigToFile

        $global:IsServiceRenewMode      = $false
        $global:SelectedServiceForRenew = $null
        $UI.TxtServiceCn.IsEnabled      = $true

        $UI.TxtServiceCaTitle.Text      = "Neues Service-Zertifikat Konfigurieren"
        $UI.BtnSaveNewService.Content   = "💾 Speichern & Erzeugen"

        Update-DashboardStatus

        $UI.MainTabControl.SelectedItem = $UI.TabDashboard
        $msg = if ($global:IsServiceRenewMode) { "Service-Zertifikat '$($params.CommonName)' wurde erfolgreich erneuert!" } else { "Service-Zertifikat '$($params.CommonName)' wurde erfolgreich erstellt!" }
        [System.Windows.MessageBox]::Show($msg, "Erfolg", "OK", "Information")

    } catch {
        [System.Windows.MessageBox]::Show("Fehler beim Erstellen des Zertifikats:`n$($_.Exception.Message)", "Fehler", "OK", "Error")
    }
})

# Bricht die Eingabe für das Service-Zertifikat ab.
$UI.BtnCancelNewService.Add_Click({
    $global:IsServiceRenewMode      = $false
    $global:SelectedServiceForRenew = $null
    $UI.TxtServiceCn.IsEnabled      = $true

    $UI.TxtServiceCaTitle.Text      = "Neues Service-Zertifikat Konfigurieren"
    $UI.BtnSaveNewService.Content   = "💾 Speichern & Erzeugen"

    $UI.MainTabControl.SelectedItem = $UI.TabDashboard
    $UI.TxtStatus.Text = "Bereit."
})

# --- 14. Grid & Context Menu Actions (Aktionen, die direkt über das Datagrid oder dessen Kontextmenü für bestehende Zertifikate aufgerufen werden.) ---
# Dynamisches Befüllen oder Validieren des Kontextmenüs vor dem Anzeigen.
$UI.GridServices.Add_ContextMenuOpening({
    $selected = $UI.GridServices.SelectedItem

    # Globale Menüpunkte konfigurieren
    $UI.MenuGlobalNewService.IsEnabled = $UI.BtnNewService.IsEnabled
    $UI.MenuGlobalRenewDue.IsEnabled   = $UI.BtnRenewDue.IsEnabled

    # Standardzustand setzen
    $UI.MenuMainAction.IsEnabled   = $false
    $UI.MenuShowDetails.IsEnabled  = $false
    $UI.MenuExportCustom.IsEnabled = $false
    $UI.MenuAdoptOrphan.IsEnabled  = $false
    $UI.MenuDeleteCert.IsEnabled   = $false

    if (-not $selected) { return }

    # Dynamische Logik je nach Zertifikatsstatus
    switch ($selected.Status) {
        "Gültig" {
            $UI.MenuMainAction.Header      = "Manuell erneuern (Force Renew)"
            $UI.MenuMainAction.IsEnabled   = $true
            $UI.MenuShowDetails.IsEnabled  = $true
            $UI.MenuExportCustom.IsEnabled = $true
            $UI.MenuDeleteCert.IsEnabled   = $true
        }
        "Warnung" {
            $UI.MenuMainAction.Header      = "Zertifikat erneuern"
            $UI.MenuMainAction.IsEnabled   = $true
            $UI.MenuShowDetails.IsEnabled  = $true
            $UI.MenuExportCustom.IsEnabled = $true
            $UI.MenuDeleteCert.IsEnabled   = $true
        }
        "Kritisch" {
            $UI.MenuMainAction.Header      = "Zertifikat erneuern"
            $UI.MenuMainAction.IsEnabled   = $true
            $UI.MenuShowDetails.IsEnabled  = $true
            $UI.MenuExportCustom.IsEnabled = $true
            $UI.MenuDeleteCert.IsEnabled   = $true
        }
        "Abgelaufen" {
            $UI.MenuMainAction.Header      = "Zertifikat erneuern (Re-issue)"
            $UI.MenuMainAction.IsEnabled   = $true
            $UI.MenuShowDetails.IsEnabled  = $true
            $UI.MenuExportCustom.IsEnabled = $true
            $UI.MenuDeleteCert.IsEnabled   = $true
        }
        "Defekt" {
            $UI.MenuMainAction.Header      = "Reparieren (Unter aktiver CA neu ausstellen)"
            $UI.MenuMainAction.IsEnabled   = $true
            $UI.MenuShowDetails.IsEnabled  = $true
            $UI.MenuDeleteCert.IsEnabled   = $true
        }
        "Fehlt" {
            $UI.MenuMainAction.Header      = "Zertifikat erstmals ausstellen"
            $UI.MenuMainAction.IsEnabled   = $true
            $UI.MenuDeleteCert.IsEnabled   = $true
        }
        "Orphan" {
            $UI.MenuMainAction.Header      = "Nicht konfiguriert"
            $UI.MenuAdoptOrphan.IsEnabled  = $true
            $UI.MenuDeleteCert.IsEnabled   = $true
        }
    }
})

# Öffnet die Detailansicht des ausgewählten Zertifikats.
$UI.MenuShowDetails.Add_Click({
    $selected = $UI.GridServices.SelectedItem
    if (-not $selected) { return }

    $detailsText = @"
Anzeigename:
$($selected.DisplayName)

Common Name:
$($selected.CommonName)

Status:
$($selected.Status)

Ausstellende CA:
$($selected.IssuerCommonName)

Gültig bis:
$($selected.ExpiryDate)

Resttage:
$($selected.DaysRemaining)

EKU:
$($selected.EKU)

SANs:
$($selected.SANs)

Issuer:
$($selected.Issuer)

Subject:
$($selected.Subject)

Seriennummer:
$($selected.SerialNumber)

Thumbprint:
$($selected.Thumbprint)
"@
    [System.Windows.MessageBox]::Show($detailsText, "Zertifikats-Details", "OK", "Information")
})

# Öffnet den Dialog zum benutzerdefinierten Export (z. B. PFX, CER, PEM).
$UI.MenuExportCustom.Add_Click({
    $selected = $UI.GridServices.SelectedItem
    if (-not $selected) { return }

    $certDir = Get-AbsolutePath $global:Config.paths.certs_directory
    $caDir   = Get-AbsolutePath $global:Config.paths.ca_directory
    $safeFileName = $selected.CommonName -replace '[^a-zA-Z0-9\.-]', '_'

    $svcCrtPath = Join-Path $certDir "$safeFileName.crt"
    $svcKeyPath = Join-Path $certDir "$safeFileName.key"

    # Speichern-Dialog mit allen Formaten inkl. Private Key
    $saveFileDialog = New-Object Microsoft.Win32.SaveFileDialog
    $saveFileDialog.InitialDirectory = $certDir
    $saveFileDialog.FileName = "$safeFileName"
    $saveFileDialog.Filter = "PEM / CRT Zertifikat (*.crt;*.pem)|*.crt;*.pem|" +
                             "Private Key (*.key)|*.key|" +
                             "PFX / PKCS#12 Container (*.pfx)|*.pfx|" +
                             "PEM inkl. Key (*.full.pem)|*.full.pem|" +
                             "Fullchain Zertifikat (*.fullchain.crt)|*.fullchain.crt|" +
                             "CA-Chain (*.chain.crt)|*.chain.crt|" +
                             "Alle Dateien (*.*)|*.*"
    $saveFileDialog.Title = "Zertifikat in beliebigem Format exportieren"

    if ($saveFileDialog.ShowDialog() -eq $true) {
        $targetPath  = $saveFileDialog.FileName
        $filterIndex = $saveFileDialog.FilterIndex

        try {
            # Unterzeichner-CA ermitteln (für Chains / PFX)
            $pkiState = Get-SystemPkiState
            $useInter = ($null -ne $pkiState.IntermediateCA -and$pkiState.IntermediateCA.Status -ne "Defekt")
            if ($useInter) {
                $interBase = if ($global:Config.defaults.intermediate_ca.base_filename) {
                    $global:Config.defaults.intermediate_ca.base_filename
                } else { "IntermediateCA" }
                $signingCrtPath = Join-Path $caDir "$interBase.crt"
            } else {
                $rootBase = if ($global:Config.defaults.root_ca.base_filename) {
                    $global:Config.defaults.root_ca.base_filename
                } else { "RootCA" }
                $signingCrtPath = Join-Path $caDir "$rootBase.crt"
            }

            switch ($filterIndex) {
                1 { 
                    # Reines Zertifikat (.crt / .pem)
                    if (-not (Test-Path $svcCrtPath)) { throw "Zertifikatsdatei ($safeFileName.crt) fehlt." }
                    Copy-Item -Path $svcCrtPath -Destination $targetPath -Force
                }
                2 { 
                    # Nur Private Key (.key)
                    if (-not (Test-Path $svcKeyPath)) { throw "Der private Schlüssel ($safeFileName.key) fehlt im Ordner." }
                    Copy-Item -Path $svcKeyPath -Destination $targetPath -Force
                }
                3 { 
                    # PFX Container (.pfx)
                    if (-not (Test-Path $svcCrtPath)) { throw "Zertifikatsdatei ($safeFileName.crt) fehlt." }
                    if (-not (Test-Path $svcKeyPath)) { throw "Der private Schlüssel ($safeFileName.key) fehlt." }
                    
                    $pfxPass = Show-PasswordDialog -Title "PFX Passwort" -Prompt "Passwort für PFX-Export eingeben (Leer lassen für kein Passwort):"
                    if ($null -eq $pfxPass) { return }

                    $pfxPassArg = if (-not [string]::IsNullOrWhiteSpace($pfxPass)) { "pass:$pfxPass" } else { "pass:" }
                    
                    $pfxArgs = @(
                        "pkcs12", "-export",
                        "-out", $targetPath,
                        "-inkey", $svcKeyPath,
                        "-in", $svcCrtPath,
                        "-passin", "pass:",
                        "-passout", $pfxPassArg
                    )
                    if (Test-Path $signingCrtPath) {
                        $pfxArgs += @("-certfile", $signingCrtPath)
                    }

                    Invoke-OpenSSL -Arguments $pfxArgs | Out-Null
                }
                4 { 
                    # Full PEM (Zertifikat + Key in einer Datei)
                    if (-not (Test-Path $svcCrtPath)) { throw "Zertifikatsdatei ($safeFileName.crt) fehlt." }
                    if (-not (Test-Path $svcKeyPath)) { throw "Der private Schlüssel ($safeFileName.key) fehlt." }

                    $crtText = Get-Content -Path $svcCrtPath -Raw
                    $keyText = Get-Content -Path $svcKeyPath -Raw
                    Set-Content -Path $targetPath -Value "$crtText`n$keyText" -Encoding UTF8
                }
                5 { 
                    # Fullchain (Zertifikat + Signing CA)
                    if (-not (Test-Path $svcCrtPath)) { throw "Zertifikatsdatei ($safeFileName.crt) fehlt." }
                    $crtText = Get-Content -Path $svcCrtPath -Raw
                    $caText  = if (Test-Path $signingCrtPath) { Get-Content -Path $signingCrtPath -Raw } else { "" }
                    Set-Content -Path $targetPath -Value "$crtText`n$caText" -Encoding UTF8
                }
                6 { 
                    # Nur CA-Chain
                    if (Test-Path $signingCrtPath) {
                        Copy-Item -Path $signingCrtPath -Destination $targetPath -Force
                    } else {
                        throw "Kein CA-Zertifikat für Chain-Export gefunden."
                    }
                }
            }

            [System.Windows.MessageBox]::Show("Datei erfolgreich exportiert nach:`n$targetPath", "Export erfolgreich", "OK", "Information")
        } catch {
            [System.Windows.MessageBox]::Show("Fehler beim Exportieren:`n$($_.Exception.Message)", "Exportfehler", "OK", "Error")
        }
    }
})

# Verknüpft eine verwaiste Zertifikatsdatei/Ordner wieder mit der Anwendungslogik.
$UI.MenuAdoptOrphan.Add_Click({
    $selected = $UI.GridServices.SelectedItem
    if (-not $selected -or $selected.Status -ne "Orphan") { return }

    $sansList = $selected.SANs -split ", "
    $sansDns  = @($sansList | Where-Object { $_ -notmatch '^\d+\.\d+\.\d+\.\d+$' -and $_ -ne "" })
    $sansIp   = @($sansList | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })

    # Standardwerte aus $global:Config.defaults.services als Fallback laden
    $defaultSvc = $global:Config.defaults.services

    # EKU bereinigen (falls der Text aus dem Grid z. B. "Unbekannt (Orphan)" lautet)
    $ekuVal = if ($selected.EKU -and $selected.EKU -notmatch "Unbekannt") { 
        $selected.EKU 
    } else { 
        if ($defaultSvc.default_eku) { $defaultSvc.default_eku } else { "TLS Web Server Authentication (serverAuth)" }
    }

    $newSvc = [ordered]@{
        display_name  = $selected.CommonName
        common_name   = $selected.CommonName
        eku           = $ekuVal
        validity_days = if ($defaultSvc.validity_days) { [int]$defaultSvc.validity_days } else { 365 }
        key_algorithm = if ($defaultSvc.key_algorithm) { $defaultSvc.key_algorithm } else { "RSA" }
        key_length    = if ($defaultSvc.key_length) { [int]$defaultSvc.key_length } else { 2048 }
        key_usages    = @("digitalSignature", "keyEncipherment")
        exports       = if ($defaultSvc.exports) { $defaultSvc.exports } else {
            [ordered]@{
                pfx       = $false
                crt       = $true
                key       = $true
                pem_cert  = $false
                pem_full  = $false
                chain     = $false
                fullchain = $false
            }
        }
        sans_dns      = $sansDns
        sans_ip       = $sansIp
    }

    if ($null -eq $global:Config.service_certificates) {
        $global:Config.service_certificates = @()
    }

    $global:Config.service_certificates += $newSvc
    Save-ConfigToFile
    
    Update-DashboardStatus
    [System.Windows.MessageBox]::Show("Zertifikat '$($selected.CommonName)' wurde erfolgreich mit vollständigen Parametern in die config.yaml übernommen!", "Erfolg", "OK", "Information")
})

# Löscht das ausgewählte Zertifikat aus der Verwaltung/dem Dateisystem.
$UI.MenuDeleteCert.Add_Click({
    $selected = $UI.GridServices.SelectedItem
    if (-not $selected) { return }

    $confirm = [System.Windows.MessageBox]::Show(
        "Möchtest du die Zertifikatsdateien und den Konfigurationseintrag für '$($selected.CommonName)' wirklich unwiderruflich löschen?",
        "Datei löschen bestätigen",
        "YesNo",
        "Warning"
    )

    if ($confirm -eq "Yes") {
        $certDir = Get-AbsolutePath $global:Config.paths.certs_directory
        $safeFileName = $selected.CommonName -replace '[^a-zA-Z0-9\.-]', '_'

        Remove-Item (Join-Path $certDir "$safeFileName.key") -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $certDir "$safeFileName.csr") -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $certDir "$safeFileName.crt") -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $certDir "$safeFileName.pfx") -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $certDir "$safeFileName.pem") -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $certDir "$safeFileName.full.pem") -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $certDir "$safeFileName.chain.crt") -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $certDir "$safeFileName.fullchain.crt") -ErrorAction SilentlyContinue

        $global:Config.service_certificates = @($global:Config.service_certificates | Where-Object { $_.common_name -ne $selected.CommonName })
        Save-ConfigToFile
        Update-DashboardStatus
    }
})

# Führt die konfigurierte Standard-Aktion für den ausgewählten Eintrag aus.
$UI.MenuMainAction.Add_Click({
    $selected = $UI.GridServices.SelectedItem
    if (-not $selected -or -not $UI.MenuMainAction.IsEnabled) { return }

    # Gewähltes Zertifikat merken & Modus setzen
    $global:SelectedServiceForRenew = $selected
    $global:IsServiceRenewMode      = $true

    # Daten des ausgewählten Zertifikats ins Formular laden
    LoadServiceCertToForm -ServiceItem $selected

    # Titel & Button für Renew-Modus anpassen
    $UI.TxtServiceCaTitle.Text = "Service-Zertifikat Bearbeiten & Erneuern"
    $UI.BtnSaveNewService.Content = "🔄 Zertifikat Erneuern & Speichern"

    # Common Name darf bei bestehendem Eintrags-Renew nicht geändert werden (dient als Primary Key)
    $UI.TxtServiceCn.IsEnabled = $false

    # Zum Formular-Tab wechseln
    $UI.MainTabControl.SelectedItem = $UI.TabNewService
    $UI.TxtStatus.Text = "Zertifikat '$($selected.CommonName)' bearbeiten..."
})

# --- 15. Bulk & Maintenance Operations (Aktionen zur Stapelverarbeitung und automatischen Erneuerung von ablaufenden Zertifikaten.) ---
# Stößt die automatische Erneuerung aller fälligen Service-Zertifikate an.
$UI.BtnRenewDue.Add_Click({
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
        if ($useInter) {
            # Intermediate-CA wird verwendet: Nur fragen, wenn sie ein Passwort hat
            if ($pkiState.IntermediateHasPass) {
                $caPass = Show-PasswordDialog -Title "Intermediate-CA Passwort" -Prompt "Gib das Passwort der Intermediate-CA ein:"
                if ([string]::IsNullOrWhiteSpace($caPass)) { return }
            }
        } else {
            # Root-CA wird verwendet: Nur fragen, wenn sie ein Passwort hat
            if ($pkiState.RootHasPass) {
                $caPass = Show-PasswordDialog -Title "Root-CA Passwort" -Prompt "Gib das Passwort der Root-CA ein:"
                if ([string]::IsNullOrWhiteSpace($caPass)) { return }
            }
        }

        # Ausführen der Re-Issue Engine
        Repair-ServiceCertificates -CertificatesToRepair $toRepair -CaPassword $caPass

        Update-DashboardStatus
        $UI.TxtStatus.Text = "Reparatur abgeschlossen: $($toRepair.Count) Zertifikat(e) neu ausgestellt."
        [System.Windows.MessageBox]::Show("$($toRepair.Count) Zertifikat(e) wurden erfolgreich repariert / neu ausgestellt!", "Erfolg", "OK", "Information")

    } catch {
        [System.Windows.MessageBox]::Show("Fehler bei der Reparatur:`n$($_.Exception.Message)", "Fehler", "OK", "Error")
    }
})

# Globaler Menüpunkt zum Auslösen der Stapelerneuerung fälliger Zertifikate.
$UI.MenuGlobalRenewDue.Add_Click({
    $UI.BtnRenewDue.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
})

# --- 16. Configuration & View Navigation (Aktionen zur Steuerung der Anwendungs-Einstellungen sowie zum Import/Export der Konfiguration.) ---
# Öffnet die Einstellungs-Ansicht / den Konfigurations-Tab.
$UI.BtnOpenConfig.Add_Click({
    Update-ConfigTabState
    $UI.MainTabControl.SelectedItem = $UI.TabConfig
    $UI.TxtStatus.Text = "Config-Editor geöffnet." 
})

# Verlässt die Konfigurations-Ansicht und kehrt zum Haupt-Dashboard zurück.
$UI.BtnBackFromConfig.Add_Click({
    $UI.MainTabControl.SelectedItem = $UI.TabDashboard
    $UI.TxtStatus.Text = "Bereit."
})

# Exportiert die aktuelle Konfiguration (YAML/JSON) in eine Datei.
$UI.BtnExportConfig.Add_Click({
    $saveFileDialog = New-Object Microsoft.Win32.SaveFileDialog
    $saveFileDialog.Filter = "YAML-Dateien (*.yaml;*.yml)|*.yaml;*.yml|Alle Dateien (*.*)|*.*"
    $saveFileDialog.FileName = "config.yaml"
    $saveFileDialog.Title = "Konfiguration exportieren"

    if ($saveFileDialog.ShowDialog() -eq $true) {
        try {
            [System.IO.File]::WriteAllText($saveFileDialog.FileName, $UI.TxtConfigEditor.Text, [System.Text.Encoding]::UTF8)
            [System.Windows.MessageBox]::Show("Konfiguration erfolgreich exportiert nach:`n$($saveFileDialog.FileName)", "Export erfolgreich", "OK", "Information")
            $UI.TxtStatus.Text = "Konfiguration exportiert."
        } catch {
            [System.Windows.MessageBox]::Show("Fehler beim Exportieren:`n$_", "Fehler", "OK", "Error")
        }
    }
})

# Importiert eine externe Konfigurationsdatei in die Anwendung.
$UI.BtnImportConfig.Add_Click({
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
            $UI.TxtStatus.Text = "Neue Konfiguration importiert."
        } catch {
            [System.Windows.MessageBox]::Show("Fehler beim Importieren oder ungültiges YAML-Format:`n$_", "Fehler", "OK", "Error")
        }
    }
})

# --- 17. ANZEIGE DER BENUTZEROBERFLÄCHE ---
$UI.window.ShowDialog() | Out-Null
