<#
.SYNOPSIS
  홈위젯 콜드스타트 딥링크 유실 버그 재현 스크립트 (진단 단계 P3).

.DESCRIPTION
  3가지 앱 상태 시나리오(cold / kill / warm) x 3가지 위젯(마이크, 월간 달력, 그룹 달력)
  = 9케이스를 자동으로 실행하고, 각 케이스의 logcat을 파일로 저장한다.

  시나리오:
    1. cold - 완전 콜드: force-stop 후 새 인텐트로 콜드부팅 기동
    2. kill - 태스크 잔존/프로세스 사망: 정상 기동 -> 홈으로 보내기 -> 프로세스만 kill -> 인텐트 재기동
    3. warm - 정상 실행 중(포그라운드)에 인텐트 수신

  이 스크립트는 아직 배포되지 않은 진단 로그 태그(PlanFlowWidgetIntent, WidgetRoute)가
  logcat에 없어도 정상 동작해야 한다 - adb 명령이 실패 없이 실행되고 로그 파일이
  생성되는지만 검증하면 된다(P1/P2 로깅 코드는 아직 빌드에 없을 수 있음).

.NOTES
  패키지: com.fluxstudio.planflow
  인코딩: UTF-8 with BOM (한글 주석 포함)
#>

param(
  [string]$PackageName = "com.fluxstudio.planflow",
  [string]$DeviceSerial = "",
  [int]$ColdWaitSeconds = 5,
  [int]$WarmupWaitSeconds = 3,
  [int]$KillSettleSeconds = 2
)

$ErrorActionPreference = "Stop"

# ── 경로 설정 ────────────────────────────────────────────────
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $ScriptDir "widget-coldstart-logs"

if (-not (Test-Path -LiteralPath $LogDir)) {
  New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# ── adb 대상 device 인자 (여러 기기 연결 시 -s 옵션 필요) ─────
$AdbTargetArgs = @()
if ($DeviceSerial -ne "") {
  $AdbTargetArgs = @("-s", $DeviceSerial)
}

function Invoke-Adb {
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [switch]$AllowFailure
  )
  $fullArgs = @()
  $fullArgs += $AdbTargetArgs
  $fullArgs += $Arguments

  Write-Host "  adb $($fullArgs -join ' ')" -ForegroundColor DarkGray

  $previousEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $output = & adb @fullArgs 2>&1 | ForEach-Object { $_.ToString() }
  $exitCode = $LASTEXITCODE
  $ErrorActionPreference = $previousEap

  if ($output) {
    $output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
  }

  if ($exitCode -ne 0 -and -not $AllowFailure) {
    throw "adb $($fullArgs -join ' ') 실패 (exit=$exitCode)"
  }

  return [PSCustomObject]@{
    ExitCode = $exitCode
    Output   = $output
  }
}

# ── 기기 연결 확인 ──────────────────────────────────────────
Write-Host "[정보] adb 기기 연결 확인 중..." -ForegroundColor Cyan
$devicesResult = Invoke-Adb -Arguments @("devices", "-l") -AllowFailure
$deviceLines = $devicesResult.Output | Where-Object { $_ -match "\bdevice\b" -and $_ -notmatch "List of devices" }
if (-not $deviceLines -or $deviceLines.Count -eq 0) {
  Write-Host "[오류] 연결된 adb 기기가 없습니다. 무선 디버깅(mDNS) 또는 USB 연결 상태를 확인하세요." -ForegroundColor Red
  exit 1
}
Write-Host "[성공] 연결된 기기: $($deviceLines.Count)개" -ForegroundColor Green
$deviceLines | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

# ── 패키지 설치 확인 ────────────────────────────────────────
Write-Host "[정보] 패키지 설치 확인 중: $PackageName" -ForegroundColor Cyan
$pkgResult = Invoke-Adb -Arguments @("shell", "pm", "list", "packages", $PackageName) -AllowFailure
$pkgInstalled = $pkgResult.Output | Where-Object { $_ -match [regex]::Escape($PackageName) }
if (-not $pkgInstalled) {
  Write-Host "[오류] 패키지가 기기에 설치되어 있지 않습니다: $PackageName" -ForegroundColor Red
  exit 1
}
Write-Host "[성공] 패키지 설치 확인됨: $pkgInstalled" -ForegroundColor Green

# ── 위젯별 인텐트 정의 ──────────────────────────────────────
# home_widget 플러그인이 실제로 만드는 인텐트를 최대한 동일하게 재현한다.
# - 마이크(1x1)/월간 달력 위젯: es.antonborri.home_widget.action.LAUNCH, 컴포넌트 명시
# - 그룹 달력 위젯: android.intent.action.VIEW, 컴포넌트 명시
$HomeWidgetLaunchAction = "es.antonborri.home_widget.action.LAUNCH"
$ViewAction = "android.intent.action.VIEW"
$MainActivityComponent = "$PackageName/.MainActivity"

$Widgets = @(
  [PSCustomObject]@{
    Key    = "voice-launcher"
    Uri    = "planflow://voice-launcher"
    Action = $HomeWidgetLaunchAction
  },
  [PSCustomObject]@{
    Key    = "calendar"
    Uri    = "planflow://calendar?date=2026-08-10"
    Action = $HomeWidgetLaunchAction
  },
  [PSCustomObject]@{
    Key    = "group-calendar"
    Uri    = "planflow://group-calendar?groupId=test123&date=2026-08-10"
    Action = $ViewAction
  }
)

$Scenarios = @("cold", "kill", "warm")

function Send-WidgetIntent {
  param([Parameter(Mandatory = $true)]$Widget)

  Invoke-Adb -Arguments @(
    "shell", "am", "start",
    "-a", $Widget.Action,
    "-n", $MainActivityComponent,
    "-d", $Widget.Uri
  ) -AllowFailure
}

function Start-AppNormally {
  Invoke-Adb -Arguments @(
    "shell", "am", "start",
    "-n", $MainActivityComponent
  ) -AllowFailure
}

$results = @()
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

Write-Host ""
Write-Host "[정보] 9케이스(시나리오 3 x 위젯 3) 재현 시작..." -ForegroundColor Cyan

foreach ($scenario in $Scenarios) {
  foreach ($widget in $Widgets) {
    $caseLabel = "${scenario}_$($widget.Key)"
    Write-Host ""
    Write-Host "[진행] 케이스: $caseLabel" -ForegroundColor Cyan

    try {
      switch ($scenario) {
        "cold" {
          # 완전 콜드: force-stop -> 대기 -> 로그 클리어 -> 인텐트 송신 -> 대기 -> 덤프
          Write-Host "  1) force-stop" -ForegroundColor DarkCyan
          Invoke-Adb -Arguments @("shell", "am", "force-stop", $PackageName) -AllowFailure | Out-Null
          Start-Sleep -Seconds $KillSettleSeconds

          Write-Host "  2) logcat 클리어" -ForegroundColor DarkCyan
          Invoke-Adb -Arguments @("logcat", "-c") -AllowFailure | Out-Null

          Write-Host "  3) 위젯 인텐트 송신 (콜드 기동)" -ForegroundColor DarkCyan
          Send-WidgetIntent -Widget $widget | Out-Null

          Write-Host "  4) 대기 ($ColdWaitSeconds 초, 앱 기동+라우팅 시간 확보)" -ForegroundColor DarkCyan
          Start-Sleep -Seconds $ColdWaitSeconds
        }
        "kill" {
          # 태스크 잔존/프로세스 사망: 정상 기동 -> 홈으로 -> 프로세스만 kill -> 재기동
          Write-Host "  1) 정상 기동" -ForegroundColor DarkCyan
          Start-AppNormally | Out-Null
          Start-Sleep -Seconds $WarmupWaitSeconds

          Write-Host "  2) 홈 버튼으로 보내기 (태스크는 유지)" -ForegroundColor DarkCyan
          Invoke-Adb -Arguments @("shell", "input", "keyevent", "KEYCODE_HOME") -AllowFailure | Out-Null
          Start-Sleep -Seconds 1

          Write-Host "  3) 프로세스만 kill (태스크/백스택 유지)" -ForegroundColor DarkCyan
          Invoke-Adb -Arguments @("shell", "am", "kill", $PackageName) -AllowFailure | Out-Null
          Start-Sleep -Seconds $KillSettleSeconds

          Write-Host "  4) logcat 클리어" -ForegroundColor DarkCyan
          Invoke-Adb -Arguments @("logcat", "-c") -AllowFailure | Out-Null

          Write-Host "  5) 위젯 인텐트 송신 (재기동)" -ForegroundColor DarkCyan
          Send-WidgetIntent -Widget $widget | Out-Null

          Write-Host "  6) 대기 ($ColdWaitSeconds 초)" -ForegroundColor DarkCyan
          Start-Sleep -Seconds $ColdWaitSeconds
        }
        "warm" {
          # 정상 실행 중(포그라운드)에 인텐트 수신
          Write-Host "  1) 정상 기동" -ForegroundColor DarkCyan
          Start-AppNormally | Out-Null

          Write-Host "  2) 대기 ($WarmupWaitSeconds 초, 포그라운드 확보)" -ForegroundColor DarkCyan
          Start-Sleep -Seconds $WarmupWaitSeconds

          Write-Host "  3) logcat 클리어" -ForegroundColor DarkCyan
          Invoke-Adb -Arguments @("logcat", "-c") -AllowFailure | Out-Null

          Write-Host "  4) 위젯 인텐트 송신 (warm)" -ForegroundColor DarkCyan
          Send-WidgetIntent -Widget $widget | Out-Null

          Write-Host "  5) 대기 ($WarmupWaitSeconds 초)" -ForegroundColor DarkCyan
          Start-Sleep -Seconds $WarmupWaitSeconds
        }
      }

      # ── 로그 덤프 ──
      $logFileName = "${caseLabel}_${timestamp}.log"
      $logFilePath = Join-Path $LogDir $logFileName
      Write-Host "  로그 덤프 -> $logFilePath" -ForegroundColor DarkCyan

      $dumpResult = Invoke-Adb -Arguments @("logcat", "-d") -AllowFailure
      $dumpResult.Output | Out-File -FilePath $logFilePath -Encoding utf8

      $lineCount = ($dumpResult.Output | Measure-Object).Count
      Write-Host "[성공] $caseLabel 완료 (로그 $lineCount 줄)" -ForegroundColor Green

      $results += [PSCustomObject]@{
        Case      = $caseLabel
        Scenario  = $scenario
        Widget    = $widget.Key
        LogPath   = $logFilePath
        LineCount = $lineCount
        Status    = "OK"
      }
    }
    catch {
      Write-Host "[오류] $caseLabel 실패: $($_.Exception.Message)" -ForegroundColor Red
      $results += [PSCustomObject]@{
        Case      = $caseLabel
        Scenario  = $scenario
        Widget    = $widget.Key
        LogPath   = $null
        LineCount = 0
        Status    = "FAILED: $($_.Exception.Message)"
      }
    }
  }
}

# ── 종료 후 원상복구: 앱을 정상 상태로 한 번 더 기동해둔다 ──
Write-Host ""
Write-Host "[정보] 정리: 앱 정상 재기동" -ForegroundColor Cyan
Start-AppNormally | Out-Null

# ── 결과 요약 출력 ──────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  9케이스 재현 결과 요약" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$okCount = ($results | Where-Object { $_.Status -eq "OK" }).Count
$failCount = $results.Count - $okCount

foreach ($r in $results) {
  if ($r.Status -eq "OK") {
    Write-Host "[OK]   $($r.Case)" -ForegroundColor Green
    Write-Host "       -> $($r.LogPath)" -ForegroundColor DarkGray
  }
  else {
    Write-Host "[FAIL] $($r.Case): $($r.Status)" -ForegroundColor Red
  }
}

Write-Host ""
Write-Host "총 $($results.Count)케이스 중 성공 $okCount / 실패 $failCount" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Red" })

if ($failCount -gt 0) {
  exit 1
}

exit 0
