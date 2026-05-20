param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot "..\env\db-backup.local.json"),
  [string]$TaskName = "PlanFlow Daily Database Backup",
  [string]$At = "03:30",
  [switch]$RunNow
)

$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "planflow-db-backup.ps1"
if (-not (Test-Path -LiteralPath $scriptPath)) {
  throw "Missing backup script: $scriptPath"
}

$resolvedConfig = if ([System.IO.Path]::IsPathRooted($ConfigPath)) {
  $ConfigPath
} else {
  Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..")).Path $ConfigPath
}

if (-not (Test-Path -LiteralPath $resolvedConfig)) {
  throw "Missing DB backup config: $resolvedConfig"
}

$time = [DateTime]::ParseExact($At, "HH:mm", [Globalization.CultureInfo]::InvariantCulture)
$actionArgs = @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", "`"$scriptPath`"",
  "-ConfigPath", "`"$resolvedConfig`""
) -join " "

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $actionArgs
$trigger = New-ScheduledTaskTrigger -Daily -At $time
$settings = New-ScheduledTaskSettingsSet `
  -StartWhenAvailable `
  -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Hours 2)
$principal = New-ScheduledTaskPrincipal `
  -UserId $env:USERNAME `
  -LogonType Interactive `
  -RunLevel LeastPrivilege

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $action `
  -Trigger $trigger `
  -Settings $settings `
  -Principal $principal `
  -Force | Out-Null

Write-Host "Registered Windows scheduled task: $TaskName at $At"

if ($RunNow) {
  Start-ScheduledTask -TaskName $TaskName
  Write-Host "Started task once now: $TaskName"
}
