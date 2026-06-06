param(
  [string]$PubspecPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'pubspec.yaml'),
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
  [pscustomobject]@{
    PubspecPath = $PubspecPath
    VersionName = $versionName
    OldVersion  = $oldVersion
    NewVersion  = $newVersion
    BuildNumber  = $newBuildNumber
  }
} catch {
  Write-Error $_
  exit 1
}
