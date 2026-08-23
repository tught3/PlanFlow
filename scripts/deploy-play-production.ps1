param(
  [string]$ConfigPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'config\play-production.json'),
  [switch]$ConfirmProductionRollout,
  [switch]$BuildDraft,
  [switch]$ReuseExistingAab,
  [switch]$UseSharedGradleCache,
  [switch]$SkipVersionBump,
  [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$BuildScript = Join-Path $WorkspaceRoot 'scripts\build-internal-aab.ps1'
$GradlePath = Join-Path $WorkspaceRoot 'android\gradlew.bat'
$PubspecPath = Join-Path $WorkspaceRoot 'pubspec.yaml'
$ExampleConfigPath = (Resolve-Path (Join-Path $WorkspaceRoot 'config\play-production.example.json')).Path

function Assert-File([string]$Path, [string]$Label) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Label not found: $Path"
  }
}

function Read-Json([string]$Path) {
  try { return (Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json) }
  catch { throw "Production config is not valid JSON: $Path" }
}

function Assert-ProductionConfig($Config, [bool]$ForUpload) {
  foreach ($required in @('path', 'packageName', 'track', 'serviceAccountJson', 'aabPath')) {
    if (-not ($Config.PSObject.Properties.Name -contains $required) -or [string]::IsNullOrWhiteSpace([string]$Config.$required)) {
      throw "Production config is missing '$required'."
    }
  }
  if ([string]$Config.track -ne 'production') {
    throw "Production wrapper requires track=production; found '$($Config.track)'."
  }
  if ([string]$Config.packageName -ne 'com.fluxstudio.planflow') {
    throw "Unexpected production package name '$($Config.packageName)'."
  }
  $projectPath = [System.IO.Path]::GetFullPath([string]$Config.path)
  if ($projectPath.TrimEnd('\') -ine $WorkspaceRoot.TrimEnd('\')) {
    throw "Production config path must point to this PlanFlow workspace: $WorkspaceRoot"
  }
  if ($ForUpload) {
    if (-not [bool]$Config.enabled) { throw 'Production config is disabled. Set enabled=true only in the local, untracked production config.' }
    if ([System.IO.Path]::GetFullPath($ConfigPath) -ieq $ExampleConfigPath) { throw 'The example production config cannot be used for a public rollout.' }
    $serviceAccount = [System.IO.Path]::GetFullPath([string]$Config.serviceAccountJson)
    Assert-File -Path $serviceAccount -Label 'production service account JSON'
    $serviceJson = Read-Json -Path $serviceAccount
    if ([string]$serviceJson.type -ne 'service_account') { throw 'Production service account JSON must be a service_account credential.' }
  }
}

function Read-PubspecVersion {
  $text = Get-Content -LiteralPath $PubspecPath -Raw -Encoding utf8
  $m = [regex]::Match($text, '(?m)^\s*version:\s*([^\s#]+)')
  if (-not $m.Success) { throw 'Unable to read pubspec version.' }
  return $m.Groups[1].Value
}

function Assert-ExistingAabMarker([string]$AabPath) {
  $markerPath = "$AabPath.map-marker"
  Assert-File -Path $AabPath -Label 'production AAB'
  Assert-File -Path $markerPath -Label 'production AAB map marker'

  $values = @{}
  foreach ($line in [System.IO.File]::ReadAllLines($markerPath, [System.Text.UTF8Encoding]::new($false))) {
    $separator = $line.IndexOf('=')
    if ($separator -gt 0) {
      $values[$line.Substring(0, $separator)] = $line.Substring($separator + 1)
    }
  }
  $resolvedAab = (Resolve-Path -LiteralPath $AabPath).Path
  $markerAab = if ($values.ContainsKey('aabPath')) { [string]$values['aabPath'] } else { '' }
  if ([string]::IsNullOrWhiteSpace($markerAab) -or
      (Resolve-Path -LiteralPath $markerAab -ErrorAction SilentlyContinue).Path -ine $resolvedAab -or
      ([string]$values['sha256'] -notmatch '^[0-9a-fA-F]{64}$')) {
    throw 'Existing production AAB map marker is invalid or points to a different AAB.'
  }

  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $actualHash = [System.BitConverter]::ToString(
      $sha256.ComputeHash([System.IO.File]::ReadAllBytes($resolvedAab))
    ).Replace('-', '')
  } finally {
    $sha256.Dispose()
  }
  if ($actualHash -ine [string]$values['sha256']) {
    throw 'Existing production AAB map marker SHA-256 does not match the AAB.'
  }
  return $markerPath
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
  throw "Production config not found: $ConfigPath`nCopy config\play-production.example.json to config\play-production.json and fill the local service account path."
}

Assert-File -Path $BuildScript -Label 'map-safe AAB build script'
Assert-File -Path $GradlePath -Label 'Android Gradle wrapper'
Assert-File -Path $PubspecPath -Label 'pubspec.yaml'
$config = Read-Json -Path $ConfigPath
Assert-ProductionConfig -Config $config -ForUpload:$ConfirmProductionRollout

Write-Host "Production preflight passed for $($config.packageName), track=$($config.track)."
Write-Host "Current version: $(Read-PubspecVersion)"

if (-not $ConfirmProductionRollout -and -not $BuildDraft) {
  Write-Host 'No upload performed. This is the default fail-closed preflight mode.'
  Write-Host 'Use -BuildDraft to create a map-safe candidate AAB without uploading.'
  Write-Host 'Use -ConfirmProductionRollout with a non-example enabled config only after Play Console review.'
  exit 0
}

$aabPath = [System.IO.Path]::GetFullPath((Join-Path ([string]$config.path) ([string]$config.aabPath)))
$buildResult = $null
if ($ReuseExistingAab) {
  if (-not $ConfirmProductionRollout) {
    throw '-ReuseExistingAab requires -ConfirmProductionRollout.'
  }
  Write-Host 'Reusing existing validated AAB; build and version bump are skipped.'
  $markerPath = Assert-ExistingAabMarker -AabPath $aabPath
} else {
  $buildArgs = @{ SkipFluxOsSession = $true }
  if ($SkipVersionBump -or -not $ConfirmProductionRollout) { $buildArgs.SkipVersionBump = $true }
  if ($SkipTests) { $buildArgs.SkipTests = $true }
  Write-Host 'Building through scripts/build-internal-aab.ps1 (map-safe dart-define preflight included).'
  $buildResult = & $BuildScript @buildArgs
  if ($LASTEXITCODE -ne 0) { throw "Map-safe production AAB build failed with exit code $LASTEXITCODE." }
  $markerPath = "$aabPath.map-marker"
  Assert-File -Path $aabPath -Label 'production AAB'
  Assert-File -Path $markerPath -Label 'map artifact marker'
}
if (-not $ConfirmProductionRollout) {
  Write-Host "Draft AAB ready: $aabPath"
  Write-Host 'No Play upload performed.'
  exit 0
}

$serviceAccount = [System.IO.Path]::GetFullPath([string]$config.serviceAccountJson)
$artifactDir = Split-Path -Parent $aabPath
$rolloutToken = [guid]::NewGuid().ToString('N')
$receiptPath = Join-Path $WorkspaceRoot ("build\.planflow-production-rollout-{0}.receipt" -f $rolloutToken)
$planflowGradleUserHome = Join-Path $WorkspaceRoot '.gradle-local\gradle-home'
$receiptLines = @(
  "token=$rolloutToken",
  "track=production",
  "workspace=$WorkspaceRoot",
  "issuedAtEpochMillis=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
)
[System.IO.File]::WriteAllLines($receiptPath, $receiptLines, [System.Text.UTF8Encoding]::new($false))
$previousGradleUserHome = $env:GRADLE_USER_HOME
if ($UseSharedGradleCache -and -not [string]::IsNullOrWhiteSpace($previousGradleUserHome)) {
  $planflowGradleUserHome = $previousGradleUserHome
}
$env:GRADLE_USER_HOME = $planflowGradleUserHome
Push-Location (Join-Path $WorkspaceRoot 'android')
try {
  & $GradlePath ':app:publishReleaseBundle' '--track' 'production' '--artifact-dir' $artifactDir `
    '--console=plain' '--stacktrace' '--no-daemon' `
    "-PplanflowPlayServiceAccountJson=$serviceAccount" "-PplanflowMapArtifactMarker=$markerPath" `
    '-PplanflowPlayTrack=production' "-PplanflowProductionRolloutToken=$rolloutToken" `
    "-PplanflowProductionRolloutReceipt=$receiptPath"
  if ($LASTEXITCODE -ne 0) { throw "Production Play upload failed with exit code $LASTEXITCODE." }
} finally {
  Pop-Location
  if ($null -eq $previousGradleUserHome) {
    Remove-Item Env:GRADLE_USER_HOME -ErrorAction SilentlyContinue
  } else {
    $env:GRADLE_USER_HOME = $previousGradleUserHome
  }
  Remove-Item -LiteralPath $receiptPath -Force -ErrorAction SilentlyContinue
}

Write-Host "Production rollout uploaded for $($config.packageName), track=production."
