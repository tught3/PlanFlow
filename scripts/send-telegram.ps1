param(
  [Parameter(Mandatory = $true)]
  [string]$Title,

  [Parameter(Mandatory = $true)]
  [string]$Message,

  [string]$EnvPath = (Join-Path (Split-Path -Parent $PSScriptRoot) '.env')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-EnvValue {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Key
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  $encoding = [System.Text.UTF8Encoding]::new($false)
  $lines = [System.IO.File]::ReadAllLines($Path, $encoding)
  foreach ($line in $lines) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith('#')) {
      continue
    }
    if ($trimmed -notmatch '^(?<key>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?<value>.*)$') {
      continue
    }
    if ($Matches.key -ne $Key) {
      continue
    }

    $value = $Matches.value.Trim()
    if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
      $value = $value.Substring(1, $value.Length - 2)
    } elseif ($value.StartsWith("'") -and $value.EndsWith("'") -and $value.Length -ge 2) {
      $value = $value.Substring(1, $value.Length - 2)
    }
    return $value
  }

  return $null
}

try {
  Add-Type -AssemblyName System.Net.Http
  [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

  $token = Read-EnvValue -Path $EnvPath -Key 'TELEGRAM_BOT_TOKEN'
  $chatId = Read-EnvValue -Path $EnvPath -Key 'TELEGRAM_CHAT_ID'

  if ([string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($chatId)) {
    return [pscustomobject]@{
      Ok      = $false
      Skipped = $true
      Reason  = 'TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID missing in .env'
    }
  }

  $payload = [pscustomobject]@{
    chat_id                  = $chatId
    text                     = "$Title`n$Message"
    disable_web_page_preview = $true
  } | ConvertTo-Json -Compress

  $client = [System.Net.Http.HttpClient]::new()
  try {
    $client.Timeout = [TimeSpan]::FromSeconds(5)
    $content = [System.Net.Http.StringContent]::new($payload, [System.Text.Encoding]::UTF8, 'application/json')
    $response = $client.PostAsync("https://api.telegram.org/bot$token/sendMessage", $content).GetAwaiter().GetResult()
    $responseText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
      throw "Telegram HTTP $([int]$response.StatusCode): $responseText"
    }

    $parsed = $responseText | ConvertFrom-Json
    return [pscustomobject]@{
      Ok      = [bool]$parsed.ok
      Skipped = $false
      Status  = 'sent'
    }
  } finally {
    $client.Dispose()
  }
} catch {
  return [pscustomobject]@{
    Ok      = $false
    Skipped = $false
    Error   = $_.Exception.Message
  }
}
