# Generates module manifests for MediaCopy modules if missing
param()

$mods = @('CopyOps','Elevation','ExtensionMap','Index','Logging','Config','Baseline')
foreach ($m in $mods) {
    $psm1 = Join-Path $PSScriptRoot ("$m.psm1")
    $psd1 = Join-Path $PSScriptRoot ("$m.psd1")
    if (-not (Test-Path -LiteralPath $psm1)) {
        Write-Host "Skipping ${m}: module file not found"
        continue
    }
    if (-not (Test-Path -LiteralPath $psd1)) {
        New-ModuleManifest -Path $psd1 -RootModule (Split-Path -Leaf $psm1) -ModuleVersion '1.0.0' -Author 'MediaCopy' -CompanyName 'MediaCopy' -FunctionsToExport '*' -PowerShellVersion '7.0'
        Write-Host "Created $psd1"
    } else {
        Write-Host "Exists: $psd1"
    }
}