# LocalCertFactory - PKI Manager 🛡️

**LocalCertFactory** ist eine eigenständige, leichtgewichtige PowerShell- und WPF-Desktop-Anwendung zur Verwaltung einer lokalen Public Key Infrastructure (PKI) mithilfe von OpenSSL. Sie bietet eine übersichtliche, moderne Benutzeroberfläche, um Root-CAs, Intermediate-CAs und Service-/Gerätezertifikate einfach zu erstellen, zu verwalten, zu erneuern und zu exportieren – ganz ohne komplexe Befehlszeilenparameter.

## Funktionen
- **Moderne WPF-Benutzeroberfläche:** Klares Windows-Design im Stil von Microsoft Fluent Design.
- **Volle CA-Hierarchie:** Erstellung und Verwaltung von Root-CAs sowie passwortgeschützten oder passwortlosen Intermediate-CAs.
- **Service-Zertifikatsverwaltung:** Ausstellung von TLS/SSL-Server-/Client-Zertifikaten mit benutzerdefinierten SANs (Subject Alternative Names) für DNS-Namen und IP-Adressen.
- **Automatisches Lifecycle- & Ablauf-Tracking:** Visuelle Statusanzeigen (Gültig, Warnung, Kritisch, Abgelaufen, Defekt/Mismatch, Fehlt).
- **Flexible Exporte:** Export von Zertifikaten in verschiedene Formate (`.crt`, `.key`, `.pfx` / PKCS#12, `.pem`, `.full.pem`, `.chain.crt`, `.fullchain.crt`).
- **Konfigurationsbasiert:** Synchronisiert mit einer lokalen `config.yaml`-Datei für einfache Bereitstellung und Sicherung.

## Systemvoraussetzungen
- Windows 10 / 11 mit PowerShell 5.1+
- OpenSSL (wird automatisch in Standardpfaden wie Git für Windows oder Chocolatey gesucht oder kann manuell ausgewählt werden)
- PowerShell-Modul: `powershell-yaml` (wird bei Bedarf automatisch installiert)

## Erste Schritte
1. Klone oder lade das Repository auf deinen lokalen Computer herunter.
2. Stelle sicher, dass **OpenSSL** auf deinem System installiert ist (z. B. über Git für Windows).
3. Starte die Anwendung über PowerShell oder durch Ausführen des Skripts.

---
---

> 🇬🇧/🇺🇸 **english version:**

# LocalCertFactory - PKI Manager 🛡️

**LocalCertFactory** is a standalone, lightweight PowerShell & WPF desktop application designed to manage a local Public Key Infrastructure (PKI) using OpenSSL. It provides a clean, modern user interface to easily issue, track, renew, and export Root CAs, Intermediate CAs, and Service/Device certificates without dealing with complex command-line arguments.

## Features
- **Modern WPF GUI**: Clean Windows interface styled with Microsoft Fluent Design principles.
- **Full CA Hierarchy Support**: Create and manage Root CAs and password-protected or passwordless Intermediate CAs.
- **Service Certificate Management**: Issue TLS/SSL server/client certificates with custom Subject Alternative Names (SANs) for DNS names and IP addresses.
- **Automated Lifecycle & Expiry Tracking**: Visual status indicators (Valid, Warning, Critical, Expired, Broken/Mismatch, Missing).
- **Flexible Exports**: Export certificates into multiple formats (`.crt`, `.key`, `.pfx` / PKCS#12, `.pem`, `.full.pem`, `.chain.crt`, `.fullchain.crt`).
- **Configuration-Driven**: Synchronized with a local `config.yaml` file for easy deployment and backup.

## Requirements
- Windows 10 / 11 with PowerShell 5.1+
- OpenSSL (automatically searched in standard paths like Git for Windows or Chocolatey, or manually selectable)
- PowerShell module: `powershell-yaml` (will be installed automatically if missing)

## Getting Started
1. Clone or download the repository to your local machine.
2. Ensure **OpenSSL** is installed on your system (e.g., via Git for Windows).
3. Run the application via PowerShell or by executing the script.
