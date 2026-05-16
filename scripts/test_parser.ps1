$errs = $null
$deployPath = Join-Path $PSScriptRoot 'deploy.ps1'
[System.Management.Automation.Language.Parser]::ParseFile($deployPath, [ref]$null, [ref]$errs) | Out-Null
if ($errs) {
    "FAIL: scripts/deploy.ps1 has syntax errors:"
    $errs | ForEach-Object { "- $($_.Message) at line $($_.Extent.StartLineNumber), col $($_.Extent.StartColumnNumber)" }
    exit 1
} else {
    "PASS: scripts/deploy.ps1 is syntactically valid."
    exit 0
}
