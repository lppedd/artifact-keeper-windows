#Requires -Version 5.1
<#
.SYNOPSIS
    Check the status of an Artifact Keeper installation on Windows.

.DESCRIPTION
    Reads the installation directory, checks for installed binaries, queries
    service status, hits health endpoints, and reports disk usage. This script
    does not modify anything and is safe to run at any time.

.PARAMETER InstallDir
    Root directory for the Artifact Keeper installation.
    Defaults to C:\ArtifactKeeper.

.PARAMETER ApiPort
    Backend API port. Defaults to 8080.

.PARAMETER WebPort
    Web frontend port. Defaults to 3000.

.PARAMETER PostgresPort
    PostgreSQL port. Defaults to 5432.

.PARAMETER MeilisearchPort
    Meilisearch port. Defaults to 7700.

.PARAMETER TrivyPort
    Trivy port. Defaults to 8090.

.PARAMETER PostgresVersion
    PostgreSQL major version. Used to match the versioned service name
    (e.g., ArtifactKeeperPostgreSQLv17). Defaults to "17".

.EXAMPLE
    .\check.ps1

.EXAMPLE
    .\check.ps1 -InstallDir "D:\ArtifactKeeper"
#>

param(
    [string]$InstallDir = "C:\ArtifactKeeper",
    [int]$ApiPort = 8080,
    [int]$WebPort = 3000,
    [int]$PostgresPort = 5432,
    [int]$MeilisearchPort = 7700,
    [int]$TrivyPort = 8090,
    [string]$PostgresVersion = "17"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"

# ---------------------------------------------------------------------------
# Service name constants (must match setup.ps1)
# ---------------------------------------------------------------------------

$ServiceNames = @{
    Backend     = "ArtifactKeeper"
    PostgreSQL  = "ArtifactKeeperPostgreSQLv$PostgresVersion"
    Meilisearch = "ArtifactKeeperMeilisearch"
    Trivy       = "ArtifactKeeperTrivy"
    Frontend    = "ArtifactKeeperWeb"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-CheckResult {
    param(
        [string]$Status,   # Installed, Missing, Running, Stopped, Healthy, Unreachable
        [string]$Label,
        [string]$Detail = ""
    )
    $color = switch ($Status) {
        "Installed"   { "Green" }
        "Running"     { "Green" }
        "Healthy"     { "Green" }
        "Stopped"     { "Yellow" }
        "Missing"     { "DarkGray" }
        "Unreachable" { "Yellow" }
        default       { "White" }
    }
    $tag = "[$Status]".PadRight(14)
    Write-Host "  $tag" -ForegroundColor $color -NoNewline
    Write-Host " $Label" -NoNewline
    if ($Detail) {
        Write-Host "  $Detail" -ForegroundColor DarkGray
    } else {
        Write-Host ""
    }
}

function Test-Endpoint {
    param([string]$Url, [int]$TimeoutSec = 3)
    try {
        $ProgressPreference = "SilentlyContinue"
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $resp.StatusCode -lt 400
    }
    catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  Artifact Keeper Status Check" -ForegroundColor Cyan
Write-Host "  =============================" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  Install directory: $InstallDir" -ForegroundColor Gray
Write-Host ""

if (-not (Test-Path $InstallDir)) {
    Write-Host "  Installation directory does not exist." -ForegroundColor Yellow
    Write-Host "  Run setup.ps1 to install Artifact Keeper." -ForegroundColor Gray
    Write-Host ""
    exit 0
}

# ---------------------------------------------------------------------------
# Component checks
# ---------------------------------------------------------------------------

$components = @(
    @{
        Name    = "Backend"
        Exe     = "bin\artifact-keeper.exe"
        Service = $ServiceNames.Backend
        Health  = "http://localhost:${ApiPort}/health"
    }
    @{
        Name    = "PostgreSQL"
        Exe     = "postgresql\pgsql\bin\psql.exe"
        Service = $ServiceNames.PostgreSQL
        Health  = $null
    }
    @{
        Name    = "Meilisearch"
        Exe     = "meilisearch\meilisearch.exe"
        Service = $ServiceNames.Meilisearch
        Health  = "http://localhost:${MeilisearchPort}/health"
    }
    @{
        Name    = "Trivy"
        Exe     = "trivy\trivy.exe"
        Service = $ServiceNames.Trivy
        Health  = $null
    }
    @{
        Name    = "Node.js"
        Exe     = "nodejs\node.exe"
        Service = $null
        Health  = $null
    }
    @{
        Name    = "Frontend"
        Exe     = "web\server.js"
        Service = $ServiceNames.Frontend
        Health  = "http://localhost:${WebPort}"
    }
)

Write-Host "  Components" -ForegroundColor White
Write-Host "  ----------" -ForegroundColor DarkGray

foreach ($c in $components) {
    $exePath = Join-Path $InstallDir $c.Exe
    $label = $c.Name.PadRight(14)

    if (-not (Test-Path $exePath)) {
        Write-CheckResult "Missing" $label
        continue
    }

    $item = Get-Item $exePath
    $sizeMB = [math]::Round($item.Length / 1MB, 1)
    $detail = "${sizeMB} MB"

    Write-CheckResult "Installed" $label $detail

    # Service status
    if ($c.Service) {
        $svc = Get-Service -Name $c.Service -ErrorAction SilentlyContinue
        if ($svc) {
            $svcLabel = "  Service: $($c.Service)".PadRight(14)
            if ($svc.Status -eq "Running") {
                Write-CheckResult "Running" $svcLabel
            } else {
                Write-CheckResult "Stopped" $svcLabel
            }
        }
    }

    # Health endpoint
    if ($c.Health) {
        $healthy = Test-Endpoint $c.Health
        $healthLabel = "  Endpoint: $($c.Health)".PadRight(14)
        if ($healthy) {
            Write-CheckResult "Healthy" $healthLabel
        } else {
            Write-CheckResult "Unreachable" $healthLabel
        }
    }
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  Configuration" -ForegroundColor White
Write-Host "  -------------" -ForegroundColor DarkGray

$dataDir = Join-Path $InstallDir "data"
$envFile = Join-Path $dataDir "config\.env"

if (Test-Path $envFile) {
    Write-CheckResult "Installed" ".env config" $envFile
} else {
    Write-CheckResult "Missing" ".env config" "(expected at $envFile)"
}

$akEnvFile = [Environment]::GetEnvironmentVariable("AK_ENV_FILE", "Machine")
if ($akEnvFile) {
    Write-CheckResult "Installed" "AK_ENV_FILE" $akEnvFile
} else {
    Write-CheckResult "Missing" "AK_ENV_FILE" "(system environment variable not set)"
}

# ---------------------------------------------------------------------------
# Disk usage
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  Disk Usage" -ForegroundColor White
Write-Host "  ----------" -ForegroundColor DarkGray

$subdirs = @("bin", "postgresql", "meilisearch", "trivy", "nodejs", "web", "data")
foreach ($sub in $subdirs) {
    $path = Join-Path $InstallDir $sub
    if (Test-Path $path) {
        $bytes = (Get-ChildItem -Path $path -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        if ($bytes) {
            $mb = [math]::Round($bytes / 1MB, 1)
            $label = $sub.PadRight(14)
            Write-Host "    $label  $mb MB" -ForegroundColor Gray
        }
    }
}

$totalBytes = (Get-ChildItem -Path $InstallDir -Recurse -File -ErrorAction SilentlyContinue |
    Measure-Object -Property Length -Sum).Sum
if ($totalBytes) {
    $totalMB = [math]::Round($totalBytes / 1MB, 1)
    Write-Host ""
    Write-Host "    Total         $totalMB MB" -ForegroundColor White
}

Write-Host ""
