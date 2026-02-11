param(
    [string]$CyberFoilPath = "C:\Users\User\Documents\GitHub\CyberFoil",
    [string]$SourceDir = "$PSScriptRoot\artefacts",
    [string]$OutputDir = "$PSScriptRoot\release\offline_db",
    [string]$ManifestBaseUrl = "https://github.com/luketanti/CyberFoil-DB/releases/latest/download",
    [string]$ManifestName = "offline_db_manifest.json",
    [string]$DbVersion = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($DbVersion)) {
    $DbVersion = [DateTime]::UtcNow.ToString("yyyyMMddHHmmss")
}

$exporter = Join-Path $CyberFoilPath "tools\export_offline_db.py"

if (-not (Test-Path -LiteralPath $exporter)) {
    throw "export_offline_db.py not found at: $exporter"
}

if (-not (Test-Path -LiteralPath $SourceDir)) {
    throw "Source directory not found: $SourceDir"
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

Write-Host "Using exporter: $exporter"
Write-Host "Source dir:    $SourceDir"
Write-Host "Output dir:    $OutputDir"
Write-Host "DB version:    $DbVersion"
Write-Host "Manifest URL:  $ManifestBaseUrl"
Write-Host "Manifest name: $ManifestName"

$py = Get-Command py -ErrorAction SilentlyContinue
if ($null -eq $py) {
    throw "Python launcher 'py' was not found in PATH."
}

& py -3 $exporter `
    --source-dir $SourceDir `
    --output-dir $OutputDir `
    --manifest-base-url $ManifestBaseUrl `
    --manifest-name $ManifestName `
    --db-version $DbVersion

if ($LASTEXITCODE -ne 0) {
    throw "export_offline_db.py failed with exit code $LASTEXITCODE"
}

Write-Host "Done. Generated files in: $OutputDir"
