# Artifact Keeper Windows Installer

WiX-based MSI installer for deploying Artifact Keeper as a Windows Service on Windows Server.

## What the installer does

- Installs the Artifact Keeper binary to `C:\Program Files\ArtifactKeeper\`
- Registers the `ArtifactKeeper` Windows Service with delayed auto-start
- Creates data directories at `C:\ProgramData\ArtifactKeeper\`
- Prompts for database connection and basic configuration
- Supports silent/unattended installation for enterprise deployment

## Prerequisites

- Windows Server 2019, 2022, or 2025 (Windows 10/11 for evaluation)
- PostgreSQL 16 or later (not bundled)
- Meilisearch (optional, not bundled)

## Building

The MSI is built automatically when a new backend release is published. To build manually:

```powershell
# Install WiX Toolset v4
dotnet tool install --global wix

# Download the backend binary
.\build\download-binary.ps1 -Version 1.2.0

# Build the MSI
.\build\build-msi.ps1 -Version 1.2.0
```

## Silent Installation

```powershell
msiexec /i ArtifactKeeper-1.2.0-x64.msi /qn `
    DB_HOST=localhost DB_PORT=5432 `
    DB_NAME=artifact_registry DB_USER=registry `
    DB_PASSWORD=changeme BIND_ADDRESS=0.0.0.0:8080
```

## License

MIT
