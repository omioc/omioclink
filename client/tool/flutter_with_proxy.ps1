param(
  [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)]
  [string[]]$Arguments
)

$env:HTTP_PROXY = 'http://127.0.0.1:7897'
$env:HTTPS_PROXY = 'http://127.0.0.1:7897'

& flutter @Arguments
exit $LASTEXITCODE
