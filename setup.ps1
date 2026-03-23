#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Artifact Keeper setup script for Windows.

.DESCRIPTION
    Downloads and installs Artifact Keeper and its dependencies (PostgreSQL,
    Meilisearch, Trivy, Node.js, web frontend) on Windows Server or Windows
    10/11. Each component runs as a Windows Service.

.PARAMETER InstallDir
    Root directory for binaries. Defaults to C:\ArtifactKeeper.

.PARAMETER DataDir
    Root directory for data, configuration, and logs. Defaults to
    C:\ArtifactKeeper\data.

.PARAMETER Components
    Components to install. Use "all" for everything, or pick from: backend,
    postgresql, meilisearch, trivy, frontend, check, uninstall.

.PARAMETER Unattended
    Skip interactive prompts. Requires -DbPassword when installing PostgreSQL.

.PARAMETER Check
    Show installation status without modifying anything. Same as
    -Components check.

.PARAMETER Upgrade
    Upgrade installed components to the latest (or specified) versions.

.EXAMPLE
    .\setup.ps1
    Interactive setup with component selection menu.

.EXAMPLE
    .\setup.ps1 -Components all -Unattended -DbPassword "s3cure"
    Unattended install of all components.

.EXAMPLE
    .\setup.ps1 -Check
    Show status of installed components.
#>

param(
    [string]$InstallDir = "C:\ArtifactKeeper",
    [string]$DataDir = "C:\ArtifactKeeper\data",
    [ValidateSet("all", "backend", "postgresql", "meilisearch", "trivy", "frontend", "check", "uninstall")]
    [string[]]$Components = @("all"),
    [string]$BackendVersion = "latest",
    [string]$PostgresVersion = "17",
    [string]$MeilisearchVersion = "latest",
    [string]$TrivyVersion = "latest",
    [string]$NodeVersion = "22.16.0",
    [string]$WinswVersion = "2.12.0",
    [string]$DbPassword,
    [string]$JwtSecret,
    [int]$ApiPort = 8080,
    [int]$WebPort = 3000,
    [switch]$Unattended,
    [switch]$Check,
    [switch]$Upgrade
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$ScriptVersion = "1.0.0"
$LogFile = Join-Path $InstallDir "setup.log"

$ServiceNames = @{
    Backend      = "ArtifactKeeper"
    PostgreSQL   = "PostgreSQL"
    Meilisearch  = "Meilisearch"
    Trivy        = "Trivy"
    Frontend     = "ArtifactKeeperWeb"
}

# PostgreSQL full version mapping (major -> full).
# Update this table when new minor releases ship.
$PostgresFullVersions = @{
    "17" = "17.4"
    "16" = "16.8"
}

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    if (Test-Path (Split-Path $LogFile -Parent)) {
        $line | Out-File -Append -FilePath $LogFile -Encoding utf8
    }
    switch ($Level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "OK"    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
}

function Write-Banner {
    Write-Host ""
    Write-Host "  Artifact Keeper Setup  v$ScriptVersion" -ForegroundColor Cyan
    Write-Host "  =====================================" -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-Status {
    param([string]$Label, [string]$Value, [string]$Color = "White")
    Write-Host "  $Label" -NoNewline -ForegroundColor Gray
    Write-Host "  $Value" -ForegroundColor $Color
}

# ---------------------------------------------------------------------------
# Download helpers
# ---------------------------------------------------------------------------

function Invoke-DownloadWithRetry {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [int]$MaxAttempts = 3
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Write-Log "Downloading $Uri (attempt $attempt/$MaxAttempts)"
            # Use TLS 1.2+ for GitHub and other HTTPS sources
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $ProgressPreference = "SilentlyContinue"
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
            $hash = (Get-FileHash -Path $OutFile -Algorithm SHA256).Hash
            Write-Log "Downloaded $OutFile (SHA256: $hash)"
            return $true
        }
        catch {
            Write-Log "Download failed: $_" "WARN"
            if ($attempt -eq $MaxAttempts) {
                Write-Log "All $MaxAttempts download attempts failed for $Uri" "ERROR"
                return $false
            }
            Start-Sleep -Seconds ($attempt * 2)
        }
    }
    return $false
}

function Get-LatestGitHubRelease {
    param([Parameter(Mandatory)][string]$Repo)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest"
        $tag = $release.tag_name
        Write-Log "Latest release for $Repo : $tag"
        return $tag
    }
    catch {
        Write-Log "Failed to query GitHub API for $Repo : $_" "ERROR"
        return $null
    }
}

function New-SecureRandomString {
    param([int]$ByteCount = 48)
    $bytes = New-Object byte[] $ByteCount
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    return [Convert]::ToBase64String($bytes)
}

# ---------------------------------------------------------------------------
# Directory setup
# ---------------------------------------------------------------------------

function Initialize-Directories {
    $dirs = @(
        $InstallDir
        (Join-Path $InstallDir "bin")
        (Join-Path $InstallDir "meilisearch")
        (Join-Path $InstallDir "trivy")
        (Join-Path $InstallDir "web")
        $DataDir
        (Join-Path $DataDir "config")
        (Join-Path $DataDir "artifacts")
        (Join-Path $DataDir "pgdata")
        (Join-Path $DataDir "meili-data")
        (Join-Path $DataDir "trivy-cache")
        (Join-Path $DataDir "logs")
    )
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
    Write-Log "Directory structure created under $InstallDir"
}

# ---------------------------------------------------------------------------
# WinSW helper
# ---------------------------------------------------------------------------

function Install-WinSW {
    $winswPath = Join-Path $InstallDir "bin\winsw.exe"
    if (Test-Path $winswPath) {
        Write-Log "WinSW already present at $winswPath"
        return $true
    }
    $url = "https://github.com/winsw/winsw/releases/download/v$WinswVersion/WinSW.NET461.exe"
    return Invoke-DownloadWithRetry -Uri $url -OutFile $winswPath
}

function Register-WinSWService {
    param(
        [Parameter(Mandatory)][string]$ServiceDir,
        [Parameter(Mandatory)][string]$ServiceId,
        [Parameter(Mandatory)][string]$XmlContent
    )
    $winswSrc = Join-Path $InstallDir "bin\winsw.exe"
    $winswDst = Join-Path $ServiceDir "$ServiceId-service.exe"
    $xmlFile  = Join-Path $ServiceDir "$ServiceId-service.xml"

    Copy-Item -Path $winswSrc -Destination $winswDst -Force
    $XmlContent | Set-Content -Path $xmlFile -Encoding UTF8

    # Unregister first if the service already exists
    $existing = Get-Service -Name $ServiceId -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "Service $ServiceId already registered, reinstalling"
        & $winswDst stop 2>$null
        & $winswDst uninstall 2>$null
        Start-Sleep -Seconds 2
    }

    & $winswDst install
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Failed to register service $ServiceId" "ERROR"
        return $false
    }
    Write-Log "Registered service: $ServiceId" "OK"
    return $true
}

# ---------------------------------------------------------------------------
# Component installers
# ---------------------------------------------------------------------------

function Install-Backend {
    Write-Log "--- Installing Backend ---"

    $version = $BackendVersion
    if ($version -eq "latest") {
        $tag = Get-LatestGitHubRelease "artifact-keeper/artifact-keeper"
        if (-not $tag) { return $false }
        $version = $tag.TrimStart("v")
    }

    $binDir = Join-Path $InstallDir "bin"
    $exePath = Join-Path $binDir "artifact-keeper.exe"
    $url = "https://github.com/artifact-keeper/artifact-keeper/releases/download/v$version/artifact-keeper-windows-amd64.exe"

    $ok = Invoke-DownloadWithRetry -Uri $url -OutFile $exePath
    if (-not $ok) { return $false }

    # Set the environment variable so the backend finds its config
    $envFilePath = Join-Path $DataDir "config\.env"
    [Environment]::SetEnvironmentVariable("AK_ENV_FILE", $envFilePath, "Machine")
    Write-Log "Set AK_ENV_FILE = $envFilePath (Machine scope)"

    # Register as Windows Service using the backend's own --install flag
    Write-Log "Registering ArtifactKeeper service via --install"
    & $exePath --install 2>&1 | ForEach-Object { Write-Log $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Backend --install failed (exit code $LASTEXITCODE). The service may need manual registration." "WARN"
    } else {
        Write-Log "Backend service registered" "OK"
    }

    Write-Log "Backend v$version installed" "OK"
    return $true
}

function Install-PostgreSQL {
    Write-Log "--- Installing PostgreSQL ---"

    $major = $PostgresVersion
    $fullVersion = $PostgresFullVersions[$major]
    if (-not $fullVersion) {
        Write-Log "Unknown PostgreSQL major version: $major. Supported: $($PostgresFullVersions.Keys -join ', ')" "ERROR"
        return $false
    }

    $pgDir = Join-Path $InstallDir "postgresql"
    $pgBinDir = Join-Path $pgDir "pgsql\bin"
    $pgDataDir = Join-Path $DataDir "pgdata"
    $zipName = "postgresql-$fullVersion-1-windows-x64-binaries.zip"
    $zipPath = Join-Path $InstallDir $zipName
    $url = "https://get.enterprisedb.com/postgresql/$zipName"

    if (Test-Path $pgBinDir) {
        Write-Log "PostgreSQL binaries already present at $pgBinDir"
    } else {
        $ok = Invoke-DownloadWithRetry -Uri $url -OutFile $zipPath
        if (-not $ok) { return $false }

        Write-Log "Extracting PostgreSQL to $pgDir"
        Expand-Archive -Path $zipPath -DestinationPath $pgDir -Force
        Remove-Item $zipPath -Force
    }

    # Initialize the data directory if it does not exist
    $pgdataMarker = Join-Path $pgDataDir "PG_VERSION"
    if (-not (Test-Path $pgdataMarker)) {
        # Generate a password for the postgres superuser
        $pgSuperPass = New-SecureRandomString -ByteCount 24

        Write-Log "Running initdb for data directory $pgDataDir"
        $initdb = Join-Path $pgBinDir "initdb.exe"
        $env:PGPASSWORD = $pgSuperPass
        & $initdb -D $pgDataDir -U postgres -A md5 --pwfile=- 2>&1 <<< $pgSuperPass |
            ForEach-Object { Write-Log $_ }
    }

    # Register as a Windows Service
    $pgCtl = Join-Path $pgBinDir "pg_ctl.exe"
    $existing = Get-Service -Name $ServiceNames.PostgreSQL -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Log "Registering PostgreSQL service"
        & $pgCtl register -N $ServiceNames.PostgreSQL -D $pgDataDir 2>&1 |
            ForEach-Object { Write-Log $_ }
    }

    # Start the service so we can create the application database
    Start-Service -Name $ServiceNames.PostgreSQL -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    # Determine database password
    $dbPass = $DbPassword
    if (-not $dbPass) {
        if ($Unattended) {
            $dbPass = New-SecureRandomString -ByteCount 24
            Write-Log "Generated random database password (saved to .env)" "WARN"
        } else {
            $securePass = Read-Host "Enter password for the 'registry' database user" -AsSecureString
            $dbPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass))
        }
    }

    # Create the application user and database
    $psql = Join-Path $pgBinDir "psql.exe"
    $env:PGPASSWORD = $dbPass

    Write-Log "Creating database user 'registry' and database 'artifact_registry'"
    & $psql -h localhost -U postgres -c "DO `$`$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'registry') THEN CREATE ROLE registry WITH LOGIN PASSWORD '$dbPass'; END IF; END `$`$;" 2>&1 |
        ForEach-Object { Write-Log $_ }

    & $psql -h localhost -U postgres -c "SELECT 1 FROM pg_database WHERE datname = 'artifact_registry'" -t 2>&1 |
        ForEach-Object {
            if ($_.Trim() -ne "1") {
                & $psql -h localhost -U postgres -c "CREATE DATABASE artifact_registry OWNER registry;" 2>&1 |
                    ForEach-Object { Write-Log $_ }
            }
        }

    # Store password for .env generation
    $script:ResolvedDbPassword = $dbPass
    Write-Log "PostgreSQL $fullVersion installed" "OK"
    return $true
}

function Install-Meilisearch {
    Write-Log "--- Installing Meilisearch ---"

    if (-not (Install-WinSW)) { return $false }

    $version = $MeilisearchVersion
    if ($version -eq "latest") {
        $tag = Get-LatestGitHubRelease "meilisearch/meilisearch"
        if (-not $tag) { return $false }
        $version = $tag.TrimStart("v")
    }

    $msDir = Join-Path $InstallDir "meilisearch"
    $exePath = Join-Path $msDir "meilisearch.exe"
    $url = "https://github.com/meilisearch/meilisearch/releases/download/v$version/meilisearch-windows-amd64.exe"

    $ok = Invoke-DownloadWithRetry -Uri $url -OutFile $exePath
    if (-not $ok) { return $false }

    # Generate a master key
    $masterKey = New-SecureRandomString -ByteCount 32
    $script:MeilisearchMasterKey = $masterKey

    $meiliDataDir = Join-Path $DataDir "meili-data"
    $logDir = Join-Path $DataDir "logs"

    $xml = @"
<service>
  <id>Meilisearch</id>
  <name>Meilisearch</name>
  <description>Meilisearch search engine for Artifact Keeper</description>
  <executable>$exePath</executable>
  <arguments>--db-path "$meiliDataDir" --master-key "$masterKey" --http-addr 127.0.0.1:7700</arguments>
  <log mode="roll-by-size">
    <logpath>$logDir</logpath>
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>3</keepFiles>
  </log>
  <startmode>Automatic</startmode>
</service>
"@

    $registered = Register-WinSWService -ServiceDir $msDir -ServiceId "Meilisearch" -XmlContent $xml
    if (-not $registered) { return $false }

    Write-Log "Meilisearch v$version installed" "OK"
    return $true
}

function Install-Trivy {
    Write-Log "--- Installing Trivy ---"

    if (-not (Install-WinSW)) { return $false }

    $version = $TrivyVersion
    if ($version -eq "latest") {
        $tag = Get-LatestGitHubRelease "aquasecurity/trivy"
        if (-not $tag) { return $false }
        $version = $tag.TrimStart("v")
    }

    $trivyDir = Join-Path $InstallDir "trivy"
    $exePath = Join-Path $trivyDir "trivy.exe"
    $zipPath = Join-Path $InstallDir "trivy.zip"
    $url = "https://github.com/aquasecurity/trivy/releases/download/v$version/trivy_${version}_Windows-64bit.zip"

    $ok = Invoke-DownloadWithRetry -Uri $url -OutFile $zipPath
    if (-not $ok) { return $false }

    Write-Log "Extracting Trivy to $trivyDir"
    Expand-Archive -Path $zipPath -DestinationPath $trivyDir -Force
    Remove-Item $zipPath -Force

    $cacheDir = Join-Path $DataDir "trivy-cache"
    $logDir = Join-Path $DataDir "logs"

    $xml = @"
<service>
  <id>Trivy</id>
  <name>Trivy</name>
  <description>Trivy vulnerability scanner for Artifact Keeper</description>
  <executable>$exePath</executable>
  <arguments>server --listen 0.0.0.0:8090 --cache-dir "$cacheDir"</arguments>
  <log mode="roll-by-size">
    <logpath>$logDir</logpath>
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>3</keepFiles>
  </log>
  <startmode>Automatic</startmode>
</service>
"@

    $registered = Register-WinSWService -ServiceDir $trivyDir -ServiceId "Trivy" -XmlContent $xml
    if (-not $registered) { return $false }

    Write-Log "Trivy v$version installed" "OK"
    return $true
}

function Install-Frontend {
    Write-Log "--- Installing Web Frontend ---"

    if (-not (Install-WinSW)) { return $false }

    # -- Node.js --
    $nodeDir = Join-Path $InstallDir "nodejs"
    $nodeExe = Join-Path $nodeDir "node.exe"
    if (-not (Test-Path $nodeExe)) {
        $nodeZip = Join-Path $InstallDir "node.zip"
        $url = "https://nodejs.org/dist/v$NodeVersion/node-v$NodeVersion-win-x64.zip"
        $ok = Invoke-DownloadWithRetry -Uri $url -OutFile $nodeZip
        if (-not $ok) { return $false }

        Write-Log "Extracting Node.js to $nodeDir"
        $tempDir = Join-Path $InstallDir "node-temp"
        Expand-Archive -Path $nodeZip -DestinationPath $tempDir -Force
        # The ZIP contains a top-level folder like node-v22.16.0-win-x64
        $innerDir = Get-ChildItem -Path $tempDir -Directory | Select-Object -First 1
        if ($innerDir) {
            if (Test-Path $nodeDir) { Remove-Item $nodeDir -Recurse -Force }
            Move-Item -Path $innerDir.FullName -Destination $nodeDir
        }
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $nodeZip -Force
        Write-Log "Node.js v$NodeVersion installed" "OK"
    } else {
        Write-Log "Node.js already present at $nodeExe"
    }

    # -- Web frontend artifact --
    $webDir = Join-Path $InstallDir "web"
    $webZip = Join-Path $InstallDir "web.zip"
    $webVersion = $BackendVersion
    if ($webVersion -eq "latest") {
        $tag = Get-LatestGitHubRelease "artifact-keeper/artifact-keeper-web"
        if (-not $tag) { return $false }
        $webVersion = $tag.TrimStart("v")
    }

    $url = "https://github.com/artifact-keeper/artifact-keeper-web/releases/download/v$webVersion/artifact-keeper-web-standalone.zip"
    $ok = Invoke-DownloadWithRetry -Uri $url -OutFile $webZip
    if (-not $ok) { return $false }

    Write-Log "Extracting web frontend to $webDir"
    Expand-Archive -Path $webZip -DestinationPath $webDir -Force
    Remove-Item $webZip -Force

    # -- Register as a service via WinSW --
    $logDir = Join-Path $DataDir "logs"

    $xml = @"
<service>
  <id>ArtifactKeeperWeb</id>
  <name>Artifact Keeper Web</name>
  <description>Artifact Keeper web frontend (Next.js)</description>
  <executable>$nodeExe</executable>
  <arguments>server.js</arguments>
  <workingdirectory>$webDir</workingdirectory>
  <env name="PORT" value="$WebPort" />
  <env name="HOSTNAME" value="0.0.0.0" />
  <env name="NEXT_PUBLIC_API_URL" value="http://localhost:$ApiPort" />
  <log mode="roll-by-size">
    <logpath>$logDir</logpath>
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>3</keepFiles>
  </log>
  <startmode>Automatic</startmode>
</service>
"@

    $registered = Register-WinSWService -ServiceDir $webDir -ServiceId "ArtifactKeeperWeb" -XmlContent $xml
    if (-not $registered) { return $false }

    Write-Log "Web frontend v$webVersion installed" "OK"
    return $true
}

# ---------------------------------------------------------------------------
# Configuration generation
# ---------------------------------------------------------------------------

function Write-EnvConfig {
    param([bool]$PostgresLocal, [bool]$MeilisearchLocal, [bool]$TrivyLocal)

    $envFile = Join-Path $DataDir "config\.env"

    $dbPassword = if ($script:ResolvedDbPassword) { $script:ResolvedDbPassword } elseif ($DbPassword) { $DbPassword } else { "changeme" }
    $dbUrl = "postgresql://registry:${dbPassword}@localhost:5432/artifact_registry"

    $jwtValue = if ($JwtSecret) { $JwtSecret } else { New-SecureRandomString -ByteCount 48 }

    $storagePath = Join-Path $DataDir "artifacts"
    $logsPath = Join-Path $DataDir "logs"

    $lines = @(
        "# Artifact Keeper configuration"
        "# Generated by setup.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        ""
        "DATABASE_URL=$dbUrl"
        "JWT_SECRET=$jwtValue"
        "STORAGE_PATH=$storagePath"
        "BIND_ADDRESS=0.0.0.0:$ApiPort"
        "RUST_LOG=info"
    )

    if ($MeilisearchLocal) {
        $key = if ($script:MeilisearchMasterKey) { $script:MeilisearchMasterKey } else { "" }
        $lines += ""
        $lines += "MEILISEARCH_URL=http://localhost:7700"
        if ($key) { $lines += "MEILISEARCH_API_KEY=$key" }
    }

    if ($TrivyLocal) {
        $lines += ""
        $lines += "TRIVY_URL=http://localhost:8090"
    }

    $lines -join "`r`n" | Set-Content -Path $envFile -Encoding UTF8
    Write-Log "Configuration written to $envFile"

    # Restrict ACLs: Administrators and SYSTEM only
    try {
        $acl = Get-Acl $envFile
        $acl.SetAccessRuleProtection($true, $false)
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "BUILTIN\Administrators", "FullControl", "Allow")
        $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "NT AUTHORITY\SYSTEM", "FullControl", "Allow")
        $acl.AddAccessRule($adminRule)
        $acl.AddAccessRule($systemRule)
        Set-Acl -Path $envFile -AclObject $acl
        Write-Log "Restricted .env file permissions to Administrators and SYSTEM"
    }
    catch {
        Write-Log "Could not restrict .env file permissions: $_" "WARN"
    }
}

# ---------------------------------------------------------------------------
# Service management
# ---------------------------------------------------------------------------

function Start-AllServices {
    $order = @(
        $ServiceNames.PostgreSQL
        $ServiceNames.Backend
        $ServiceNames.Meilisearch
        $ServiceNames.Trivy
        $ServiceNames.Frontend
    )
    Write-Host ""
    foreach ($svc in $order) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            try {
                if ($s.Status -ne "Running") {
                    Start-Service -Name $svc
                    Start-Sleep -Seconds 2
                }
                $s = Get-Service -Name $svc
                $port = switch ($svc) {
                    $ServiceNames.PostgreSQL  { "5432" }
                    $ServiceNames.Backend     { "$ApiPort" }
                    $ServiceNames.Meilisearch { "7700" }
                    $ServiceNames.Trivy       { "8090" }
                    $ServiceNames.Frontend    { "$WebPort" }
                }
                $statusColor = if ($s.Status -eq "Running") { "Green" } else { "Yellow" }
                Write-Host "  [$($s.Status)]" -ForegroundColor $statusColor -NoNewline
                Write-Host " $($svc.PadRight(22)) (port $port)"
            }
            catch {
                Write-Host "  [Failed]" -ForegroundColor Red -NoNewline
                Write-Host " $svc : $_"
            }
        }
    }
}

function Stop-AllServices {
    $order = @(
        $ServiceNames.Frontend
        $ServiceNames.Trivy
        $ServiceNames.Meilisearch
        $ServiceNames.Backend
        $ServiceNames.PostgreSQL
    )
    foreach ($svc in $order) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq "Running") {
            Write-Log "Stopping $svc"
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Check mode
# ---------------------------------------------------------------------------

function Invoke-CheckMode {
    Write-Banner
    Write-Host "  Installation directory: $InstallDir" -ForegroundColor Gray
    Write-Host ""

    $components = @(
        @{ Name = "Backend";     Exe = "bin\artifact-keeper.exe"; Service = $ServiceNames.Backend;     Port = $ApiPort;  HealthUrl = "http://localhost:${ApiPort}/health" }
        @{ Name = "PostgreSQL";  Exe = "postgresql\pgsql\bin\psql.exe"; Service = $ServiceNames.PostgreSQL; Port = 5432; HealthUrl = $null }
        @{ Name = "Meilisearch"; Exe = "meilisearch\meilisearch.exe"; Service = $ServiceNames.Meilisearch; Port = 7700; HealthUrl = "http://localhost:7700/health" }
        @{ Name = "Trivy";       Exe = "trivy\trivy.exe"; Service = $ServiceNames.Trivy; Port = 8090; HealthUrl = $null }
        @{ Name = "Node.js";     Exe = "nodejs\node.exe"; Service = $null; Port = $null; HealthUrl = $null }
        @{ Name = "Frontend";    Exe = "web\server.js"; Service = $ServiceNames.Frontend; Port = $WebPort; HealthUrl = "http://localhost:${WebPort}" }
    )

    foreach ($c in $components) {
        $exePath = Join-Path $InstallDir $c.Exe
        $installed = Test-Path $exePath

        $nameStr = $c.Name.PadRight(14)
        if ($installed) {
            Write-Host "  [Installed]" -ForegroundColor Green -NoNewline
            Write-Host "  $nameStr" -NoNewline

            # File size
            $item = Get-Item $exePath
            $sizeMB = [math]::Round($item.Length / 1MB, 1)
            Write-Host "  ${sizeMB} MB" -NoNewline -ForegroundColor DarkGray

            # Service status
            if ($c.Service) {
                $svc = Get-Service -Name $c.Service -ErrorAction SilentlyContinue
                if ($svc) {
                    $svcColor = if ($svc.Status -eq "Running") { "Green" } else { "Yellow" }
                    Write-Host "  $($svc.Status)" -NoNewline -ForegroundColor $svcColor
                }
            }

            # Health check
            if ($c.HealthUrl) {
                try {
                    $resp = Invoke-WebRequest -Uri $c.HealthUrl -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
                    Write-Host "  Healthy" -ForegroundColor Green
                }
                catch {
                    Write-Host "  Unreachable" -ForegroundColor Yellow
                }
            } else {
                Write-Host ""
            }
        } else {
            Write-Host "  [Missing]   " -ForegroundColor DarkGray -NoNewline
            Write-Host "  $nameStr"
        }
    }

    # Disk usage
    Write-Host ""
    if (Test-Path $InstallDir) {
        $totalBytes = (Get-ChildItem -Path $InstallDir -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        $totalMB = [math]::Round($totalBytes / 1MB, 1)
        Write-Host "  Total disk usage: $totalMB MB" -ForegroundColor Gray
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

function Invoke-Uninstall {
    Write-Banner
    Write-Log "Starting uninstall"

    Stop-AllServices

    # Unregister WinSW-based services
    $winswServices = @(
        @{ Dir = "meilisearch"; Id = "Meilisearch" }
        @{ Dir = "trivy"; Id = "Trivy" }
        @{ Dir = "web"; Id = "ArtifactKeeperWeb" }
    )
    foreach ($ws in $winswServices) {
        $svcExe = Join-Path $InstallDir "$($ws.Dir)\$($ws.Id)-service.exe"
        if (Test-Path $svcExe) {
            Write-Log "Unregistering $($ws.Id) service"
            & $svcExe uninstall 2>$null
        }
    }

    # Unregister backend service
    $backendExe = Join-Path $InstallDir "bin\artifact-keeper.exe"
    if (Test-Path $backendExe) {
        Write-Log "Unregistering ArtifactKeeper service"
        & $backendExe --uninstall 2>$null
    }

    # Unregister PostgreSQL service
    $pgCtl = Join-Path $InstallDir "postgresql\pgsql\bin\pg_ctl.exe"
    if (Test-Path $pgCtl) {
        Write-Log "Unregistering PostgreSQL service"
        & $pgCtl unregister -N $ServiceNames.PostgreSQL 2>$null
    }

    # Remove environment variable
    [Environment]::SetEnvironmentVariable("AK_ENV_FILE", $null, "Machine")

    # Remove data?
    $removeData = $false
    if ($Unattended) {
        $removeData = $true
    } else {
        $answer = Read-Host "Remove data directory ($DataDir)? This deletes all artifacts and databases. [y/N]"
        $removeData = ($answer -eq "y" -or $answer -eq "Y")
    }

    Write-Log "Removing installation directory: $InstallDir"
    if ($removeData -or ($DataDir -like "$InstallDir*")) {
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        # Remove everything except the data directory
        Get-ChildItem -Path $InstallDir -Exclude "data" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($removeData -and $DataDir -notlike "$InstallDir*") {
        Write-Log "Removing data directory: $DataDir"
        Remove-Item -Path $DataDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Uninstall complete" "OK"
}

# ---------------------------------------------------------------------------
# Upgrade
# ---------------------------------------------------------------------------

function Invoke-Upgrade {
    Write-Banner
    Write-Log "Starting upgrade"

    Stop-AllServices

    # Re-run installers for existing components
    $backendExe = Join-Path $InstallDir "bin\artifact-keeper.exe"
    if (Test-Path $backendExe) { Install-Backend | Out-Null }

    $msExe = Join-Path $InstallDir "meilisearch\meilisearch.exe"
    if (Test-Path $msExe) { Install-Meilisearch | Out-Null }

    $trivyExe = Join-Path $InstallDir "trivy\trivy.exe"
    if (Test-Path $trivyExe) { Install-Trivy | Out-Null }

    $webDir = Join-Path $InstallDir "web\server.js"
    if (Test-Path $webDir) { Install-Frontend | Out-Null }

    Write-Log "Upgrade complete. Starting services..." "OK"
    Start-AllServices
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------

function Show-InteractiveMenu {
    Write-Banner
    Write-Host "  Select components to install:"
    Write-Host ""
    Write-Host "    [1] Backend API server (required)" -ForegroundColor White
    Write-Host "    [2] PostgreSQL $PostgresVersion database (required unless using external DB)" -ForegroundColor White
    Write-Host "    [3] Meilisearch search engine (recommended)" -ForegroundColor White
    Write-Host "    [4] Trivy vulnerability scanner (optional)" -ForegroundColor White
    Write-Host "    [5] Web frontend (recommended)" -ForegroundColor White
    Write-Host ""
    Write-Host "    [A] All components" -ForegroundColor Cyan
    Write-Host "    [C] Check existing installation" -ForegroundColor Cyan
    Write-Host "    [U] Uninstall" -ForegroundColor Cyan
    Write-Host ""

    $selection = Read-Host "  Enter selection (e.g., 1,2,3,5 or A for all)"
    $selection = $selection.Trim().ToUpper()

    if ($selection -eq "C") { return @("check") }
    if ($selection -eq "U") { return @("uninstall") }
    if ($selection -eq "A") { return @("all") }

    $map = @{ "1" = "backend"; "2" = "postgresql"; "3" = "meilisearch"; "4" = "trivy"; "5" = "frontend" }
    $selected = @()
    foreach ($token in ($selection -split "[,\s]+")) {
        if ($map.ContainsKey($token)) {
            $selected += $map[$token]
        }
    }

    if ($selected.Count -eq 0) {
        Write-Host "  No valid selection. Exiting." -ForegroundColor Yellow
        exit 0
    }

    return $selected
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Initialize script-scope variables for cross-component state
$script:ResolvedDbPassword = $null
$script:MeilisearchMasterKey = $null

# Handle -Check shorthand
if ($Check) { $Components = @("check") }

# Interactive menu when running without explicit components
if ((-not $Unattended) -and ($Components.Count -eq 1) -and ($Components[0] -eq "all") -and (-not $Check) -and (-not $Upgrade)) {
    $Components = Show-InteractiveMenu
}

# Dispatch check / uninstall / upgrade
if ($Components -contains "check") {
    Invoke-CheckMode
    exit 0
}

if ($Components -contains "uninstall") {
    Invoke-Uninstall
    exit 0
}

if ($Upgrade) {
    Invoke-Upgrade
    exit 0
}

# --- Normal install flow ---
Write-Banner
Initialize-Directories

$resolvedComponents = if ($Components -contains "all") {
    @("backend", "postgresql", "meilisearch", "trivy", "frontend")
} else {
    $Components
}

$results = @{}

foreach ($comp in $resolvedComponents) {
    $success = $false
    try {
        $success = switch ($comp) {
            "backend"     { Install-Backend }
            "postgresql"  { Install-PostgreSQL }
            "meilisearch" { Install-Meilisearch }
            "trivy"       { Install-Trivy }
            "frontend"    { Install-Frontend }
            default       { Write-Log "Unknown component: $comp" "ERROR"; $false }
        }
    }
    catch {
        Write-Log "Error installing ${comp}: $_" "ERROR"
        $success = $false
    }
    $results[$comp] = $success
}

# Generate configuration
$pgLocal = $resolvedComponents -contains "postgresql"
$msLocal = $resolvedComponents -contains "meilisearch"
$tvLocal = $resolvedComponents -contains "trivy"
Write-EnvConfig -PostgresLocal $pgLocal -MeilisearchLocal $msLocal -TrivyLocal $tvLocal

# Summary
Write-Host ""
Write-Host "  Installation Summary" -ForegroundColor Cyan
Write-Host "  ====================" -ForegroundColor DarkCyan
Write-Host ""

$allOk = $true
foreach ($comp in $resolvedComponents) {
    $ok = $results[$comp]
    $icon = if ($ok) { "OK" } else { "FAIL" }
    $color = if ($ok) { "Green" } else { "Red" }
    Write-Host "    [$icon] $comp" -ForegroundColor $color
    if (-not $ok) { $allOk = $false }
}

if ($allOk) {
    Write-Host ""
    Write-Log "All components installed successfully" "OK"

    # Start services
    Write-Host ""
    Write-Host "  Services:" -ForegroundColor Cyan
    Start-AllServices

    Write-Host ""
    Write-Host "  Open http://localhost:$WebPort in your browser to get started." -ForegroundColor Green
    $adminPassFile = Join-Path $DataDir "artifacts\admin.password"
    Write-Host "  Admin password will be written to: $adminPassFile" -ForegroundColor Gray
    Write-Host ""
} else {
    Write-Host ""
    Write-Log "Some components failed to install. Check the log at $LogFile" "WARN"
    Write-Host ""
    exit 1
}
