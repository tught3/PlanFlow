param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Args
)

$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$SkipFluxOsSession = $env:PLANFLOW_SKIP_FLUXOS_SESSION -in @('1', 'true', 'TRUE', 'yes', 'YES')
if (-not $SkipFluxOsSession) {
  . (Join-Path $WorkspaceRoot '.fluxos\scripts\fluxos-session-bootstrap.ps1')
}

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ProjectGradleHome = Join-Path $ProjectRoot '.gradle-local\gradle-home'
New-Item -ItemType Directory -Force -Path $ProjectGradleHome | Out-Null
$env:GRADLE_USER_HOME = $ProjectGradleHome

$session = $null
$exitCode = 0
try {
  try {
    $session = Start-FluxOsProjectSession -Project 'PlanFlow' -Source 'flutter-local' -Owner 'PlanFlow-local' -Label 'PlanFlow Flutter 런처' -Note ("flutter {0}" -f (($Args -join ' ').Trim())) -Cwd $ProjectRoot -PreferCurrentProjectSession
  } catch {
    Write-Warning ("FluxOS session registration skipped; continuing local Flutter command. {0}" -f $_.Exception.Message)
  }

  $defineFile = Join-Path $PSScriptRoot '..\env\local.json'
  $fallbackDefineFile = Join-Path $PSScriptRoot '..\env\local.example.json'
  if (-not (Test-Path $defineFile)) {
    if (Test-Path $fallbackDefineFile) {
      $defineFile = $fallbackDefineFile
      Write-Warning "Missing env/local.json; falling back to env/local.example.json"
    } else {
      Write-Warning "Missing local define file and example fallback; continuing without injected dart-defines."
      $defineFile = $null
    }
  }


  if ($Args.Count -eq 0) {
    & flutter
    $exitCode = $LASTEXITCODE
    return
  }

  $command = $Args[0]
  $flutterArgs = @($Args)

  if ($command -eq 'deploy') {
    $deployHelper = 'E:\AI_WIKI\scripts\flutter-deploy-or-copy.ps1'
    if (-not (Test-Path -LiteralPath $deployHelper)) {
      throw "Missing deploy helper: $deployHelper"
    }
    $tailArgs = @()
    if ($Args.Count -gt 1) {
      $tailArgs = @($Args[1..($Args.Count - 1)])
    }
    $deployExtraArgs = @()
    if ($defineFile) {
      $deployExtraArgs += "--dart-define-from-file=$defineFile"
    }
    $extraJson = ConvertTo-Json -Compress -InputObject @($deployExtraArgs)
    $deployCommand = @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass',
      '-File', $deployHelper,
      '-ProjectPath', $ProjectRoot,
      '-Project', 'PlanFlow',
      '-Owner', 'PlanFlow-local',
      '-ExtraBuildArgsJson', $extraJson
    ) + $tailArgs
    & powershell @deployCommand
    $exitCode = $LASTEXITCODE
    return
  }

  $commandsWithDefines = @('build', 'run', 'test')
  if ($defineFile -and $commandsWithDefines -contains $command) {
    $defineArgs = @("--dart-define-from-file=$defineFile")
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
