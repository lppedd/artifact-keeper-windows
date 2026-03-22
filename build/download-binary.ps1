#Requires -Version 5.1
param(
    [Parameter(Mandatory)]
    [string]$Version
)

$tag = "v$Version"
$asset = "artifact-keeper-windows-amd64.exe"
$url = "https://github.com/artifact-keeper/artifact-keeper/releases/download/$tag/$asset"

Write-Host "Downloading $asset from release $tag..."
Invoke-WebRequest -Uri $url -OutFile "artifact-keeper.exe"

$hash = (Get-FileHash "artifact-keeper.exe" -Algorithm SHA256).Hash
Write-Host "SHA256: $hash"
Write-Host "Downloaded artifact-keeper.exe ($((Get-Item artifact-keeper.exe).Length / 1MB) MB)"
