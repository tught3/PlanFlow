param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Args
)

$defineFile = Join-Path $PSScriptRoot '..\env\local.json'

if (-not (Test-Path $defineFile)) {
  throw "Missing local define file: $defineFile"
}

$localDefines = Get-Content $defineFile -Raw -Encoding utf8 | ConvertFrom-Json
$defineArgs = @()
foreach ($property in $localDefines.PSObject.Properties) {
  $value = [string]$property.Value
  if (-not [string]::IsNullOrWhiteSpace($value)) {
    $defineArgs += "--dart-define=$($property.Name)=$value"
  }
}

if ($Args.Count -eq 0) {
  & flutter
  exit $LASTEXITCODE
}

$command = $Args[0]
$flutterArgs = @($Args)

if ($defineArgs.Count -gt 0 -and $command -ne 'analyze') {
  if ($command -eq 'build' -and $Args.Count -ge 2) {
    $flutterArgs = @($command, $Args[1]) + $defineArgs + $Args[2..($Args.Count - 1)]
  } elseif ($Args.Count -gt 1) {
    $flutterArgs = @($command) + $defineArgs + $Args[1..($Args.Count - 1)]
  } else {
    $flutterArgs = @($command) + $defineArgs
  }
}

& flutter @flutterArgs
exit $LASTEXITCODE
