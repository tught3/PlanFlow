# Build the isolated debug package with both non-secret guide QA defines.
# This script deliberately accepts no extra Flutter arguments or define files.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if ($args.Count -ne 0) { throw 'Extra build arguments are not allowed.' }

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$definePath = Join-Path $projectRoot 'qa-defines\guide-qa.json'
$guard = 'E:\AI_WIKI\scripts\flutter-build-guarded.ps1'
$apkPath = Join-Path $projectRoot 'build\app\outputs\flutter-apk\app-debug.apk'
if (-not (Test-Path -LiteralPath $guard -PathType Leaf)) { throw 'Guarded Flutter build wrapper is missing.' }
if (-not (Test-Path -LiteralPath $definePath -PathType Leaf)) { throw 'Guide QA define file is missing.' }
$defines = Get-Content -LiteralPath $definePath -Raw | ConvertFrom-Json
$defineNames = @($defines.PSObject.Properties.Name | Sort-Object)
$expectedNames = @('PLANFLOW_GUIDE_QA', 'PLANFLOW_ISOLATED_GUIDE_QA') | Sort-Object
if ($defineNames.Count -ne 2 -or (Compare-Object $defineNames $expectedNames -CaseSensitive) -or
    $defines.PLANFLOW_GUIDE_QA -isnot [bool] -or -not $defines.PLANFLOW_GUIDE_QA -or
    $defines.PLANFLOW_ISOLATED_GUIDE_QA -isnot [bool] -or -not $defines.PLANFLOW_ISOLATED_GUIDE_QA) {
  throw 'Guide QA define file must contain exactly the two required true booleans.'
}

$sdkRoots = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)
if ($env:LOCALAPPDATA) { $sdkRoots += (Join-Path $env:LOCALAPPDATA 'Android\Sdk') }
$aapt = $null
foreach ($sdkRoot in $sdkRoots) {
  if ([string]::IsNullOrWhiteSpace($sdkRoot)) { continue }
  $buildTools = Join-Path $sdkRoot 'build-tools'
  if (-not (Test-Path -LiteralPath $buildTools -PathType Container)) { continue }
  $aapt = Get-ChildItem -LiteralPath $buildTools -Directory |
    Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'aapt.exe' } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
  if ($aapt) { break }
}
if (-not $aapt) { throw 'Android SDK aapt.exe was not found.' }

$buildArgs = @('apk', '--debug', '--dart-define-from-file=qa-defines/guide-qa.json')
$buildArgsJson = ConvertTo-Json -InputObject $buildArgs -Compress
$owner = "planflow-guide-qa-build-$PID"
$startedUtc = [DateTime]::UtcNow
Write-Host 'Guarded Flutter APK build arguments (via shared guard): --debug --dart-define-from-file=qa-defines/guide-qa.json'
& $guard `
  -ProjectPath $projectRoot -Project 'PlanFlow' -Owner $owner -BuildArgsJson $buildArgsJson
if ($LASTEXITCODE -ne 0) { throw "Guarded Flutter build failed (exit=$LASTEXITCODE)." }
if (-not (Test-Path -LiteralPath $apkPath -PathType Leaf)) { throw 'APK was not produced.' }
if ((Get-Item -LiteralPath $apkPath).LastWriteTimeUtc -lt $startedUtc.AddSeconds(-2)) {
  throw 'APK timestamp predates the guarded build; refusing stale artifact.'
}
$initialApkHash = (Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash

$badging = & $aapt dump badging $apkPath
if ($LASTEXITCODE -ne 0) { throw 'aapt could not inspect the built APK.' }
$packageLine = @($badging | Where-Object { $_ -match '^package: ' })
if ($packageLine.Count -ne 1 -or
    $packageLine[0] -notmatch "^package: name='com\.fluxstudio\.planflow\.guideqa' versionCode='([0-9]+)'") {
  throw 'Built APK is not the isolated guideqa package.'
}
$versionCode = $Matches[1]

# Inspect the bytes packaged in the APK. A marker establishes that the debug
# diagnostic is present, not the values of the runtime constants. The latter
# are deliberately left pending until the APK is launched and its diagnostic
# line is observed; source/config files alone cannot prove effective defines.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($apkPath)
try {
  $kernel = $zip.GetEntry('assets/flutter_assets/kernel_blob.bin')
  if (-not $kernel) { throw 'Debug kernel blob is missing from the APK.' }
  $stream = $kernel.Open()
  try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $kernelHash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
    finally { $sha.Dispose() }
  } finally { $stream.Dispose() }
  $stream = $kernel.Open()
  try {
    $marker = 'PLANFLOW_GUIDE_QA_BUILD_DEFINES'
    $buffer = New-Object byte[] 65536
    $tail = ''
    $markerFound = $false
    while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
      $segment = $tail + [Text.Encoding]::ASCII.GetString($buffer, 0, $count)
      if ($segment.Contains($marker)) { $markerFound = $true; break }
      $tail = $segment.Substring([Math]::Max(0, $segment.Length - $marker.Length + 1))
    }
    if (-not $markerFound) { throw 'Guide QA diagnostic marker is absent from APK kernel.' }
  } finally { $stream.Dispose() }
} finally { $zip.Dispose() }

$apkHash = (Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash
if ($apkHash -ne $initialApkHash) { throw 'APK changed while it was being inspected.' }
Write-Host "APK=$apkPath"
Write-Host "PACKAGE=com.fluxstudio.planflow.guideqa VERSION_CODE=$versionCode"
Write-Host "APK_SHA256=$apkHash KERNEL_SHA256=$kernelHash"
Write-Host 'QA_DIAGNOSTIC_MARKER=PRESENT EFFECTIVE_DEFINES=UNCONFIRMED_RUNTIME_DIAGNOSTIC_REQUIRED'
