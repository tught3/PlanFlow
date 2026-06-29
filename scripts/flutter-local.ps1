param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Args
)

$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$SkipFluxOsSession = $env:PLANFLOW_SKIP_FLUXOS_SESSION -in @('1', 'true', 'TRUE', 'yes', 'YES')
if (-not $SkipFluxOsSession) {
  . (Join-Path $WorkspaceRoot '.fluxos\scripts\fluxos-session-bootstrap.ps1')
}

$session = $null
$exitCode = 0
try {
  if (-not $SkipFluxOsSession) {
    $session = Start-FluxOsProjectSession -Project 'PlanFlow' -Source 'flutter-local' -Owner 'PlanFlow-local' -Label 'PlanFlow Flutter 런처' -Note ("flutter {0}" -f (($Args -join ' ').Trim())) -Cwd (Resolve-Path (Join-Path $PSScriptRoot '..')).Path -PreferCurrentProjectSession
  }

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
  $defineSupportedCommands = @('build', 'run', 'test', 'drive')

  if ($command -eq 'deploy') {
    $deployHelper = 'E:\AI_WIKI\scripts\flutter-deploy-or-copy.ps1'
    if (-not (Test-Path -LiteralPath $deployHelper)) {
      throw "Missing deploy helper: $deployHelper"
    }
    $tailArgs = @()
    if ($Args.Count -gt 1) {
      $tailArgs = @($Args[1..($Args.Count - 1)])
    }
    $extraJson = ConvertTo-Json -Compress -InputObject @($defineArgs)
    $deployCommand = @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass',
      '-File', $deployHelper,
      '-ProjectPath', (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
      '-Project', 'PlanFlow',
      '-Owner', 'PlanFlow-local',
      '-ExtraBuildArgsJson', $extraJson
    ) + $tailArgs
    & powershell @deployCommand
    $exitCode = $LASTEXITCODE
    return
  }

  if ($defineArgs.Count -gt 0 -and ($defineSupportedCommands -contains $command)) {
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
