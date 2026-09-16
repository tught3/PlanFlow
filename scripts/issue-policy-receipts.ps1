<#
issue-policy-receipts.ps1

FLUXSTORE Authority Receipt v2 -- batch signer/issuer for PlanFlow's
NO_SIGNED_DECISION subjects.

WHAT THIS DOES
  For every profile-subject blocker whose issuance is currently blocked by
  *only* NO_SIGNED_DECISION (i.e. the value/principal/registry ladder is
  already satisfied and the only missing thing is a human signature), this
  script:
    1. runs `authority adjudicate` to get the live decision-request list,
    2. filters to signable==true subjects, minus a hardcoded field
       blocklist (belt-and-suspenders -- see FILTERING below),
    3. writes each subject's exact statementCanonical bytes to a temp file,
    4. signs it with `ssh-keygen -Y sign` under your policy-authority key,
    5. fetches a *fresh* per-subject planDigest via `issuance-plan`,
    6. calls `authority issue --issue` to publish the v2 receipt.

  This script itself only ever *writes* by calling `authority issue
  --issue`, which is the one function in fluxstore.issuance that mutates
  anything on disk (a receipt file under the fixed, non-configurable
  receipt store root). Every other step here is read-only.

EXACT COUNT (measured 2026-09-16 against PlanFlow's live plan; re-verify by
re-running the DRY-RUN COUNT ONLY block below before trusting this number
again -- it will drift as fields get answered/receipts get issued):
  - 48 total profile-subject decision-request rows (canonicalPolicyId x
    platform x storeSurface x decisionReason combinations).
  - 38 are signable==true right now (blockers == [NO_SIGNED_DECISION] only)
    -- this script issues receipts for these 38.
  - 10 are signable==false and this script never touches them, spanning 6
    distinct canonicalPolicyId fields (NOT 4 -- see NOTE ON SCOPE below):
      profile:content.encryption            (2 rows: HPAR + SPDR)
      profile:content.medicalClaims         (1 row:  HPAR)
      profile:content.traderStatus          (2 rows: HPAR + SPDR)
      profile:content.ageRating.android     (2 rows: HPAR + SPDR)
      profile:content.ageRating.ios         (1 row:  SPDR)
      profile:privacy.ios.dataTypes.advertisingData.purposes (2 rows: HPAR + SPDR)

NOTE ON SCOPE (deviation from the original 4-field assumption): the
original request named only 4 fields as VALUE_UNANSWERED-blocked
(traderStatus, ageRating android/ios, iOS advertisingData.purposes).
Live measurement (fluxstore authority adjudicate against PlanFlow,
2026-09-16) shows 6 distinct fields / 10 rows are actually non-signable
right now -- content.encryption (VALUE_FAILS_FIELD_VALIDATOR +
PRINCIPAL_SCOPE_UNCOVERED) and content.medicalClaims
(PRINCIPAL_SCOPE_UNCOVERED) are ALSO blocked, not just the 4 named fields.
Rather than hardcode a blocklist that would have silently under-protected
2 extra fields, this script's PRIMARY filter is the live `signable` flag
computed by fluxstore.issuance for each subject at run time -- that is the
authoritative "is this actually safe to sign" answer, always freshly
recomputed, never a stale snapshot. The 4-field HARDCODED_FIELD_BLOCKLIST
below is kept ONLY as a secondary defense-in-depth check (never touched
even if some future code change made `signable` wrongly return true for
one of these 4) -- it is deliberately not the only guard.

FIELDS THIS SCRIPT NEVER TOUCHES (hardcoded blocklist, secondary guard):
  - profile:content.traderStatus
  - profile:content.ageRating.android
  - profile:content.ageRating.ios
  - profile:privacy.ios.dataTypes.advertisingData.purposes
  (content.encryption / content.medicalClaims are excluded too, but only
  via the live signable-flag check above, not via this hardcoded list.)

PER-STEP FAILURE HANDLING: each subject is independent. If any step for a
given subject fails (schema invalid, statement byte mismatch, stale plan
digest, signature verification failure, etc.), that subject is recorded as
FAILED with the reason and the script moves on to the next subject. The
whole run never aborts on a single subject's failure.

PREREQUISITES:
  - `python` on PATH able to import fluxstore from
    E:\FluxStudio\tools\flux-release\store (this script cd's there).
  - `ssh-keygen` on PATH (Windows 10+/11 OpenSSH client, or Git's).
  - Private key at ~/.ssh/fluxstore-policy-authority-20260916 (passphrase
    prompts, if any, appear interactively -- run this in a real terminal,
    not unattended).
  - principals.json already has the `planflow-ceo` principal registered
    (already true per this session's prep -- not re-verified here).

RUN:
  pwsh -NoProfile -File E:\FluxStudio\PlanFlow\scripts\issue-policy-receipts.ps1

VERIFY AFTER RUNNING (must report zero non-receipt mutations; also re-run
`authority adjudicate` to confirm the 38 subjects now show
VALID_RECEIPT_ALREADY_EXISTS / automaticallyResolved count increased by up
to 38):
  cd E:\FluxStudio\tools\flux-release\store
  python -m fluxstore.cli plan --json --project-root E:\FluxStudio\PlanFlow `
    --mode dry-run --out <scratch-dir> --assert-zero-mutation
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot = "E:\FluxStudio\PlanFlow",
    [string]$ToolStoreDir = "E:\FluxStudio\tools\flux-release\store",
    [string]$PrivateKeyPath = (Join-Path $HOME ".ssh\fluxstore-policy-authority-20260916"),
    [string]$Namespace = "fluxstore-policy-decision@v1",
    [string]$WorkDir = (Join-Path $env:TEMP ("fluxstore-receipt-issue-" + (Get-Date -Format "yyyyMMdd-HHmmss")))
)

$ErrorActionPreference = "Stop"

# Secondary, defense-in-depth guard only -- see NOTE ON SCOPE above. The
# PRIMARY guard is the live `signable` flag read per-subject from
# `authority adjudicate`'s decision-requests output, not this list.
$HardcodedFieldBlocklist = @(
    "profile:content.traderStatus",
    "profile:content.ageRating.android",
    "profile:content.ageRating.ios",
    "profile:privacy.ios.dataTypes.advertisingData.purposes"
)

function Invoke-FluxstoreCli {
    param(
        [Parameter(Mandatory = $true)][string[]]$CliArgs
    )
    Push-Location $ToolStoreDir
    try {
        $stdout = & python -m fluxstore.cli @CliArgs 2>$null
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{ Stdout = ($stdout -join "`n"); ExitCode = $exitCode }
    } finally {
        Pop-Location
    }
}

function ConvertFrom-JsonSafe {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try {
        return $Text | ConvertFrom-Json -Depth 64
    } catch {
        return $null
    }
}

if (-not (Test-Path $PrivateKeyPath)) {
    throw "Private key not found at $PrivateKeyPath -- aborting before touching any subject."
}
if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    throw "ssh-keygen not found on PATH -- aborting before touching any subject."
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$adjudicateOut = Join-Path $WorkDir "adjudication"
New-Item -ItemType Directory -Force -Path $adjudicateOut | Out-Null

Write-Host "== Step 1: adjudicate (read-only) =="
$adjResult = Invoke-FluxstoreCli -CliArgs @(
    "authority", "--json", "--project-root", $ProjectRoot,
    "adjudicate", "--out", $adjudicateOut
)
$adjJson = ConvertFrom-JsonSafe $adjResult.Stdout
if (-not $adjJson) {
    throw "adjudicate produced no parseable JSON on stdout (exit=$($adjResult.ExitCode)). Aborting before touching any subject."
}
Write-Host "  adjudicate status: $($adjJson.status) (exit=$($adjResult.ExitCode))"

$requestsPath = Join-Path $adjudicateOut "decision-requests.request.json"
if (-not (Test-Path $requestsPath)) {
    throw "decision-requests.request.json not found at $requestsPath -- aborting."
}
$requestsDoc = Get-Content $requestsPath -Raw | ConvertFrom-Json -Depth 64
$allRequests = @($requestsDoc.requests)
Write-Host "  total decision-request rows: $($allRequests.Count)"

# --- Filtering -------------------------------------------------------------
# PRIMARY filter: live signable flag (see NOTE ON SCOPE in the header).
# SECONDARY filter: hardcoded field blocklist (defense-in-depth only).
$candidates = @()
$skippedNotSignable = @()
$skippedBlocklisted = @()
foreach ($req in $allRequests) {
    $cpid = $req.currentInputs.policyImpact.canonicalPolicyId
    $platform = $req.currentInputs.policyImpact.platform
    $surface = $req.currentInputs.policyImpact.storeSurface
    $reason = $req.currentInputs.policyImpact.decisionReason

    if ($HardcodedFieldBlocklist -contains $cpid) {
        $skippedBlocklisted += [pscustomobject]@{ CanonicalPolicyId = $cpid; Platform = $platform; StoreSurface = $surface; DecisionReason = $reason }
        continue
    }
    if (-not $req.signable) {
        $skippedNotSignable += [pscustomobject]@{ CanonicalPolicyId = $cpid; Platform = $platform; StoreSurface = $surface; DecisionReason = $reason; IssuanceBlockers = ($req.issuanceBlockers -join ",") }
        continue
    }
    if (-not $req.statementCanonical) {
        $skippedNotSignable += [pscustomobject]@{ CanonicalPolicyId = $cpid; Platform = $platform; StoreSurface = $surface; DecisionReason = $reason; IssuanceBlockers = "signable=true but statementCanonical missing (unexpected)" }
        continue
    }

    $candidates += [pscustomobject]@{
        CanonicalPolicyId  = $cpid
        Platform           = $platform
        StoreSurface       = $surface
        DecisionReason     = $reason
        ValueDigest        = $req.valueDigest
        StatementCanonical = $req.statementCanonical
    }
}

Write-Host "  candidates to issue: $($candidates.Count)"
Write-Host "  skipped (blocklisted, never touched): $($skippedBlocklisted.Count)"
Write-Host "  skipped (not signable right now): $($skippedNotSignable.Count)"

$succeeded = @()
$failed = @()

$idx = 0
foreach ($c in $candidates) {
    $idx++
    $safeName = ($c.CanonicalPolicyId + "_" + $c.Platform + "_" + $c.StoreSurface + "_" + $c.DecisionReason) -replace '[^A-Za-z0-9_.-]', '_'
    Write-Host "== [$idx/$($candidates.Count)] $($c.CanonicalPolicyId) ($($c.Platform)/$($c.StoreSurface)/$($c.DecisionReason)) =="

    try {
        $statementPath = Join-Path $WorkDir "$safeName.statement.json"
        $signaturePath = "$statementPath.sig"

        # Write the EXACT bytes of statementCanonical -- no BOM, no trailing
        # newline (fluxstore.issuance.issue() compares statement_bytes
        # byte-for-byte against its own freshly recomputed canonical form).
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($statementPath, $c.StatementCanonical, $utf8NoBom)

        Write-Host "  signing with ssh-keygen -Y sign ..."
        & ssh-keygen -Y sign -n $Namespace -f $PrivateKeyPath $statementPath
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $signaturePath)) {
            throw "ssh-keygen -Y sign failed (exit=$LASTEXITCODE) or did not produce $signaturePath"
        }

        Write-Host "  fetching fresh planDigest ..."
        $planResult = Invoke-FluxstoreCli -CliArgs @(
            "authority", "--json", "--project-root", $ProjectRoot,
            "issuance-plan",
            "--canonical-policy-id", $c.CanonicalPolicyId,
            "--decision-reason", $c.DecisionReason,
            "--platform", $c.Platform,
            "--store-surface", $c.StoreSurface
        )
        $planJson = ConvertFrom-JsonSafe $planResult.Stdout
        if (-not $planJson -or -not $planJson.issuable -or -not $planJson.planDigest) {
            throw "issuance-plan not issuable right now (exit=$($planResult.ExitCode), issuable=$($planJson.issuable), blockers=$($planJson.issuanceBlockers -join ','))"
        }

        $statementObj = ConvertFrom-JsonSafe $c.StatementCanonical
        $principalId = $statementObj.principalId
        if (-not $principalId) {
            throw "could not parse principalId out of statementCanonical"
        }

        Write-Host "  issuing (principal=$principalId) ..."
        $issueResult = Invoke-FluxstoreCli -CliArgs @(
            "authority", "--json", "--project-root", $ProjectRoot,
            "issue", "--issue",
            "--canonical-policy-id", $c.CanonicalPolicyId,
            "--decision-reason", $c.DecisionReason,
            "--platform", $c.Platform,
            "--store-surface", $c.StoreSurface,
            "--statement", $statementPath,
            "--signature", $signaturePath,
            "--principal", $principalId,
            "--confirm-subject", $c.CanonicalPolicyId,
            "--confirm-value-digest", $c.ValueDigest,
            "--plan-digest", $planJson.planDigest
        )
        $issueJson = ConvertFrom-JsonSafe $issueResult.Stdout
        if (-not $issueJson -or $issueJson.status -notin @("PUBLISHED", "IDEMPOTENT_EXISTS")) {
            throw "issue rejected (exit=$($issueResult.ExitCode), status=$($issueJson.status), codes=$($issueJson.codes -join ','))"
        }

        Write-Host "  OK: $($issueJson.status) -> $($issueJson.path)"
        $succeeded += [pscustomobject]@{
            CanonicalPolicyId = $c.CanonicalPolicyId; Platform = $c.Platform; StoreSurface = $c.StoreSurface
            DecisionReason = $c.DecisionReason; Status = $issueJson.status; Path = $issueJson.path
        }
    } catch {
        Write-Warning "  FAILED: $($_.Exception.Message)"
        $failed += [pscustomobject]@{
            CanonicalPolicyId = $c.CanonicalPolicyId; Platform = $c.Platform; StoreSurface = $c.StoreSurface
            DecisionReason = $c.DecisionReason; Reason = $_.Exception.Message
        }
    }
}

Write-Host ""
Write-Host "==================== SUMMARY ===================="
Write-Host "Total candidates attempted : $($candidates.Count)"
Write-Host "Succeeded (PUBLISHED/IDEMPOTENT_EXISTS) : $($succeeded.Count)"
Write-Host "Failed : $($failed.Count)"
Write-Host "Skipped (blocklisted, never touched) : $($skippedBlocklisted.Count)"
Write-Host "Skipped (not signable right now) : $($skippedNotSignable.Count)"
Write-Host ""
if ($succeeded.Count -gt 0) {
    Write-Host "-- Succeeded --"
    $succeeded | Format-Table -AutoSize | Out-String | Write-Host
}
if ($failed.Count -gt 0) {
    Write-Host "-- Failed --"
    $failed | Format-Table -AutoSize | Out-String | Write-Host
}
Write-Host "Work directory (statements/signatures/adjudication artifacts): $WorkDir"
Write-Host ""
Write-Host "Next: verify zero non-receipt mutations with:"
Write-Host "  cd $ToolStoreDir"
Write-Host "  python -m fluxstore.cli plan --json --project-root $ProjectRoot --mode dry-run --out $WorkDir\verify-plan --assert-zero-mutation"
