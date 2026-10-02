$ErrorActionPreference = 'Stop'
try {
  & "E:\FluxStudio\PlanFlow\scripts\build-internal-aab.ps1" -SkipVersionBump -SkipTests
} catch {
  Write-Host "=== FULL EXCEPTION ==="
  Write-Host $_.Exception.ToString()
  Write-Host "=== SCRIPT STACK TRACE ==="
  Write-Host $_.ScriptStackTrace
  Write-Host "=== INVOCATION INFO ==="
  Write-Host ($_.InvocationInfo.PositionMessage)
}
