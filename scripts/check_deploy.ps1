$errs = $null
$deployPath = Join-Path $PSScriptRoot 'deploy.ps1'
[System.Management.Automation.Language.Parser]::ParseFile($deployPath, [ref]$null, [ref]$errs) | Out-Null
if ($errs) {
    $errs | ForEach-Object { $_.Message }
    exit 1
} else {
    Write-Output 'PASS scripts/deploy.ps1'
    exit 0
}
