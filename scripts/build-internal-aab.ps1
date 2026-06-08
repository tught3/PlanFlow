param(
  [string[]]$TestTargets = @(
    'test/services/voice_command_pipeline_test.dart',
    'test/services/voice_conversation_controller_test.dart',
    'test/services/manual_event_side_effect_service_test.dart',
    'test/widgets/calendar_style_event_editor_test.dart',
    'test/screens/event_edit_screen_test.dart',
    'test/screens/voice_conversation_screen_test.dart'
  ),
  [switch]$SkipVersionBump,
  [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FlutterLocal = Join-Path $PSScriptRoot 'flutter-local.ps1'
$PubspecPath = Join-Path $WorkspaceRoot 'pubspec.yaml'
$AabPath = Join-Path $WorkspaceRoot 'build\app\outputs\bundle\release\app-release.aab'

function Write-Stage([string]$Message) {
  Write-Host ""
  Write-Host "== $Message =="
}

function Invoke-Checked([scriptblock]$Action, [string]$Label) {
  Write-Host $Label
  & $Action
  if ($LASTEXITCODE -ne 0) {
    throw "$Label failed with exit code $LASTEXITCODE."
  }
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
  if (-not (Test-Path -LiteralPath $FlutterLocal)) {
    throw "flutter-local.ps1 not found: $FlutterLocal"
  }

  Write-Stage "PlanFlow internal test AAB build"

  $versionInfo = $null
  if (-not $SkipVersionBump) {
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

  Write-Stage "Running analyze"
  Invoke-Checked { & $FlutterLocal analyze --no-pub } 'scripts/flutter-local.ps1 analyze --no-pub'

  Write-Stage "Running focused tests"
  if ($SkipTests -or -not $TestTargets -or $TestTargets.Count -eq 0) {
    Write-Host "Skipping focused tests because no requested test files were present."
  } else {
    $testArgs = @('test') + $TestTargets + @('--no-pub')
    Invoke-Checked { & $FlutterLocal @testArgs } ("scripts/flutter-local.ps1 test {0} --no-pub" -f ($TestTargets -join ' '))
  }

  Write-Stage "Building release appbundle"
  Invoke-Checked { & $FlutterLocal build appbundle --release --no-pub } 'scripts/flutter-local.ps1 build appbundle --release --no-pub'

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
}
