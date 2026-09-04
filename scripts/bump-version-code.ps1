param(
  [string]$PubspecPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'pubspec.yaml'),
  [string]$WidgetXcconfigPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'ios\Flutter\PlanFlow-Identity.xcconfig'),
  [int]$Increment = 1
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-Utf8Text {
  param([Parameter(Mandatory = $true)][string]$Path)
  $encoding = [System.Text.UTF8Encoding]::new($false)
  return [System.IO.File]::ReadAllText($Path, $encoding)
}

function Write-Utf8Text {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Text
  )
  $encoding = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

try {
  if (-not (Test-Path -LiteralPath $PubspecPath)) {
    throw "pubspec.yaml not found: $PubspecPath"
  }

  if ($Increment -lt 1) {
    throw "Increment must be at least 1."
  }

  $content = Read-Utf8Text -Path $PubspecPath
  $pattern = '(?m)^(?<prefix>\s*version:\s*)(?<version>[0-9]+\.[0-9]+\.[0-9]+)\+(?<build>\d+)(?<suffix>\s*(#.*)?)$'
  $match = [regex]::Match($content, $pattern)

  if (-not $match.Success) {
    throw "Unable to find a parsable version line in pubspec.yaml."
  }

  $versionName = $match.Groups['version'].Value
  $buildNumber = [int]$match.Groups['build'].Value
  $newBuildNumber = $buildNumber + $Increment
  $oldVersion = "$versionName+$buildNumber"
  $newVersion = "$versionName+$newBuildNumber"

  $replacement = $match.Groups['prefix'].Value + $versionName + '+' + $newBuildNumber + $match.Groups['suffix'].Value
  $updated = $content.Substring(0, $match.Index) + $replacement + $content.Substring($match.Index + $match.Length)

  if ($updated -eq $content) {
    throw "pubspec.yaml version line was not changed."
  }

  Write-Utf8Text -Path $PubspecPath -Text $updated

  Write-Host "Updated pubspec.yaml version: $oldVersion -> $newVersion"

  # Keep the WidgetKit extension's version literals in sync with pubspec.yaml.
  # ios/Flutter/PlanFlow-Identity.xcconfig explains why these can't just
  # reference $(FLUTTER_BUILD_NAME)/$(FLUTTER_BUILD_NUMBER): the widget target
  # intentionally omits Generated.xcconfig, so those Flutter-injected
  # variables are undefined in its configuration chain. Without this sync,
  # test/ios_widget_version_contract_test.dart's pubspec-parity assertion
  # breaks whenever pubspec.yaml's version is bumped but this file is not
  # (ios-release.yml's command-line MARKETING_VERSION/CURRENT_PROJECT_VERSION
  # overrides protect release archives from the same drift, but local/
  # simulator builds have no such override).
  if (Test-Path -LiteralPath $WidgetXcconfigPath) {
    $xcconfigContent = Read-Utf8Text -Path $WidgetXcconfigPath
    $xcconfigUpdated = $xcconfigContent

    $marketingPattern = '(?m)^(?<prefix>\s*PLANFLOW_WIDGET_MARKETING_VERSION\s*=\s*)[0-9]+\.[0-9]+\.[0-9]+(?<suffix>\s*(#.*)?)$'
    $marketingMatch = [regex]::Match($xcconfigUpdated, $marketingPattern)
    if (-not $marketingMatch.Success) {
      throw "Unable to find PLANFLOW_WIDGET_MARKETING_VERSION in $WidgetXcconfigPath."
    }
    $marketingReplacement = $marketingMatch.Groups['prefix'].Value + $versionName + $marketingMatch.Groups['suffix'].Value
    $xcconfigUpdated = $xcconfigUpdated.Substring(0, $marketingMatch.Index) + $marketingReplacement + $xcconfigUpdated.Substring($marketingMatch.Index + $marketingMatch.Length)

    $buildPattern = '(?m)^(?<prefix>\s*PLANFLOW_WIDGET_BUILD_NUMBER\s*=\s*)\d+(?<suffix>\s*(#.*)?)$'
    $buildMatch = [regex]::Match($xcconfigUpdated, $buildPattern)
    if (-not $buildMatch.Success) {
      throw "Unable to find PLANFLOW_WIDGET_BUILD_NUMBER in $WidgetXcconfigPath."
    }
    $buildReplacement = $buildMatch.Groups['prefix'].Value + $newBuildNumber + $buildMatch.Groups['suffix'].Value
    $xcconfigUpdated = $xcconfigUpdated.Substring(0, $buildMatch.Index) + $buildReplacement + $xcconfigUpdated.Substring($buildMatch.Index + $buildMatch.Length)

    if ($xcconfigUpdated -ne $xcconfigContent) {
      Write-Utf8Text -Path $WidgetXcconfigPath -Text $xcconfigUpdated
      Write-Host "Updated $WidgetXcconfigPath widget version literals: PLANFLOW_WIDGET_MARKETING_VERSION=$versionName, PLANFLOW_WIDGET_BUILD_NUMBER=$newBuildNumber"
    }
  } else {
    Write-Warning "Widget xcconfig not found at $WidgetXcconfigPath; skipped widget version sync."
  }

  return [pscustomobject]@{
    OldVersion = $oldVersion
    NewVersion = $newVersion
  }
} catch {
  Write-Error $_
  exit 1
}
