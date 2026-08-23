import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "scripts" / "deploy-play-production.ps1").read_text(encoding="utf-8")
EXAMPLE = json.loads((ROOT / "config" / "play-production.example.json").read_text(encoding="utf-8"))


def test_production_example_is_fail_closed_and_uses_production_track():
    assert EXAMPLE["enabled"] is False
    assert EXAMPLE["track"] == "production"
    assert EXAMPLE["packageName"] == "com.fluxstudio.planflow"


def test_wrapper_requires_explicit_confirmation_and_rejects_example_for_upload():
    assert "[switch]$ConfirmProductionRollout" in SCRIPT
    assert "-ForUpload:$ConfirmProductionRollout" in SCRIPT
    assert "The example production config cannot be used" in SCRIPT
    assert "No upload performed. This is the default fail-closed preflight mode." in SCRIPT


def test_wrapper_requires_map_safe_build_and_production_gradle_track():
    assert "build-internal-aab.ps1" in SCRIPT
    assert "map artifact marker" in SCRIPT
    assert "'--track' 'production'" in SCRIPT
    assert "-PplanflowPlayTrack=production" in SCRIPT
    # banned-ok: contract assertion verifies the production wrapper does not invoke direct Flutter builds.
    assert "flutter build appbundle" not in SCRIPT


def test_gradle_guard_accepts_only_explicit_supported_tracks():
    gradle = (ROOT / "android" / "app" / "build.gradle.kts").read_text(encoding="utf-8")
    assert 'providers.gradleProperty("planflowPlayTrack")' in gradle
    assert 'setOf("internal", "alpha", "production")' in gradle
    assert 'track.set(planflowPlayTrack)' in gradle
    assert 'planflowProductionRolloutToken' in gradle
    assert 'planflowProductionRolloutReceipt' in gradle
    assert 'rollout receipt is invalid' in gradle
    assert 'receiptFile.delete()' in gradle
    assert 'Production publish blocked' in gradle


def test_wrapper_validates_service_account_for_rollout():
    assert "production service account JSON" in SCRIPT
    assert "service_account" in SCRIPT
    assert "Set enabled=true only in the local, untracked production config" in SCRIPT
    assert "planflowProductionRolloutToken" in SCRIPT
    assert "planflowProductionRolloutReceipt" in SCRIPT
    assert "issuedAtEpochMillis" in SCRIPT
