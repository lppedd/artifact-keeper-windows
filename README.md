# Artifact Keeper Windows Installer

> **Beta:** Windows support is currently in beta. Please report issues on [GitHub](https://github.com/artifact-keeper/artifact-keeper/issues).

PowerShell-based setup tool for deploying Artifact Keeper and its dependencies on Windows Server.

## What it installs

| Component | Source | Service Name |
|-----------|--------|--------------|
| Backend API | artifact-keeper/artifact-keeper | ArtifactKeeper |
| PostgreSQL 17 | enterprisedb.com | PostgreSQL |
| Meilisearch | meilisearch/meilisearch | Meilisearch |
| Trivy | aquasecurity/trivy | Trivy |
| Web Frontend | artifact-keeper/artifact-keeper-web | ArtifactKeeperWeb |
| Node.js (runtime) | nodejs.org | (used by frontend) |
| WinSW | winsw/winsw | (service wrapper) |

## Quick start

```powershell
# Download and run the setup script (requires Administrator)
irm https://raw.githubusercontent.com/artifact-keeper/artifact-keeper-windows/main/setup.ps1 -OutFile setup.ps1
.\setup.ps1
```

## Install options

```powershell
# Interactive (select components from menu)
.\setup.ps1

# Install everything, unattended
.\setup.ps1 -Components all -Unattended -DbPassword "changeme"

# Install only backend and PostgreSQL
.\setup.ps1 -Components backend,postgresql

# Check existing installation
.\setup.ps1 -Check

# Upgrade all components
.\setup.ps1 -Upgrade

# Custom paths
.\setup.ps1 -InstallDir "D:\ArtifactKeeper" -DataDir "D:\ArtifactKeeper\data"

# Uninstall
.\setup.ps1 -Components uninstall
```

## Silent/unattended install

For enterprise deployment via SCCM, Intune, or GPO:

```powershell
powershell.exe -ExecutionPolicy Bypass -File setup.ps1 `
    -Components all -Unattended `
    -DbPassword "s3cure-passw0rd" `
    -JwtSecret "your-64-char-secret-here" `
    -ApiPort 8080 -WebPort 3000
```

## Directory structure

```
C:\ArtifactKeeper\
    bin\
        artifact-keeper.exe
        winsw.exe
    postgresql\
        pgsql\
            bin\, lib\, share\
    meilisearch\
        meilisearch.exe
        meilisearch-service.exe
        meilisearch-service.xml
    trivy\
        trivy.exe
        trivy-service.exe
        trivy-service.xml
    nodejs\
        node.exe, npm, ...
    web\
        server.js, .next/, ...
        ArtifactKeeperWeb-service.exe
        ArtifactKeeperWeb-service.xml
    data\
        config\
            .env
        artifacts\
        pgdata\
        meili-data\
        trivy-cache\
        logs\
    setup.log
```

## Checking installation status

Run `check.ps1` to see what is installed, whether services are running, and how much disk space is used. This script does not modify anything.

```powershell
.\check.ps1
.\check.ps1 -InstallDir "D:\ArtifactKeeper"
```

Or use the built-in check mode:

```powershell
.\setup.ps1 -Check
```

## Prerequisites

- Windows Server 2019+ or Windows 10/11
- PowerShell 5.1+ (pre-installed on all supported versions)
- Internet connection (components are downloaded during setup)
- Administrator privileges

## How services are managed

The backend binary has native Windows Service support and registers itself using the `--install` flag. PostgreSQL registers via `pg_ctl register`. Meilisearch, Trivy, and the web frontend use [WinSW](https://github.com/winsw/winsw) as a lightweight service wrapper. WinSW is downloaded once and copied per service.

## License

Apache-2.0
