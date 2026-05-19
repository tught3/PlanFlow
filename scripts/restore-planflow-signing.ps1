param(
  [string]$ArchivePath = "android/signing/PlanFlow-signing-keys.zip.aes",
  [string]$OutputRoot = "android",
  [string]$PasswordFile,
  [switch]$Force
)

$ErrorActionPreference = "Stop"

function ConvertTo-PlainText([securestring]$SecureValue) {
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
  }
}

if ($PasswordFile) {
  $password = (Get-Content -LiteralPath $PasswordFile -Raw).Trim()
} else {
  $securePassword = Read-Host "PlanFlow signing archive password" -AsSecureString
  $password = ConvertTo-PlainText $securePassword
}

if ([string]::IsNullOrWhiteSpace($password)) {
  throw "Archive password is empty."
}

$archive = Resolve-Path -LiteralPath $ArchivePath -ErrorAction Stop
$bytes = [IO.File]::ReadAllBytes($archive)
$magic = [Text.Encoding]::ASCII.GetString($bytes, 0, 6)
if ($magic -ne "PFSGN1") {
  throw "Unsupported PlanFlow signing archive format."
}

$salt = New-Object byte[] 16
$iv = New-Object byte[] 16
[Array]::Copy($bytes, 6, $salt, 0, 16)
[Array]::Copy($bytes, 22, $iv, 0, 16)
$cipher = New-Object byte[] ($bytes.Length - 38)
[Array]::Copy($bytes, 38, $cipher, 0, $cipher.Length)

$kdf = [Security.Cryptography.Rfc2898DeriveBytes]::new($password, $salt, 200000)
$key = $kdf.GetBytes(32)
$aes = [Security.Cryptography.Aes]::Create()
$aes.Mode = [Security.Cryptography.CipherMode]::CBC
$aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
$aes.Key = $key
$aes.IV = $iv

$decryptor = $aes.CreateDecryptor()
try {
  $plain = $decryptor.TransformFinalBlock($cipher, 0, $cipher.Length)
} finally {
  $decryptor.Dispose()
  $aes.Dispose()
  $kdf.Dispose()
  $password = $null
}

$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("planflow-signing-" + [Guid]::NewGuid().ToString("N"))
try {
  New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
  $zipPath = Join-Path $tempDir "planflow-signing.zip"
  [IO.File]::WriteAllBytes($zipPath, $plain)
  Expand-Archive -LiteralPath $zipPath -DestinationPath $tempDir -Force

  $keystoreSource = Join-Path $tempDir "planflow-release.jks"
  $propertiesSource = Join-Path $tempDir "key.properties"
  if (!(Test-Path -LiteralPath $keystoreSource) -or !(Test-Path -LiteralPath $propertiesSource)) {
    throw "Archive is missing planflow-release.jks or key.properties."
  }

  $keystoreTarget = Join-Path $OutputRoot "app/planflow-release.jks"
  $propertiesTarget = Join-Path $OutputRoot "key.properties"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $keystoreTarget) | Out-Null

  foreach ($target in @($keystoreTarget, $propertiesTarget)) {
    if ((Test-Path -LiteralPath $target) -and !$Force) {
      throw "$target already exists. Re-run with -Force to overwrite."
    }
  }

  Copy-Item -LiteralPath $keystoreSource -Destination $keystoreTarget -Force:$Force
  Copy-Item -LiteralPath $propertiesSource -Destination $propertiesTarget -Force:$Force
} finally {
  if (Test-Path -LiteralPath $tempDir) {
    Remove-Item -LiteralPath $tempDir -Recurse -Force
  }
}

Write-Host "PlanFlow signing files restored. No secrets were printed."
