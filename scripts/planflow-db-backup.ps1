param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot "..\env\db-backup.local.json"),
  [switch]$SkipRestore,
  [switch]$SkipRetention
)

$ErrorActionPreference = "Stop"

function Resolve-RepoPath([string]$Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }
  return (Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..")).Path $Path)
}

function Read-Config([string]$Path) {
  $resolved = Resolve-RepoPath $Path
  if (-not (Test-Path -LiteralPath $resolved)) {
    throw "Missing DB backup config: $resolved. Copy env/db-backup.example.json to env/db-backup.local.json and fill the connection URLs."
  }
  return Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
}

function Find-PgTool([string]$Name, [object]$Config) {
  if ($Config.PgBin -and $Config.PgBin.Trim()) {
    $candidate = Join-Path $Config.PgBin "$Name.exe"
    if (Test-Path -LiteralPath $candidate) {
      return $candidate
    }
  }

  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }

  $postgresRoots = @(
    "C:\Program Files\PostgreSQL",
    "C:\Program Files (x86)\PostgreSQL"
  )
  foreach ($root in $postgresRoots) {
    if (-not (Test-Path -LiteralPath $root)) {
      continue
    }
    $match = Get-ChildItem -LiteralPath $root -Recurse -Filter "$Name.exe" -ErrorAction SilentlyContinue |
      Sort-Object FullName -Descending |
      Select-Object -First 1
    if ($match) {
      return $match.FullName
    }
  }

  throw "Could not find $Name. Install PostgreSQL client tools 17.x or set PgBin in env/db-backup.local.json."
}

function Invoke-Checked([string]$Exe, [string[]]$Args, [string]$FailureMessage) {
  & $Exe @Args
  if ($LASTEXITCODE -ne 0) {
    throw "$FailureMessage Exit code: $LASTEXITCODE"
  }
}

function Protect-Url([string]$Url) {
  if (-not $Url) {
    return ""
  }
  return ($Url -replace '://([^:@/]+):([^@/]+)@', '://$1:****@')
}

function Assert-ConnectionStrings([object]$Config, [bool]$NeedsBackup) {
  $source = "$($Config.SourceDatabaseUrl)".Trim()
  if (-not $source -or $source.Contains("[SOURCE_DB_PASSWORD]")) {
    throw "SourceDatabaseUrl is not configured."
  }
  if ($NeedsBackup) {
    $backup = "$($Config.BackupDatabaseUrl)".Trim()
    if (-not $backup -or $backup.Contains("[BACKUP_DB_PASSWORD]")) {
      throw "BackupDatabaseUrl is not configured."
    }
    if ($source -eq $backup) {
      throw "SourceDatabaseUrl and BackupDatabaseUrl are identical. Refusing to restore over the production DB."
    }
  }
}

function Remove-OldDumps([string]$Directory, [int]$RetentionDays, [int]$MonthlyRetentionMonths) {
  if ($RetentionDays -le 0) {
    return
  }

  $now = Get-Date
  $recentCutoff = $now.AddDays(-$RetentionDays)
  $monthlyCutoff = $now.AddMonths(-[Math]::Max($MonthlyRetentionMonths, 0))
  $monthlyBuckets = @{}

  Get-ChildItem -LiteralPath $Directory -Filter "planflow-db-*.dump" -File |
    Sort-Object LastWriteTime -Descending |
    ForEach-Object {
      if ($_.LastWriteTime -ge $recentCutoff) {
        return
      }
      if ($MonthlyRetentionMonths -gt 0 -and $_.LastWriteTime -ge $monthlyCutoff) {
        $bucket = $_.LastWriteTime.ToString("yyyy-MM")
        if (-not $monthlyBuckets.ContainsKey($bucket)) {
          $monthlyBuckets[$bucket] = $true
          return
        }
      }
      Remove-Item -LiteralPath $_.FullName -Force
      Write-Host "Pruned old dump: $($_.Name)"
    }
}

$config = Read-Config $ConfigPath
Assert-ConnectionStrings $config (-not $SkipRestore)

$pgDump = Find-PgTool "pg_dump" $config
$pgRestore = Find-PgTool "pg_restore" $config
$psql = Find-PgTool "psql" $config

$dumpDirectory = if ($config.DumpDirectory -and "$($config.DumpDirectory)".Trim()) {
  Resolve-RepoPath "$($config.DumpDirectory)"
} else {
  Resolve-RepoPath "database-backups"
}
New-Item -ItemType Directory -Path $dumpDirectory -Force | Out-Null

$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
$dumpPath = Join-Path $dumpDirectory "planflow-db-$stamp.dump"
$schemas = @($config.Schemas)
if ($schemas.Count -eq 0) {
  $schemas = @("public")
}

Write-Host "PlanFlow DB backup started."
Write-Host "Source: $(Protect-Url "$($config.SourceDatabaseUrl)")"
Write-Host "Dump: $dumpPath"
Write-Host "Schemas: $($schemas -join ', ')"

$dumpArgs = @(
  "--format=custom",
  "--compress=9",
  "--no-owner",
  "--no-privileges",
  "--file", $dumpPath,
  "--dbname", "$($config.SourceDatabaseUrl)"
)
foreach ($schema in $schemas) {
  if ($schema -and "$schema".Trim()) {
    $dumpArgs += @("--schema", "$schema")
  }
}

Invoke-Checked $pgDump $dumpArgs "pg_dump failed."

if (-not $SkipRestore) {
  Write-Host "Restoring latest dump into backup DB."
  Write-Host "Backup target: $(Protect-Url "$($config.BackupDatabaseUrl)")"
  $restoreArgs = @(
    "--clean",
    "--if-exists",
    "--no-owner",
    "--no-privileges",
    "--dbname", "$($config.BackupDatabaseUrl)",
    $dumpPath
  )
  Invoke-Checked $pgRestore $restoreArgs "pg_restore to backup DB failed."

  $verifyArgs = @(
    "$($config.BackupDatabaseUrl)",
    "-v", "ON_ERROR_STOP=1",
    "-Atc",
    "select 'events=' || coalesce((select count(*) from public.events), 0) || ', backups=' || coalesce((select count(*) from public.user_backups), 0);"
  )
  Invoke-Checked $psql $verifyArgs "Backup DB verification query failed."
}

if (-not $SkipRetention) {
  $retentionDays = 35
  if ($null -ne $config.RetentionDays) {
    $retentionDays = [int]$config.RetentionDays
  }
  $monthlyRetentionMonths = 12
  if ($null -ne $config.MonthlyRetentionMonths) {
    $monthlyRetentionMonths = [int]$config.MonthlyRetentionMonths
  }

  Remove-OldDumps `
    -Directory $dumpDirectory `
    -RetentionDays $retentionDays `
    -MonthlyRetentionMonths $monthlyRetentionMonths
}

Write-Host "PlanFlow DB backup completed."
