$errs = $null
[System.Management.Automation.Language.Parser]::ParseFile('C:\repos\sentinel-tvm-function-based-connector\deploy.ps1', [ref]$null, [ref]$errs) | Out-Null
if ($errs) {
    "FAIL: deploy.ps1 has syntax errors:"
    $errs | ForEach-Object { "- $($_.Message) at line $($_.Extent.StartLineNumber), col $($_.Extent.StartColumnNumber)" }
    exit 1
} else {
    "PASS: deploy.ps1 is syntactically valid."
    exit 0
}
