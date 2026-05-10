param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Args
)

$defineFile = Join-Path $PSScriptRoot '..\env\local.json'
$defineArg = "--dart-define-from-file=$defineFile"

if (-not (Test-Path $defineFile)) {
  throw "Missing local define file: $defineFile"
}

if ($Args.Count -eq 0) {
  & flutter
  exit $LASTEXITCODE
}

$command = $Args[0]
$flutterArgs = @($Args)

$supportsDefines = $command -in @('run', 'build', 'test', 'drive', 'attach', 'install', 'assemble')
if ($supportsDefines -and ($flutterArgs -notcontains $defineArg)) {
  $flutterArgs = @($command, $defineArg) + $Args[1..($Args.Count - 1)]
}

& flutter @flutterArgs
exit $LASTEXITCODE
