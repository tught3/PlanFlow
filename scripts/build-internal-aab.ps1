param(
  [string[]]$TestTargets = @(
    'test/services/voice_command_pipeline_test.dart',
    'test/services/voice_conversation_controller_test.dart',
    'test/services/manual_event_side_effect_service_test.dart',
    'test/widgets/calendar_style_event_editor_test.dart',
    'test/screens/event_edit_screen_test.dart',
    'test/screens/voice_conversation_screen_test.dart'
  ),
  [string]$StatusPath,
  [switch]$SkipVersionBump,
  [switch]$SkipTests,
  [switch]$SkipFluxOsSession,
  [ValidateRange(60, 900)]
  [int]$AnalyzeTimeoutSeconds = 900,
  [ValidateRange(60, 900)]
  [int]$AnalyzeFallbackTimeoutSeconds = 700,
  [string]$AnalyzeAuditPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FlutterLocal = Join-Path $PSScriptRoot 'flutter-local.ps1'
$PubspecPath = Join-Path $WorkspaceRoot 'pubspec.yaml'
$AabPath = Join-Path $WorkspaceRoot 'build\app\outputs\bundle\release\app-release.aab'
$DeployLogDir = Join-Path $WorkspaceRoot '.deploy-logs'
$PreviousPlanFlowSkipFluxOsSession = $env:PLANFLOW_SKIP_FLUXOS_SESSION
if ($SkipFluxOsSession) {
  $env:PLANFLOW_SKIP_FLUXOS_SESSION = '1'
}

function Write-Stage([string]$Message) {
  Write-Host ""
  Write-Host "== $Message =="
}

function Write-DeployStatus {
  param([Parameter(Mandatory = $true)][string]$Stage)
  if ([string]::IsNullOrWhiteSpace($StatusPath)) {
    return
  }

  $encoding = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($StatusPath, $Stage, $encoding)
}

function Ensure-DeployLogDir {
  if (-not (Test-Path -LiteralPath $DeployLogDir)) {
    New-Item -ItemType Directory -Path $DeployLogDir -Force | Out-Null
  }
}

function New-DeployLogPath {
  param([Parameter(Mandatory = $true)][string]$Stage)
  Ensure-DeployLogDir
  $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
  return Join-Path $DeployLogDir ("{0}-{1}-{2}.log" -f $Stage, $stamp, ([guid]::NewGuid().ToString('N')))
}

function Write-AnalyzeAudit {
  param(
    [Parameter(Mandatory = $true)][string]$Event,
    [hashtable]$Details = @{}
  )

  $entry = [ordered]@{
    timestamp = [DateTime]::Now.ToString('o')
    event = $Event
  }
  foreach ($key in $Details.Keys) {
    $entry[$key] = $Details[$key]
  }
  Add-Content -LiteralPath $AnalyzeAuditPath -Value ($entry | ConvertTo-Json -Compress) -Encoding utf8
}

function Read-LogLinesWithRetry {
  param([Parameter(Mandatory = $true)][string]$Path)

  # This log file may have just had its writer process (or Start-Process's
  # own redirect handle) killed by a caller-side timeout a moment ago. The
  # OS/.NET can still be mid-release of the file handle for a brief window
  # right after the process is reported exited -- observed as "cannot
  # access the file ... because it is being used by another process" on
  # this exact read. Retry briefly (same pattern as Invoke-OwnedProcess's
  # stderr-append retry) instead of failing the whole deploy on a
  # transient lock. If the retries are exhausted, rethrow -- silently
  # returning empty results here would hide the real analyze/build
  # failure instead of surfacing it.
  $encoding = [System.Text.UTF8Encoding]::new($false)
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    try {
      return [System.IO.File]::ReadAllLines($Path, $encoding)
    } catch {
      if ($attempt -eq 5) { throw }
      Start-Sleep -Milliseconds (200 * $attempt)
    }
  }
}

function New-LogExcerpt {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$Before = 12,
    [int]$After = 24,
    [int]$MaxLines = 50
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return @()
  }

  $lines = Read-LogLinesWithRetry -Path $Path
  if (-not $lines -or $lines.Count -eq 0) {
    return @()
  }

  $matchIndex = $null
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*(info|warning|error)\s+-\s+') {
      $matchIndex = $i
      break
    }
  }

  if ($null -eq $matchIndex) {
    $start = [Math]::Max(0, $lines.Count - $MaxLines)
    return $lines[$start..($lines.Count - 1)]
  }

  $startIndex = [Math]::Max(0, $matchIndex - $Before)
  $endIndex = [Math]::Min($lines.Count - 1, $matchIndex + $After)
  if (($endIndex - $startIndex + 1) -gt $MaxLines) {
    $endIndex = $startIndex + $MaxLines - 1
  }
  return $lines[$startIndex..$endIndex]
}

function Get-EntryCount {
  param([Parameter(Mandatory = $true)]$Value)

  if ($null -eq $Value) {
    return 0
  }
  if ($Value -is [array]) {
    return $Value.Count
  }
  return 1
}

function Get-AnalyzeIssueLine {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  $lines = Read-LogLinesWithRetry -Path $Path
  foreach ($line in $lines) {
    if ($line -match '^\s*(info|warning|error)\s+-\s+.+\s+-\s+.+:\d+:\d+\s+-\s+.+$') {
      return $line.Trim()
    }
  }

  foreach ($line in $lines) {
    if ($line -match '^\s*(info|warning|error)\s+-\s+') {
      return $line.Trim()
    }
  }

  return $null
}

function Get-BuildFailureExcerpt {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return [pscustomobject]@{
      PrimaryLine = $null
      ExcerptText = $null
    }
  }

  $encoding = [System.Text.UTF8Encoding]::new($false)
  $lines = [System.IO.File]::ReadAllLines($Path, $encoding)
  if (-not $lines -or $lines.Count -eq 0) {
    return [pscustomobject]@{
      PrimaryLine = $null
      ExcerptText = $null
    }
  }

  $fatalPatterns = @(
    '^\s*FAILURE:\s+Build failed with an exception\.\s*$',
    '^\s*\*\s+What went wrong:\s*$',
    '^\s*\*\s+Try:\s*$',
    '^\s*Execution failed for task\s+',
    '^\s*> Task .+ FAILED\s*$',
    '^\s*Caused by:\s*'
  )

  $startIndex = $null
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    $isFatal = $false
    foreach ($pattern in $fatalPatterns) {
      if ($line -match $pattern) {
        $isFatal = $true
        break
      }
    }
    if ($isFatal) {
      $startIndex = [Math]::Max(0, $i - 4)
      break
    }
  }

  if ($null -eq $startIndex) {
    foreach ($i in 0..($lines.Count - 1)) {
      $line = $lines[$i]
      if ($line -match '^\s*error:\s+' -or $line -match '^[^:]+:\d+:\d+:\s+error:\s+' -or $line -match '^\s*Exception in thread\s+\"') {
        $startIndex = [Math]::Max(0, $i - 4)
        break
      }
    }
  }

  if ($null -eq $startIndex) {
    return [pscustomobject]@{
      PrimaryLine = $null
      ExcerptText = $null
    }
  }

  $endIndex = [Math]::Min($lines.Count - 1, $startIndex + 40)
  if (($endIndex - $startIndex + 1) -gt 50) {
    $endIndex = $startIndex + 49
  }

  $excerpt = $lines[$startIndex..$endIndex]
  $primaryLine = $null
  foreach ($line in $excerpt) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }
    if ($line -match '^\s*(Note:|warning:|Warning:|uses unchecked or unsafe operations|uses deprecated API|unchecked or unsafe operations)') {
      continue
    }
    if ($line -match '^\s*FAILURE:\s+Build failed with an exception\.\s*$') {
      continue
    }
    if ($line -match '^\s*\*\s+What went wrong:\s*$') {
      continue
    }
    if ($line -match '^\s*\*\s+Try:\s*$') {
      continue
    }
    if ($line -match '^\s*> Task .+ FAILED\s*$') {
      continue
    }
    $primaryLine = $line.Trim()
    break
  }

  if ([string]::IsNullOrWhiteSpace($primaryLine)) {
    return [pscustomobject]@{
      PrimaryLine = $null
      ExcerptText = $null
    }
  }

  return [pscustomobject]@{
    PrimaryLine = $primaryLine
    ExcerptText = ($excerpt -join "`n")
  }
}

function Invoke-Checked([scriptblock]$Action, [string]$Label) {
  Write-Host $Label
  & $Action
  if ($LASTEXITCODE -ne 0) {
    throw "$Label failed with exit code $LASTEXITCODE."
  }
}

function Invoke-OwnedProcess {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$ArgumentList,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
    [Parameter(Mandatory = $true)][string]$Stage
  )

  $errorPath = "$OutputPath.stderr"
  $exitCodePath = "$OutputPath.exitcode"
  Remove-Item -LiteralPath $OutputPath, $errorPath, $exitCodePath -Force -ErrorAction SilentlyContinue
  New-Item -ItemType File -Path $OutputPath -Force | Out-Null

  # Process.ExitCode read via Start-Process -PassThru has been observed to
  # return $null even after WaitForExit() (twice, with the parameterless
  # overload) confirms the process exited -- audit logs showed
  # exit_code:null on runs whose stdout clearly printed "No issues found!".
  # Rather than trust that unreliable .NET property, wrap the real command
  # so the child process reports its own $LASTEXITCODE (set reliably by the
  # PowerShell call operator `&` for any external command) into a file, and
  # read that back instead.
  $quotedArgs = ($ArgumentList | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ' '
  $quotedFilePath = "'" + ($FilePath -replace "'", "''") + "'"
  $quotedExitCodePath = "'" + ($exitCodePath -replace "'", "''") + "'"
  $wrapperCommand = "& $quotedFilePath $quotedArgs; Set-Content -LiteralPath $quotedExitCodePath -Value `$LASTEXITCODE -NoNewline -Encoding ascii"

  $startInfo = @{
    FilePath = 'powershell.exe'
    ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $wrapperCommand)
    WorkingDirectory = $WorkspaceRoot
    PassThru = $true
    RedirectStandardOutput = $OutputPath
    RedirectStandardError = $errorPath
    WindowStyle = 'Hidden'
  }
  $process = Start-Process @startInfo
  Write-AnalyzeAudit -Event 'started' -Details @{ stage = $Stage; pid = $process.Id; timeout_seconds = $TimeoutSeconds }

  $completed = $process.WaitForExit($TimeoutSeconds * 1000)
  if (-not $completed) {
    # This tree was launched by this script, so it cannot include another session's analyzer.
    & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null
    # Same transient-lock window as the stderr-append retry below: right
    # after taskkill reports the process dead, Start-Process's own
    # RedirectStandardOutput handle for $OutputPath can still be mid-release
    # by the OS/.NET for a brief moment (observed as "cannot access the
    # file ... because it is being used by another process" on this exact
    # Add-Content call, which previously had no retry and crashed the whole
    # deploy with an unhandled exception before the 'timed_out' audit event
    # was even written). Retry briefly instead of failing outright.
    for ($attempt = 1; $attempt -le 5; $attempt++) {
      try {
        Add-Content -LiteralPath $OutputPath -Value "`n[timeout] Owned process exceeded $TimeoutSeconds seconds and was stopped." -Encoding utf8
        break
      } catch {
        if ($attempt -eq 5) { throw }
        Start-Sleep -Milliseconds (200 * $attempt)
      }
    }
    Write-AnalyzeAudit -Event 'timed_out' -Details @{ stage = $Stage; pid = $process.Id; timeout_seconds = $TimeoutSeconds }
    $exitCode = $null
  } else {
    $process.WaitForExit()
    $exitCodeSource = 'process'
    if (Test-Path -LiteralPath $exitCodePath) {
      $exitCodeText = (Get-Content -LiteralPath $exitCodePath -Raw).Trim()
      if ($exitCodeText -match '^-?\d+$') {
        $exitCode = [int]$exitCodeText
        $exitCodeSource = 'file'
      } else {
        $exitCode = $process.ExitCode
      }
    } else {
      $exitCode = $process.ExitCode
    }
    Write-AnalyzeAudit -Event 'exited' -Details @{ stage = $Stage; pid = $process.Id; exit_code = $exitCode; exit_code_source = $exitCodeSource }
  }

  if (Test-Path -LiteralPath $errorPath) {
    # Start-Process's own redirect handle for $OutputPath can still be
    # mid-release by the OS/.NET for a brief moment right after the process
    # is reported exited (observed as "cannot access the file ... because it
    # is being used by another process" on this exact Add-Content call).
    # Retry briefly instead of failing the whole deploy on a transient lock.
    $stderrContent = Get-Content -LiteralPath $errorPath -Raw
    $appended = $false
    for ($attempt = 1; $attempt -le 5; $attempt++) {
      try {
        Add-Content -LiteralPath $OutputPath -Value $stderrContent -Encoding utf8
        $appended = $true
        break
      } catch {
        if ($attempt -eq 5) { throw }
        Start-Sleep -Milliseconds (200 * $attempt)
      }
    }
    Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $exitCodePath -Force -ErrorAction SilentlyContinue

  return [pscustomobject]@{
    ExitCode = $exitCode
    TimedOut = -not $completed
  }
}

function Invoke-BoundedAnalyze {
  param([Parameter(Mandatory = $true)][string]$PrimaryLogPath)

  # The bounded child must not create a FluxOS session that a timeout could strand.
  $previousSkipFluxOsSession = $env:PLANFLOW_SKIP_FLUXOS_SESSION
  try {
    $env:PLANFLOW_SKIP_FLUXOS_SESSION = '1'
    $flutterResult = Invoke-OwnedProcess -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FlutterLocal, 'analyze', '--no-pub') -OutputPath $PrimaryLogPath -TimeoutSeconds $AnalyzeTimeoutSeconds -Stage 'flutter'
  } finally {
    if ($null -eq $previousSkipFluxOsSession) {
      Remove-Item Env:PLANFLOW_SKIP_FLUXOS_SESSION -ErrorAction SilentlyContinue
    } else {
      $env:PLANFLOW_SKIP_FLUXOS_SESSION = $previousSkipFluxOsSession
    }
  }

  if (-not $flutterResult.TimedOut) {
    Write-AnalyzeAudit -Event 'primary_complete' -Details @{ exit_code = $flutterResult.ExitCode }
    return $flutterResult
  }

  $fallbackLogPath = New-DeployLogPath -Stage 'analyze-dart-fallback'
  Add-Content -LiteralPath $PrimaryLogPath -Value "`n[recovery] Flutter analyze timed out. Retrying once with direct Dart analyzer." -Encoding utf8
  $flutter = (Get-Command flutter -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
  $dart = Join-Path (Split-Path -Parent $flutter) 'cache\dart-sdk\bin\dart.exe'
  if (-not (Test-Path -LiteralPath $dart)) {
    Write-AnalyzeAudit -Event 'fallback_unavailable' -Details @{ dart_path = $dart }
    throw "Flutter SDK Dart analyzer not found: $dart"
  }
  $dartResult = Invoke-OwnedProcess -FilePath $dart -ArgumentList @('analyze') -OutputPath $fallbackLogPath -TimeoutSeconds $AnalyzeFallbackTimeoutSeconds -Stage 'dart-fallback'

  if (Test-Path -LiteralPath $fallbackLogPath) {
    Add-Content -LiteralPath $PrimaryLogPath -Value ("`n[direct-dart-analyze]`n" + (Get-Content -LiteralPath $fallbackLogPath -Raw)) -Encoding utf8
  }

  $dartResult | Add-Member -NotePropertyName UsedDirectDartFallback -NotePropertyValue $true
  Write-AnalyzeAudit -Event 'recovery_complete' -Details @{ fallback_exit_code = $dartResult.ExitCode; fallback_timed_out = $dartResult.TimedOut }
  return $dartResult
}

function Read-PubspecVersion {
  param([Parameter(Mandatory = $true)][string]$Path)
  $encoding = [System.Text.UTF8Encoding]::new($false)
  $content = [System.IO.File]::ReadAllText($Path, $encoding)
  $match = [regex]::Match($content, '(?m)^\s*version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+(\d+)\s*(#.*)?$')
  if (-not $match.Success) {
    throw "Unable to read version from pubspec.yaml."
  }
  return "$($match.Groups[1].Value)+$($match.Groups[2].Value)"
}

try {
  if ([string]::IsNullOrWhiteSpace($AnalyzeAuditPath)) {
    $AnalyzeAuditPath = New-DeployLogPath -Stage 'analyze-audit'
  }
  if (-not (Test-Path -LiteralPath $FlutterLocal)) {
    throw "flutter-local.ps1 not found: $FlutterLocal"
  }

  Write-Stage "PlanFlow internal test AAB build"

  $versionInfo = $null
  if (-not $SkipVersionBump) {
    Write-DeployStatus 'version-bump'
    Write-Stage "Bumping version code"
    $versionInfo = & (Join-Path $PSScriptRoot 'bump-version-code.ps1') -PubspecPath $PubspecPath
    if (-not $versionInfo) {
      throw "Version bump failed."
    }
    if ($versionInfo.PSObject.Properties.Name -contains 'OldVersion' -and $versionInfo.PSObject.Properties.Name -contains 'NewVersion') {
      Write-Host "Version changed: $($versionInfo.OldVersion) -> $($versionInfo.NewVersion)"
    } else {
      $currentVersion = Read-PubspecVersion -Path $PubspecPath
      Write-Host "Version now: $currentVersion"
    }
  } else {
    Write-Host "Skipping version bump at user request."
    $currentVersion = Read-PubspecVersion -Path $PubspecPath
    Write-Host "Current version: $currentVersion"
  }

  Write-DeployStatus 'analyze'
  Write-Stage "Running analyze"
  $analyzeLogPath = New-DeployLogPath -Stage 'analyze'
  $analyzeResult = Invoke-BoundedAnalyze -PrimaryLogPath $analyzeLogPath
  if ($analyzeResult.TimedOut -or $analyzeResult.ExitCode -ne 0) {
    $analyzeIssueLine = Get-AnalyzeIssueLine -Path $analyzeLogPath
    $excerptLines = New-LogExcerpt -Path $analyzeLogPath
    $excerptText = if ((Get-EntryCount -Value $excerptLines) -gt 0) { $excerptLines -join "`n" } else { 'No analyze excerpt available.' }
    Write-Host ''
    Write-Host "Analyze log: $analyzeLogPath"
    if ($analyzeIssueLine) {
      Write-Host "Analyze issue: $analyzeIssueLine"
    }
    Write-Host 'Analyze excerpt:'
    $excerptLines | ForEach-Object { Write-Host $_ }
    if ($analyzeIssueLine) {
      throw "Step: analyze`nAnalyze log: $analyzeLogPath`nAnalyze issue: $analyzeIssueLine`nAnalyze excerpt:`n$excerptText"
    }
    throw "Step: analyze`nAnalyze log: $analyzeLogPath`nAnalyze issue: 실제 오류를 로그에서 찾지 못했습니다. 전체 로그 확인 필요.`nAnalyze excerpt:`n$excerptText"
  }

  Write-DeployStatus 'tests'
  Write-Stage "Running focused tests"
  if ($SkipTests -or -not $TestTargets -or $TestTargets.Count -eq 0) {
    Write-Host "Skipping focused tests because no requested test files were present."
  } else {
    $testArgs = @('test') + $TestTargets + @('--no-pub')
    Invoke-Checked { & $FlutterLocal @testArgs } ("scripts/flutter-local.ps1 test {0} --no-pub" -f ($TestTargets -join ' '))
  }

  Write-DeployStatus 'build'
  Write-Stage "Building release appbundle"
  $buildLogPath = New-DeployLogPath -Stage 'build'
  $buildOutput = & $FlutterLocal build appbundle --release --no-pub 2>&1 | Tee-Object -FilePath $buildLogPath
  if ($LASTEXITCODE -ne 0) {
    $buildDetails = Get-BuildFailureExcerpt -Path $buildLogPath
    Write-Host ''
    Write-Host "Build log: $buildLogPath"
    if ($buildDetails.PrimaryLine) {
      Write-Host "Build issue: $($buildDetails.PrimaryLine)"
      Write-Host 'Build excerpt:'
      $buildDetails.ExcerptText -split "`r?`n" | ForEach-Object { Write-Host $_ }
      throw "Step: build`nBuild log: $buildLogPath`nBuild issue: $($buildDetails.PrimaryLine)`nBuild excerpt:`n$($buildDetails.ExcerptText)"
    }
    throw "Step: build`nBuild log: $buildLogPath`nBuild issue: 실제 실패 원인을 로그에서 찾지 못했습니다. 전체 로그 확인 필요."
  }

  if (-not (Test-Path -LiteralPath $AabPath)) {
    throw "AAB was not generated at: $AabPath"
  }

  $resolvedAabPath = (Resolve-Path -LiteralPath $AabPath).Path
  $finalVersion = $null
  if ($versionInfo -is [System.Management.Automation.PSObject]) {
    if ($versionInfo.PSObject.Properties.Name -contains 'NewVersion') {
      $finalVersion = [string]$versionInfo.NewVersion
    } elseif ($versionInfo.PSObject.Properties.Name -contains 'OldVersion') {
      $finalVersion = [string]$versionInfo.OldVersion
    }
  } elseif ($versionInfo -is [array]) {
    $objectCandidate = $versionInfo | Where-Object {
      $_ -is [System.Management.Automation.PSObject] -and $_.PSObject.Properties.Name -contains 'NewVersion'
    } | Select-Object -First 1
    if ($objectCandidate) {
      $finalVersion = [string]$objectCandidate.NewVersion
    }
  }

  if ([string]::IsNullOrWhiteSpace($finalVersion)) {
    $finalVersion = Read-PubspecVersion -Path $PubspecPath
    Write-Host "Version info fallback used from pubspec.yaml: $finalVersion"
  }

  Write-DeployStatus 'done'
  Write-Host ''
  Write-Host '========================================'
  Write-Host 'PlanFlow Internal Test AAB Ready'
  Write-Host "Version: $finalVersion"
  Write-Host 'AAB:'
  Write-Host $resolvedAabPath
  Write-Host ''
  Write-Host 'Next:'
  Write-Host 'Google Play Console -> PlanFlow -> 내부 테스트 -> 새 버전 만들기 -> 위 AAB 업로드'
  Write-Host '========================================'

  return [pscustomobject]@{
    OldVersion = if ($versionInfo -and $versionInfo.PSObject.Properties.Name -contains 'OldVersion') { [string]$versionInfo.OldVersion } else { $null }
    NewVersion = $finalVersion
    AabPath    = $resolvedAabPath
  }
} catch {
  Write-Error $_
  exit 1
} finally {
  if ($SkipFluxOsSession) {
    if ($null -eq $PreviousPlanFlowSkipFluxOsSession) {
      Remove-Item Env:PLANFLOW_SKIP_FLUXOS_SESSION -ErrorAction SilentlyContinue
    } else {
      $env:PLANFLOW_SKIP_FLUXOS_SESSION = $PreviousPlanFlowSkipFluxOsSession
    }
  }
}
