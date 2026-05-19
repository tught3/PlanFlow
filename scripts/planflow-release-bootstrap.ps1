param(
  [string]$ArchivePath,
  [string]$PasswordFile,
  [switch]$AllowOneTimeTransition,
  [switch]$SkipRestore,
  [switch]$SkipBuild,
  [switch]$SkipVerify,
  [switch]$SkipInstall,
  [switch]$SkipLaunch,
  [switch]$ForceRestore
)

$ErrorActionPreference = "Stop"

$ExpectedCertificateSha256 = "b3f2289851b78881263ca939fc09181efc310152828dd700fab7c552bef9a231"
$ExpectedPackageName = "com.planflow.app"
$SigningKeyFile = Join-Path $PSScriptRoot "..\android\key.properties"
$SigningKeystoreFile = Join-Path $PSScriptRoot "..\android\app\planflow-release.jks"
$DefaultArchiveCandidates = @(
  (Join-Path $env:USERPROFILE "OneDrive\PlanFlow Signing Backup\PlanFlow-signing-keys.zip.aes"),
  (Join-Path $PSScriptRoot "..\android\signing\PlanFlow-signing-keys.zip.aes")
)

function Write-Stage([string]$Message) {
  Write-Host ""
  Write-Host "== $Message =="
}

function Resolve-ExistingPath([string[]]$Candidates) {
  foreach ($candidate in $Candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      continue
    }
    if (Test-Path -LiteralPath $candidate) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }
  return $null
}

function Invoke-Checked([scriptblock]$Action, [string]$Label) {
  Write-Host $Label
  & $Action
  if ($LASTEXITCODE -ne 0) {
    throw "$Label failed with exit code $LASTEXITCODE."
  }
}

function Get-ApkSignerPath {
  $sdkRoot = Join-Path $env:LOCALAPPDATA "Android\Sdk\build-tools"
  if (!(Test-Path -LiteralPath $sdkRoot)) {
    throw "Android SDK build-tools folder not found: $sdkRoot"
  }

  $candidate = Get-ChildItem -Path $sdkRoot -Recurse -Filter apksigner.bat -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName

  if ([string]::IsNullOrWhiteSpace($candidate)) {
    throw "apksigner.bat not found under $sdkRoot"
  }

  return $candidate
}

function Get-InstalledSigningFiles {
  return (Test-Path -LiteralPath $SigningKeyFile) -and (Test-Path -LiteralPath $SigningKeystoreFile)
}

function Restore-SigningFiles {
  param(
    [Parameter(Mandatory = $true)][string]$ResolvedArchivePath,
    [string]$ResolvedPasswordFile
  )

  $restoreArgs = @(
    "-ArchivePath", $ResolvedArchivePath,
    "-OutputRoot", "android"
  )

  if ($ResolvedPasswordFile) {
    $restoreArgs += @("-PasswordFile", $ResolvedPasswordFile)
  }

  if ($ForceRestore) {
    $restoreArgs += "-Force"
  }

  & (Join-Path $PSScriptRoot "restore-planflow-signing.ps1") @restoreArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Signing restore failed with exit code $LASTEXITCODE."
  }
}

function Verify-ApkSignature {
  param(
    [Parameter(Mandatory = $true)][string]$ApkPath
  )

  $apksigner = Get-ApkSignerPath
  $verification = & $apksigner verify --print-certs $ApkPath 2>&1
  $verificationText = $verification | Out-String
  $verificationText = $verificationText.TrimEnd()
  Write-Host $verificationText

  $match = [regex]::Match($verificationText, "SHA-256(?: digest)?\s*:\s*([0-9a-fA-F]{64})", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($match.Success) {
    Write-Host "Verified APK SHA-256: $($match.Groups[1].Value.ToLowerInvariant())"
  }

  if ($verificationText -notmatch [regex]::Escape($ExpectedCertificateSha256)) {
    throw "APK signature SHA-256 did not match the expected PlanFlow release fingerprint."
  }

  if ($verificationText -notmatch [regex]::Escape("CN=PlanFlow")) {
    throw "APK signature certificate DN did not match the expected PlanFlow release identity."
  }
}

function Build-PlanFlow {
  Invoke-Checked { & (Join-Path $PSScriptRoot "flutter-local.ps1") build apk --debug --no-pub } "Building debug APK"
  Invoke-Checked { & (Join-Path $PSScriptRoot "flutter-local.ps1") build appbundle --release --no-pub } "Building release appbundle"
}

function Install-PlanFlow {
  $adbDevices = & adb devices
  $deviceLines = $adbDevices | Select-String -Pattern "`tdevice$"
  if ($deviceLines.Count -eq 0) {
    throw "No connected adb device is marked as 'device'. Connect one device before installing."
  }
  if ($deviceLines.Count -gt 1) {
    throw "More than one adb device is connected. Disconnect extras so update-install is unambiguous."
  }

  try {
    Invoke-Checked { & (Join-Path $PSScriptRoot "adb-install-update.ps1") } "Installing APK update"
  } catch {
    if ($AllowOneTimeTransition -and ($_.Exception.Message -match "INSTALL_FAILED_UPDATE_INCOMPATIBLE")) {
      Write-Host "Detected an older signing key on the device. Running the one-time PlanFlow transition."
      & adb uninstall $ExpectedPackageName
      if ($LASTEXITCODE -ne 0) {
        throw "One-time uninstall failed with exit code $LASTEXITCODE."
      }
      Invoke-Checked { & (Join-Path $PSScriptRoot "adb-install-update.ps1") } "Reinstalling APK update after one-time transition"
    } else {
      throw
    }
  }

  if ($SkipLaunch) {
    return
  }

  Write-Host "Launching app and checking PID."
  & adb shell am start -n "$ExpectedPackageName/.MainActivity" | Out-Host
  & adb shell pidof $ExpectedPackageName | Out-Host
}

Write-Stage "PlanFlow release bootstrap"

$resolvedArchive = $null
if (-not $SkipRestore) {
  $archiveCandidates = @()
  if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) {
    $archiveCandidates += $ArchivePath
  } else {
    $archiveCandidates += $DefaultArchiveCandidates
  }

  $resolvedArchive = Resolve-ExistingPath $archiveCandidates
  if ($resolvedArchive) {
    Write-Host "Signing archive: $resolvedArchive"
  } elseif (-not (Get-InstalledSigningFiles)) {
    throw @"
No PlanFlow signing archive was found.
Copy PlanFlow-signing-keys.zip.aes to one of these locations or pass -ArchivePath:
  - $($DefaultArchiveCandidates[0])
  - $($DefaultArchiveCandidates[1])
"@
  } else {
    Write-Host "Signing files already exist locally. Skipping restore."
  }

  if ($resolvedArchive -and (!(Get-InstalledSigningFiles) -or $ForceRestore)) {
    Write-Stage "Restoring signing files"
    Restore-SigningFiles -ResolvedArchivePath $resolvedArchive -ResolvedPasswordFile $PasswordFile
  }
} else {
  Write-Host "Skipping restore at user request."
}

if (-not $SkipBuild) {
  Write-Stage "Building APK and appbundle"
  Build-PlanFlow
} else {
  Write-Host "Skipping build at user request."
}

if (-not $SkipVerify) {
  $apkPath = Join-Path $PSScriptRoot "..\build\app\outputs\flutter-apk\app-debug.apk"
  if (!(Test-Path -LiteralPath $apkPath)) {
    throw "APK not found for verification: $apkPath"
  }

  Write-Stage "Verifying APK signature"
  Verify-ApkSignature -ApkPath $apkPath
  Write-Host "Signature verified: $ExpectedCertificateSha256"
} else {
  Write-Host "Skipping signature verification at user request."
}

if (-not $SkipInstall) {
  Write-Stage "Installing to connected device"
  Install-PlanFlow
} else {
  Write-Host "Skipping device install at user request."
}

Write-Host ""
Write-Host "PlanFlow bootstrap finished."
