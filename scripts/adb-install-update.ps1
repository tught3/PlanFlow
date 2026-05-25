param(
  [string]$ApkPath = "build/app/outputs/flutter-apk/app-debug.apk",
  [string]$PackageName = "com.fluxstudio.planflow"
)

$ErrorActionPreference = "Stop"

$resolvedApk = Resolve-Path -LiteralPath $ApkPath -ErrorAction Stop

Write-Host "Installing update for $PackageName with adb install -r."
Write-Host "APK: $resolvedApk"

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$adbOutput = & adb install -r -t --user 0 $resolvedApk 2>&1 |
  ForEach-Object { $_.ToString() }
$exitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
$adbOutput | ForEach-Object { Write-Host $_ }

if ($exitCode -ne 0) {
  $joined = ($adbOutput | Out-String)
  if ($joined -match "INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
    Write-Error @"
Android refused the update because the installed app and this APK are signed with different keys.
Do not automatically uninstall or clear app data. Compare signing fingerprints first, then decide manually.
Package: $PackageName
"@
  }
  Write-Error "adb install -r failed with exit code $exitCode."
}

Write-Host "Update install finished without clearing app data."
