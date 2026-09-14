import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class StoreProfileFinalContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.profile = json.loads((ROOT / "config/store/store-profile.json").read_text(encoding="utf-8"))
        cls.lineage = json.loads((ROOT / "config/store/screenshot-lineage.json").read_text(encoding="utf-8"))
        cls.readme = (ROOT / "docs/store/README.md").read_text(encoding="utf-8")
        cls.ledger = json.loads(
            (ROOT / ".codex/tasks/planflow-store-profile-final-qualification-20260914.json").read_text(encoding="utf-8")
        )

    def test_rewarded_acceptance_is_fail_closed(self):
        ios_ads = self.profile["content"]["ads"]["ios"]
        self.assertIn("EXTERNAL_DEPENDENCY_HOLD", ios_ads["note"])
        self.assertIn("CURRENT_PRODUCTION_FEATURE_ACCEPTANCE=BLOCKED", ios_ads["note"])
        self.assertIn("Build25 observed RewardedAd.load code=1 (No ad to show)", ios_ads["note"])
        self.assertIn("CURRENT_PRODUCTION_FEATURE_ACCEPTANCE=BLOCKED", self.readme)
        self.assertEqual(self.ledger["rewardedAcceptance"]["Rewarded"], "EXTERNAL_DEPENDENCY_HOLD")
        self.assertEqual(self.ledger["rewardedAcceptance"]["CURRENT_PRODUCTION_FEATURE_ACCEPTANCE"], "BLOCKED")
        self.assertEqual(self.ledger["rewardedAcceptance"]["servingClaim"], "NOT_ASSERTED")

    def test_readiness_and_protection_are_authoritative(self):
        readiness = self.ledger["finalReadiness"]
        self.assertEqual(readiness["dryRuns"], {
            "A": "BLOCKED_EXTERNAL_LINKED_WORKTREE_REPOSUBPATH_RESOLVER",
            "B": "BLOCKED_EXTERNAL_LINKED_WORKTREE_REPOSUBPATH_RESOLVER",
            "C": "BLOCKED_EXTERNAL_LINKED_WORKTREE_REPOSUBPATH_RESOLVER",
            "D": "BLOCKED_EXTERNAL_LINKED_WORKTREE_REPOSUBPATH_RESOLVER",
            "E": "PASS_PROJECT_ISOLATION",
        })
        self.assertEqual(readiness["storeMutations"], 0)
        self.assertEqual(readiness["protection"]["iosBuild23"], "PROTECTED")
        self.assertEqual(readiness["protection"]["androidProduction"], "PROTECTED")
        self.assertEqual(readiness["NEXT_RELEASE_AUTOMATION_READY"], "NO")
        self.assertEqual(readiness["STORE_POLICY_ENGINE_READY"], "NO")
        self.assertEqual(readiness["NEXT_RELEASE_AUTOMATION_OWNER"], "FluxStore")
        self.assertEqual(readiness["STORE_POLICY_ENGINE_OWNER"], "FluxStore")
        self.assertIn("repoSubpath resolver", readiness["NEXT_RELEASE_AUTOMATION_EXACT_UNBLOCK"])
        self.assertIn("repoSubpath resolver", readiness["STORE_POLICY_ENGINE_EXACT_UNBLOCK"])

    def test_native_screenshot_and_blocker_alignment(self):
        blockers = {item["code"] for item in self.profile["blockers"]}
        self.assertEqual(blockers, {
            "ANDROID_TABLET_LIVE_PII_REPLACEMENT_REQUIRED",
            "DATA_SAFETY_DOC_STALE_AD_ID",
            "IOS_SCREENSHOTS_ANDROID_CAPTURE_2_3_10",
            "APP_PRIVACY_COMPARE_UNAVAILABLE",
            "IOS_STORE_READBACK_NOT_ACCEPTED",
        })
        native = [item for item in self.lineage["screenshots"] if item["screenshotId"].endswith("-native")]
        self.assertEqual(len([item for item in native if item["slot"] == "IPHONE"]), 3)
        self.assertEqual(len([item for item in native if item["slot"] == "IPAD"]), 2)
        self.assertTrue(all(item["qualificationState"] == "LOCAL_QUALIFIED" for item in native))
        self.assertTrue(all(item["storeUploadState"] == "NOT_UPLOADED" for item in native))
        for code in blockers:
            self.assertIn(code, self.readme)

    def test_category_and_decision_alignment(self):
        category = self.profile["storeMetadata"]["ios"]
        self.assertEqual(category["category"]["value"], "productivity")
        self.assertEqual(category["category"]["source"], "STORE_READBACK")
        self.assertEqual(category["secondaryCategory"]["value"], "utilities")
        self.assertEqual(category["secondaryCategory"]["source"], "STORE_READBACK")
        self.assertIn("PRODUCTIVITY", self.readme)
        self.assertIn("UTILITIES", self.readme)
        self.assertNotIn("secondary category는 사용자 확인이나 readback이 없어", self.readme)
        decisions = {item["code"] for item in self.profile["decisionsRequired"]}
        section = self.readme.split("## 사용자 결정 필요 (decisionsRequired)", 1)[1].split("## 기준선", 1)[0]
        readme_decisions = set(re.findall(r"^\| ([A-Z][A-Z0-9_]+) \|", section, re.MULTILINE))
        self.assertEqual(readme_decisions, decisions)
        for stale in ("IOS_ADS_TRACKING_ANSWER", "CHILD_DIRECTED", "UGC_MODERATION"):
            self.assertNotIn(stale, readme_decisions)

    def test_unknown_summary_is_derived_from_profile(self):
        expected = set()

        def visit(value, path=""):
            if isinstance(value, dict):
                if "value" in value and "source" in value and (
                    value["value"] is None or value["source"] == "UNKNOWN"
                ):
                    expected.add(path)
                for key, child in value.items():
                    visit(child, f"{path}.{key}" if path else key)
            elif isinstance(value, list):
                for index, child in enumerate(value):
                    visit(child, f"{path}[{index}]")

        visit(self.profile)
        section = self.readme.split("## 모르는 값 (UNKNOWN)", 1)[1].split("---", 1)[0]
        listed = set(re.findall(r"^- `([^`]+)`", section, re.MULTILINE))
        self.assertEqual(listed, expected)
        for confirmed in (
            "storeMetadata.ios.secondaryCategory",
            "storeMetadata.ios.privacyPolicyUrl",
            "privacy.ios.dataTypes.advertisingData.collected",
            "privacy.ios.dataTypes.photos.collected",
            "content.childDirected",
            "content.ads.ios",
            "monetization.model.ios",
            "monetization.ads.ios",
        ):
            self.assertNotIn(confirmed, listed)


if __name__ == "__main__":
    unittest.main()
