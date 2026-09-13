import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
POLICY = ROOT / "docs/store/planflow-privacy-policy-final.md"
PROFILE = ROOT / "config/store/store-profile.json"
TASK = ROOT / ".codex/tasks/planflow-privacy-final-gate-closure-20260913.json"

class PrivacyPolicyContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = POLICY.read_text(encoding="utf-8")
        cls.profile = json.loads(PROFILE.read_text(encoding="utf-8"))
        cls.task = json.loads(TASK.read_text(encoding="utf-8"))

    def test_public_facts_and_boundaries(self):
        for value in ("Flux Studio", "경기도 성남시 광명로 75 303호", "대표자", "support@fluxstudio.co.kr"):
            self.assertIn(value, self.text)
        self.assertIn("만 14세 미만 아동을 대상으로 설계하거나 제공하지 않습니다", self.text)
        self.assertIn("공개 게시판이나 공개 피드는 운영하지 않습니다", self.text)
        self.assertIn("인증된 그룹 구성원 사이", self.text)
        self.assertIn("보상형 광고", self.text)
        self.assertIn("ATT 권한 요청이나 IDFA 직접 접근이 없고", self.text)
        self.assertIn("iOS IDFA 메시지가 구성되어 있지 않습니다", self.text)
        self.assertIn("UMP는 동의 정보를 처리하는 SDK이며 그 존재만으로 ATT 요청이나 추적을 의미하지 않습니다", self.text)
        self.assertIn("향후 AdMob IDFA 메시지를 새로 구성하거나 활성화하면", self.text)
        self.assertIn("그룹 백업 스냅샷", self.text)
        self.assertIn("해당 백업 생성자가 삭제할 때까지 남을 수", self.text)
        self.assertIn("그룹 백업에 대해 확인된 자동 보관기간은 없습니다", self.text)
        self.assertNotIn("그룹 백업 순환기간", self.text)
        self.assertNotIn("위 백업·스냅샷 순환 정책에 따라 삭제", self.text)

    def test_retention_and_provider_disclosures(self):
        for value in ("계정 삭제 시", "최대 365일", "최대 12개월", "최대 30일", "일본(도쿄)", "Supabase", "OpenAI", "TMAP"):
            self.assertIn(value, self.text)
        self.assertIn("원시 음성은 기기 내", self.text)

    def test_no_internal_or_secret_content(self):
        self.assertNotRegex(self.text, r"(?:[A-Za-z]:\\|lib/|ios/|\.github/)")
        self.assertNotRegex(self.text, r"ca-app-pub-\d+[~/]\d+")
        self.assertNotIn("placeholder", self.text.lower())
        self.assertEqual(
            set(re.findall(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", self.text)),
            {"support@fluxstudio.co.kr"},
        )

    def test_profile_states_and_protected_release(self):
        self.assertFalse(self.profile["privacy"]["tracking"]["value"])
        self.assertEqual(self.profile["privacy"]["tracking"]["source"], "USER_CONFIRMED_AUTHENTICATED_CONSOLE")
        self.assertFalse(self.profile["privacy"]["tracking"]["requiresHumanAuthority"])
        ios_ads = self.profile["privacy"]["ios"]["dataTypes"]["advertisingData"]
        self.assertTrue(ios_ads["collected"]["value"])
        self.assertFalse(ios_ads["usedForTracking"]["value"])
        self.assertEqual(ios_ads["usedForTracking"]["source"], "USER_CONFIRMED_AUTHENTICATED_CONSOLE")
        self.assertFalse(self.profile["content"]["ugc"]["value"])
        self.assertFalse(self.profile["content"]["childDirected"]["value"])
        blockers = {item["code"] for item in self.profile["blockers"]}
        self.assertIn("PRIVACY_POLICY_MISMATCH", blockers)
        self.assertNotIn("IOS_ADS_TRACKING_ANSWER_UNKNOWN", blockers)
        decisions = {item["code"] for item in self.profile["decisionsRequired"]}
        self.assertNotIn("IOS_ADS_TRACKING_ANSWER", decisions)
        for stale in ("CHILD_DIRECTED", "UGC_MODERATION", "IOS_ATT_USAGE_STRING"):
            self.assertNotIn(stale, decisions)
        protected = {item["target"] for item in self.profile["protectedTargets"]}
        self.assertIn("current_submission:1.1.1(23)", protected)
        self.assertTrue(self.profile["qualificationMode"])
        self.assertEqual(self.task["protection"]["storeMutations"], 0)
        self.assertEqual(self.task["protection"]["iosBuild23"], "PROTECTED")
        self.assertEqual(self.task["protection"]["androidProduction"], "PROTECTED")
        self.assertEqual(self.task["protection"]["rewarded"], "EXTERNAL_DEPENDENCY_HOLD")
        contract = next(item for item in self.profile["privacyChangeContracts"] if item["code"] == "IOS_IDFA_MESSAGE_STATE_CHANGE")
        self.assertEqual(contract["currentState"], "NOT_CONFIGURED")
        self.assertEqual(set(contract["requiredActions"]), {
            "PRIVACY_CHANGE_REQUIRED",
            "ATT_REASSESSMENT_REQUIRED",
            "APP_PRIVACY_REASSESSMENT_REQUIRED",
        })
        self.assertEqual(self.task["evidence"]["idfaMessageState"], "NOT_CONFIGURED")
        self.assertEqual(self.task["evidence"]["admobIdfaMutationCount"], 0)

if __name__ == "__main__":
    unittest.main()
