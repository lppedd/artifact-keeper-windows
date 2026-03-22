#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-installation validation for Artifact Keeper on Windows.
.DESCRIPTION
    Checks system requirements, port availability, and prerequisites.
#>

param(
    [string]$DatabaseUrl,
    [switch]$Quiet
)

$errors = 0
$warnings = 0

function Write-Check {
    param([string]$Status, [string]$Message)
    if ($Quiet -and $Status -eq "PASS") { return }
    $color = switch ($Status) {
        "PASS" { "Green" }
        "WARN" { "Yellow" }
        "FAIL" { "Red" }
        default { "White" }
    }
    Write-Host "[$Status] " -ForegroundColor $color -NoNewline
    Write-Host $Message
}

# Windows version
$os = [System.Environment]::OSVersion
if ($os.Version.Build -ge 14393) {
    Write-Check "PASS" "Windows version: $($os.VersionString)"
} else {
    Write-Check "FAIL" "Windows Server 2016+ required (build 14393+). Current: $($os.VersionString)"
    $errors++
}

# Architecture
if ($env:PROCESSOR_ARCHITECTURE -eq "AMD64") {
    Write-Check "PASS" "Architecture: x64"
} else {
    Write-Check "FAIL" "x64 architecture required. Current: $env:PROCESSOR_ARCHITECTURE"
    $errors++
}

# Port 8080
$port8080 = Get-NetTCPConnection -LocalPort 8080 -ErrorAction SilentlyContinue
if ($port8080) {
    $pid8080 = $port8080[0].OwningProcess
    $proc = Get-Process -Id $pid8080 -ErrorAction SilentlyContinue
    Write-Check "WARN" "Port 8080 in use by $($proc.ProcessName) (PID $pid8080)"
    $warnings++
} else {
    Write-Check "PASS" "Port 8080 available"
}

# Port 9090
$port9090 = Get-NetTCPConnection -LocalPort 9090 -ErrorAction SilentlyContinue
if ($port9090) {
    $pid9090 = $port9090[0].OwningProcess
    $proc = Get-Process -Id $pid9090 -ErrorAction SilentlyContinue
    Write-Check "WARN" "Port 9090 in use by $($proc.ProcessName) (PID $pid9090)"
    $warnings++
} else {
    Write-Check "PASS" "Port 9090 available"
}

# PostgreSQL
$pgService = Get-Service -Name "postgresql*" -ErrorAction SilentlyContinue
if ($pgService) {
    Write-Check "PASS" "PostgreSQL service found: $($pgService.Name) ($($pgService.Status))"
} else {
    Write-Check "WARN" "No local PostgreSQL service found. Ensure PostgreSQL is accessible."
    $warnings++
}

# Disk space
$drive = (Get-Item "C:\").PSDrive
$freeGB = [math]::Round($drive.Free / 1GB, 1)
if ($freeGB -ge 10) {
    Write-Check "PASS" "Disk space: ${freeGB} GB free"
} elseif ($freeGB -ge 1) {
    Write-Check "WARN" "Low disk space: ${freeGB} GB free (10 GB+ recommended)"
    $warnings++
} else {
    Write-Check "FAIL" "Insufficient disk space: ${freeGB} GB free (1 GB minimum)"
    $errors++
}

# Summary
Write-Host ""
if ($errors -gt 0) {
    Write-Host "Preflight failed: $errors error(s), $warnings warning(s)" -ForegroundColor Red
    exit 1
} elseif ($warnings -gt 0) {
    Write-Host "Preflight passed with $warnings warning(s)" -ForegroundColor Yellow
    exit 0
} else {
    Write-Host "All checks passed" -ForegroundColor Green
    exit 0
}
