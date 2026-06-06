param(
  [Parameter(Mandatory = $true)]
  [string]$ProjectKey,

  [string]$ConfigPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..\tools')).Path 'deploy-play-config.json'),

  [switch]$SkipUpload
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Stage {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Host ""
  Write-Host "== $Message =="
}

function Read-Utf8Json {
  param([Parameter(Mandatory = $true)][string]$Path)
  $encoding = [System.Text.UTF8Encoding]::new($false)
  $jsonText = [System.IO.File]::ReadAllText($Path, $encoding)
  return $jsonText | ConvertFrom-Json
}

function Assert-FileExists {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Label
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "$Label not found: $Path"
  }
}

function Test-CommandAvailable {
  param([Parameter(Mandatory = $true)][string]$Name)
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

try {
  Assert-FileExists -Path $ConfigPath -Label 'deploy-play-config.json'

  $config = Read-Utf8Json -Path $ConfigPath
  if (-not ($config.PSObject.Properties.Name -contains $ProjectKey)) {
    $keys = $config.PSObject.Properties.Name -join ', '
    throw "Unknown project key '$ProjectKey'. Available keys: $keys"
  }

  $project = $config.$ProjectKey
  if (-not $project.enabled) {
    throw "Project '$ProjectKey' is disabled in deploy-play-config.json."
  }

  $projectPath = [System.IO.Path]::GetFullPath([string]$project.path)
  $packageName = [string]$project.packageName
  $track = [string]$project.track
  $serviceAccountJson = [System.IO.Path]::GetFullPath([string]$project.serviceAccountJson)
  $aabRelativePath = [string]$project.aabPath
  $aabPath = Join-Path $projectPath $aabRelativePath

  Write-Host "Project key: $ProjectKey"
  Write-Host "Path: $projectPath"
  Write-Host "Package: $packageName"
  Write-Host "Track: $track"
  Write-Host "Service account JSON: $serviceAccountJson"
  Write-Host "AAB path: $aabPath"

  Assert-FileExists -Path $serviceAccountJson -Label 'service account JSON'
  Assert-FileExists -Path (Join-Path $projectPath 'pubspec.yaml') -Label 'pubspec.yaml'
  Assert-FileExists -Path (Join-Path $projectPath 'scripts\flutter-local.ps1') -Label 'scripts/flutter-local.ps1'
  Assert-FileExists -Path (Join-Path $projectPath 'scripts\bump-version-code.ps1') -Label 'scripts/bump-version-code.ps1'
  Assert-FileExists -Path (Join-Path $projectPath 'scripts\build-internal-aab.ps1') -Label 'scripts/build-internal-aab.ps1'

  if (-not (Test-CommandAvailable -Name 'fastlane')) {
    Write-Host 'fastlane가 설치되어 있지 않습니다.'
    $rubyAvailable = Test-CommandAvailable -Name 'ruby'
    $gemAvailable = Test-CommandAvailable -Name 'gem'
    if (-not $rubyAvailable -or -not $gemAvailable) {
      Write-Host 'Ruby/gem이 설치되어 있지 않아 fastlane을 바로 실행할 수 없습니다.'
      Write-Host '먼저 Ruby를 설치한 뒤 아래 명령으로 fastlane을 설치하세요:'
    } else {
      Write-Host 'fastlane를 설치하려면 아래 명령을 실행하세요:'
    }
    Write-Host 'gem install fastlane'
    exit 1
  }

  Write-Stage 'Bumping version, analyzing, testing, and building AAB'

  $requestedTests = @(
    'test/services/voice_command_pipeline_test.dart',
    'test/services/voice_conversation_controller_test.dart',
    'test/services/manual_event_side_effect_service_test.dart',
    'test/widgets/calendar_style_event_editor_test.dart',
    'test/screens/event_edit_screen_test.dart',
    'test/screens/voice_conversation_screen_test.dart'
  )
  $existingTests = @()
  foreach ($relativeTest in $requestedTests) {
    $absoluteTest = Join-Path $projectPath $relativeTest
    if (Test-Path -LiteralPath $absoluteTest) {
      $existingTests += $relativeTest
    } else {
      Write-Warning "테스트 파일이 없어 건너뜁니다: $relativeTest"
    }
  }

  Push-Location $projectPath
  try {
    $buildScript = Join-Path $projectPath 'scripts\build-internal-aab.ps1'
    $buildResult = if ($existingTests.Count -gt 0) {
      & $buildScript -TestTargets $existingTests
    } else {
      & $buildScript -SkipTests
    }
    if ($LASTEXITCODE -ne 0) {
      throw "Internal AAB build failed with exit code $LASTEXITCODE."
    }
    if (-not $buildResult) {
      throw 'Internal AAB build did not return version info.'
    }
  } finally {
    Pop-Location
  }

  if (-not (Test-Path -LiteralPath $aabPath)) {
    throw "AAB file not found after build: $aabPath"
  }

  $resolvedAabPath = (Resolve-Path -LiteralPath $aabPath).Path
  $finalVersion = [string]$buildResult.NewVersion

  if (-not $SkipUpload) {
    Write-Stage 'Uploading to Google Play internal track'

    $uploadArgs = @(
      'supply',
      '--aab', $resolvedAabPath,
      '--track', $track,
      '--package_name', $packageName,
      '--json_key', $serviceAccountJson,
      '--skip_upload_metadata', 'true',
      '--skip_upload_images', 'true',
      '--skip_upload_screenshots', 'true'
    )

    & fastlane @uploadArgs
    if ($LASTEXITCODE -ne 0) {
      throw "fastlane supply failed with exit code $LASTEXITCODE."
    }
  } else {
    Write-Host 'Upload was skipped because -SkipUpload was supplied.'
  }

  Write-Host ''
  Write-Host '========================================'
  Write-Host 'PlanFlow Play Internal Upload Complete'
  Write-Host "Version: $finalVersion"
  Write-Host "Package: $packageName"
  Write-Host "Track: $track"
  Write-Host "AAB: $resolvedAabPath"
  Write-Host ''
  Write-Host 'Next:'
  Write-Host 'Open Play Store on test device and update PlanFlow.'
  Write-Host '========================================'
} catch {
  Write-Error $_
  exit 1
}
