param(
  [string]$ArchivePath,
  [string]$PasswordFile,
  [switch]$Install
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$repoRoot = Split-Path -Parent $PSScriptRoot
$flutterScript = Join-Path $repoRoot "scripts\flutter-local.ps1"
$restoreScript = Join-Path $repoRoot "scripts\restore-planflow-signing.ps1"
$installScript = Join-Path $repoRoot "scripts\adb-install-update.ps1"
$debugApk = Join-Path $repoRoot "build/app/outputs/flutter-apk/app-debug.apk"
$releaseAab = Join-Path $repoRoot "build/app/outputs/bundle/release/app-release.aab"
$expectedDebugFingerprint = "b3f2289851b78881263ca939fc09181efc310152828dd700fab7c552bef9a231"

function Write-Status([string]$message) {
  Write-Host ""
  Write-Host "==> $message"
}

function Resolve-ArchivePath([string]$requestedPath) {
  if ($requestedPath -and (Test-Path -LiteralPath $requestedPath)) {
    return (Resolve-Path -LiteralPath $requestedPath).Path
  }
  if ($requestedPath) {
    throw "Requested ArchivePath does not exist: $requestedPath"
  }

  $oneDriveRoot = $null
  if ($env:OneDrive -and (Test-Path -LiteralPath $env:OneDrive)) {
    $oneDriveRoot = $env:OneDrive
  } elseif ($env:USERPROFILE -and (Test-Path -LiteralPath (Join-Path $env:USERPROFILE "OneDrive"))) {
    $oneDriveRoot = Join-Path $env:USERPROFILE "OneDrive"
  }

  $oneDriveCandidates = @()
  if ($oneDriveRoot) {
    $oneDriveCandidates += Join-Path $oneDriveRoot "PlanFlow Signing Backup\PlanFlow-signing-keys.zip.aes"
    $oneDriveCandidates += Join-Path $oneDriveRoot "PlanFlow Signing Backup\Planflow-signing-keys.zip.aes"
  }

  $fallbackCandidates = @(
    "android/signing/PlanFlow-signing-keys.zip.aes",
    "android/signing/planflow-signing-keys.zip.aes"
  )

  $candidates = @()
  $candidates += $oneDriveCandidates
  $candidates += $fallbackCandidates

  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      continue
    }
    if (Test-Path -LiteralPath $candidate) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }

  $fallbackText = if ($oneDriveRoot) { $oneDriveRoot } else { "not found" }
  throw "Signing archive not found. Checked OneDrive: $fallbackText and android/signing/PlanFlow-signing-keys.zip.aes. Pass -ArchivePath explicitly."
}

function Invoke-CommandWithExitCode([string]$label, [scriptblock]$action) {
  Write-Status $label
  $previousErrorAction = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & $action
  } finally {
    $ErrorActionPreference = $previousErrorAction
  }
  if ($LASTEXITCODE -ne 0) {
    throw "$label failed with exit code $LASTEXITCODE."
  }
}

function Resolve-ApkSigner() {
  $apksigner = Get-Command apksigner -ErrorAction SilentlyContinue
  if ($apksigner) {
    return $apksigner.Source
  }

  $roots = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  foreach ($root in $roots) {
    if (!(Test-Path -LiteralPath $root)) { continue }
    $buildToolsDir = Join-Path $root "build-tools"
    if (!(Test-Path -LiteralPath $buildToolsDir)) { continue }

    $latest = Get-ChildItem -Path $buildToolsDir -Directory -ErrorAction SilentlyContinue |
      Sort-Object {
        try {
          [version]$_.Name
        } catch {
          [version]"0.0.0"
        }
      } -Descending |
      Select-Object -First 1

    if (-not $latest) { continue }
    $candidate = Join-Path $latest.FullName "apksigner.bat"
    if (Test-Path -LiteralPath $candidate) {
      return $candidate
    }
  }

  throw "Could not locate apksigner. Ensure Android SDK build-tools are installed and PATH is configured."
}

function Get-ApkSignerSha256([string]$apkPath) {
  $command = Resolve-ApkSigner
  $output = & $command verify --print-certs $apkPath 2>&1 | ForEach-Object { $_.ToString() }
  if ($LASTEXITCODE -ne 0) {
    $text = $output -join "`n"
    throw "apksigner verify failed. $text"
  }

  $joined = ($output | Out-String)
  $match = [regex]::Match($joined, "SHA-256(?: digest)?\s*:\s*([0-9a-fA-F]{64})", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if (-not $match.Success) {
    throw "Unable to parse SHA-256 from apksigner output:`n$joined"
  }
  return $match.Groups[1].Value.ToLowerInvariant()
}

function Assert-ArtifactExists([string]$path, [string]$name) {
  if (!(Test-Path -LiteralPath $path)) {
    throw "$name was not produced: $path"
  }
}

try {
  Set-Location $repoRoot
  Write-Host "PlanFlow bootstrap start"

  Write-Status "1) Resolve signing archive"
  $resolvedArchive = Resolve-ArchivePath -requestedPath $ArchivePath
  Write-Host "Using archive: $resolvedArchive"

  Write-Status "2) Restore signing key and properties"
  if ($PasswordFile) {
    & $restoreScript -ArchivePath $resolvedArchive -PasswordFile $PasswordFile
  } else {
    & $restoreScript -ArchivePath $resolvedArchive
  }

  Write-Status "3) Build debug APK"
  Invoke-CommandWithExitCode "scripts/flutter-local.ps1 build apk --debug --no-pub" {
    & $flutterScript build apk --debug --no-pub
  }

  Write-Status "4) Build release AAB"
  Invoke-CommandWithExitCode "scripts/flutter-local.ps1 build appbundle --release --no-pub" {
    & $flutterScript build appbundle --release --no-pub
  }

  Write-Status "5) Validate debug APK SHA-256 certificate fingerprint"
  Assert-ArtifactExists -path $debugApk -name "Debug APK"
  $actualSha = Get-ApkSignerSha256 -apkPath $debugApk
  Write-Host "Expected SHA-256: $expectedDebugFingerprint"
  Write-Host "Actual SHA-256:   $actualSha"
  if ($actualSha -ne $expectedDebugFingerprint.ToLowerInvariant()) {
    throw "Debug APK fingerprint mismatch. The restored signing material may be different from the expected PlanFlow release key."
  }
  Write-Host "Fingerprint match confirmed."

  Write-Status "6) Confirm output artifacts"
  Assert-ArtifactExists -path $releaseAab -name "Release AAB"
  Write-Host "Debug APK: $debugApk"
  Write-Host "Release AAB: $releaseAab"

  if ($Install) {
    Write-Status "7) Run adb update install"
    Invoke-CommandWithExitCode "scripts/adb-install-update.ps1" {
      & $installScript
    }
  } else {
    Write-Host ""
    Write-Host "Install step skipped. Add -Install to run adb-install-update.ps1."
  }

  Write-Host ""
  Write-Host "PlanFlow bootstrap completed."
} catch {
  Write-Host ""
  Write-Error "PlanFlow bootstrap failed: $($_.Exception.Message)"
  throw
}
