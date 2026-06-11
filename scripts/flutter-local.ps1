param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Args
)

$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $WorkspaceRoot '.fluxos\scripts\fluxos-session-bootstrap.ps1')

$session = $null
$exitCode = 0
try {
  $session = Start-FluxOsProjectSession -Project 'PlanFlow' -Source 'flutter-local' -Owner 'PlanFlow-local' -Label 'PlanFlow Flutter 런처' -Note ("flutter {0}" -f (($Args -join ' ').Trim())) -Cwd (Resolve-Path (Join-Path $PSScriptRoot '..')).Path -PreferCurrentProjectSession

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
    $exitCode = $LASTEXITCODE
    return
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
  $exitCode = $LASTEXITCODE
} finally {
  if ($session) {
    try {
      Stop-FluxOsProjectSession -SessionId $session.id -Reason 'flutter-local 종료'
    } catch {
      # 세션 종료 실패는 로컬 명령 결과를 덮어쓰지 않는다.
    }
  }
}

exit $exitCode
