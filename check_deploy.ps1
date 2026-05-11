$errs = $null
[System.Management.Automation.Language.Parser]::ParseFile('C:\repos\sentinel-tvm-function-based-connector\deploy.ps1', [ref]$null, [ref]$errs) | Out-Null
if ($errs) {
    $errs | ForEach-Object { $_.Message }
    exit 1
} else {
    Write-Output 'PASS deploy.ps1'
    exit 0
}
