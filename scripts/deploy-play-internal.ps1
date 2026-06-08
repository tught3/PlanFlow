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

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Action,
    [Parameter(Mandatory = $true)][string]$Label
  )

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
    throw "Unable to read version from pubspec.yaml: $Path"
  }
  return "$($match.Groups[1].Value)+$($match.Groups[2].Value)"
}

function Get-VersionFromResult {
  param(
    [Parameter(Mandatory = $true)]$Result,
    [Parameter(Mandatory = $true)][string]$PubspecPath
  )

  $candidate = $null

  if ($Result -is [System.Management.Automation.PSObject]) {
    if ($Result.PSObject.Properties.Name -contains 'NewVersion') {
      $candidate = [string]$Result.NewVersion
    } elseif ($Result.PSObject.Properties.Name -contains 'OldVersion') {
      $candidate = [string]$Result.OldVersion
    }
  } elseif ($Result -is [array]) {
    $candidateObject = $Result | Where-Object {
      $_ -is [System.Management.Automation.PSObject] -and $_.PSObject.Properties.Name -contains 'NewVersion'
    } | Select-Object -First 1
    if ($candidateObject) {
      $candidate = [string]$candidateObject.NewVersion
    } else {
      $candidateObject = $Result | Where-Object {
        $_ -is [System.Management.Automation.PSObject] -and $_.PSObject.Properties.Name -contains 'OldVersion'
      } | Select-Object -First 1
      if ($candidateObject) {
        $candidate = [string]$candidateObject.OldVersion
      }
    }
  }

  if ([string]::IsNullOrWhiteSpace($candidate)) {
    $candidate = Read-PubspecVersion -Path $PubspecPath
    Write-Host "Version info fallback used from pubspec.yaml: $candidate"
  }

  return $candidate
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
  Assert-FileExists -Path (Join-Path $projectPath 'android\gradlew.bat') -Label 'android/gradlew.bat'
  Assert-FileExists -Path (Join-Path $projectPath 'android\app\build.gradle.kts') -Label 'android/app/build.gradle.kts'

  Write-Stage 'Bumping version, analyzing, testing, and building AAB'

  $buildScript = Join-Path $projectPath 'scripts\build-internal-aab.ps1'
  $buildResult = $null
  Push-Location $projectPath
  try {
    $buildResult = & $buildScript
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
  $finalVersion = Get-VersionFromResult -Result $buildResult -PubspecPath (Join-Path $projectPath 'pubspec.yaml')

  if ($SkipUpload) {
    Write-Host 'Upload was skipped because -SkipUpload was supplied.'
  } else {
    Write-Stage 'Publishing with Gradle Play Publisher'

    $androidDir = Join-Path $projectPath 'android'
    $gradlew = Join-Path $androidDir 'gradlew.bat'
    $artifactDir = Split-Path -Parent $resolvedAabPath

    Push-Location $androidDir
    try {
      Invoke-Checked {
        & $gradlew ':app:publishReleaseBundle' '--track' $track '--artifact-dir' $artifactDir "-PplanflowPlayServiceAccountJson=$serviceAccountJson"
      } 'android/gradlew.bat :app:publishReleaseBundle'
    } finally {
      Pop-Location
    }
  }

  Write-Host ''
  Write-Host '========================================'
  if ($SkipUpload) {
    Write-Host 'PlanFlow Play Internal Validation Complete'
  } else {
    Write-Host 'PlanFlow Play Internal Upload Complete'
  }
  Write-Host "Version: $finalVersion"
  Write-Host "Package: $packageName"
  Write-Host "Track: $track"
  Write-Host "AAB: $resolvedAabPath"
  Write-Host ''
  Write-Host 'Next:'
  if ($SkipUpload) {
    Write-Host 'Run the same command without -SkipUpload when you are ready to upload.'
  } else {
    Write-Host 'Open Play Store on test device and update PlanFlow.'
  }
  Write-Host '========================================'
} catch {
  Write-Error $_
  exit 1
}
