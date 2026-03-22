#Requires -Version 5.1
<#
.SYNOPSIS
    Generate or update Artifact Keeper configuration.
.DESCRIPTION
    Interactive configuration wizard that creates the .env file.
#>

param(
    [string]$EnvFile = "C:\ProgramData\ArtifactKeeper\config\.env",
    [string]$DatabaseUrl,
    [string]$JwtSecret,
    [string]$BindAddress = "0.0.0.0:8080",
    [string]$StoragePath = "C:\ProgramData\ArtifactKeeper\artifacts",
    [switch]$NonInteractive
)

function Generate-Secret {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
}

# Load existing values if file exists
$existing = @{}
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | Where-Object { $_ -match "^[A-Z_]+=.+" } | ForEach-Object {
        $key, $value = $_ -split "=", 2
        $existing[$key] = $value
    }
    Write-Host "Loaded existing configuration from $EnvFile"
}

if ($NonInteractive) {
    if (-not $DatabaseUrl -and -not $existing["DATABASE_URL"]) {
        Write-Error "DATABASE_URL is required in non-interactive mode"
        exit 1
    }
} else {
    # Interactive prompts
    if (-not $DatabaseUrl) {
        $dbHost = Read-Host "PostgreSQL host [$($existing['DB_HOST'] ?? 'localhost')]"
        if (-not $dbHost) { $dbHost = $existing['DB_HOST'] ?? "localhost" }

        $dbPort = Read-Host "PostgreSQL port [$($existing['DB_PORT'] ?? '5432')]"
        if (-not $dbPort) { $dbPort = $existing['DB_PORT'] ?? "5432" }

        $dbName = Read-Host "Database name [$($existing['DB_NAME'] ?? 'artifact_registry')]"
        if (-not $dbName) { $dbName = $existing['DB_NAME'] ?? "artifact_registry" }

        $dbUser = Read-Host "Database user [$($existing['DB_USER'] ?? 'registry')]"
        if (-not $dbUser) { $dbUser = $existing['DB_USER'] ?? "registry" }

        $dbPass = Read-Host "Database password" -AsSecureString
        $dbPassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($dbPass))

        $DatabaseUrl = "postgresql://${dbUser}:${dbPassPlain}@${dbHost}:${dbPort}/${dbName}"
    }

    if (-not $JwtSecret) {
        $generateJwt = Read-Host "Generate a random JWT secret? [Y/n]"
        if ($generateJwt -ne "n") {
            $JwtSecret = Generate-Secret
            Write-Host "Generated JWT secret (saved to config file)"
        } else {
            $JwtSecret = Read-Host "Enter JWT secret (minimum 32 characters)"
        }
    }
}

# Use provided values or fall back to existing
if (-not $DatabaseUrl) { $DatabaseUrl = $existing["DATABASE_URL"] }
if (-not $JwtSecret) { $JwtSecret = $existing["JWT_SECRET"] ?? (Generate-Secret) }

# Ensure directory exists
$dir = Split-Path $EnvFile
if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

# Write config
@"
DATABASE_URL=$DatabaseUrl
JWT_SECRET=$JwtSecret
STORAGE_PATH=$StoragePath
BIND_ADDRESS=$BindAddress
RUST_LOG=info
"@ | Set-Content -Path $EnvFile -Encoding UTF8

# Restrict permissions
$acl = Get-Acl $EnvFile
$acl.SetAccessRuleProtection($true, $false)
$adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "BUILTIN\Administrators", "FullControl", "Allow")
$systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "NT AUTHORITY\SYSTEM", "FullControl", "Allow")
$acl.AddAccessRule($adminRule)
$acl.AddAccessRule($systemRule)
Set-Acl -Path $EnvFile -AclObject $acl

Write-Host "Configuration written to $EnvFile"
Write-Host "Start the service with: Start-Service ArtifactKeeper"
