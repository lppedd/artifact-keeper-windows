#Requires -Version 5.1
param(
    [Parameter(Mandatory)]
    [string]$Version
)

$binaryPath = Join-Path $PSScriptRoot "..\artifact-keeper.exe"
if (-not (Test-Path $binaryPath)) {
    Write-Error "artifact-keeper.exe not found. Run download-binary.ps1 first."
    exit 1
}

# Convert semver to MSI-compatible version
$msiVersion = $Version
if ($Version -match "^(\d+\.\d+\.\d+)-.*?(\d+)$") {
    $msiVersion = "$($Matches[1]).$($Matches[2])"
}

$outputPath = "ArtifactKeeper-$Version-x64.msi"

Write-Host "Building MSI version $msiVersion..."
wix build src/wix/Product.wxs `
    -d "Version=$msiVersion" `
    -d "BinaryPath=$binaryPath" `
    -o $outputPath

if ($LASTEXITCODE -eq 0) {
    $hash = (Get-FileHash $outputPath -Algorithm SHA256).Hash
    "$hash  $outputPath" | Set-Content "$outputPath.sha256"
    Write-Host "Built: $outputPath"
    Write-Host "SHA256: $hash"
} else {
    Write-Error "WiX build failed"
    exit 1
}
