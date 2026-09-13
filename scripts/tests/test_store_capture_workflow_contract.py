"""Contract tests for the CI-only iOS screenshot capture pipeline."""
import json
import re
import struct
import subprocess
import tempfile
import unittest
import zlib
from pathlib import Path

ROOT = Path(__file__).parents[2]
WORKFLOW = (ROOT / '.github/workflows/store-screenshot-capture.yml').read_text()
PLAN = json.loads((ROOT / 'config/store/capture-plan.json').read_text())


def _png_chunk(kind, payload):
    checksum = zlib.crc32(kind)
    checksum = zlib.crc32(payload, checksum) & 0xFFFFFFFF
    return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', checksum)


def _valid_png(width, height, marker):
    """Return a fully decodable, opaque RGB PNG with deterministic identity."""
    first_row = bytearray(width * 3)
    first_row[:3] = bytes((marker, 37, 91))
    empty_row = bytes(width * 3)
    pixels = b'\x00' + bytes(first_row)
    pixels += (b'\x00' + empty_row) * (height - 1)
    ihdr = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    return (
        b'\x89PNG\r\n\x1a\n'
        + _png_chunk(b'IHDR', ihdr)
        + _png_chunk(b'IDAT', zlib.compress(pixels, level=9))
        + _png_chunk(b'IEND', b'')
    )


class ScreenshotCaptureContractTests(unittest.TestCase):
    def test_workflow_is_manual_read_only_macos15(self):
        self.assertIn('workflow_dispatch:', WORKFLOW)
        self.assertNotIn('push:', WORKFLOW)
        self.assertIn('runs-on: macos-15', WORKFLOW)
        self.assertIn('contents: read', WORKFLOW)

    def test_no_external_store_or_production_surface(self):
        for token in ('appstoreconnect', 'appStoreConnect', 'androidpublisher',
                      'altool', 'notarytool', 'SUPABASE_ANON_KEY: ${{ secrets.'):
            self.assertNotIn(token, WORKFLOW)
        self.assertIn('fixture.invalid', WORKFLOW)
        self.assertIn('persist-credentials: false', WORKFLOW)

    def test_plan_is_exact_minimum_matrix(self):
        self.assertEqual(PLAN['schemaVersion'], 1)
        self.assertEqual({d['slot'] for d in PLAN['devices']}, {'IPHONE', 'IPAD'})
        self.assertEqual(len(PLAN['shots']), 5)
        self.assertEqual(len([s for s in PLAN['shots'] if s['screenshotId'].startswith('iphone69-')]), 3)
        self.assertEqual(len([s for s in PLAN['shots'] if s['screenshotId'].startswith('ipad13-')]), 2)
        self.assertIn('statusBarOverride', PLAN['determinism'])
        self.assertEqual(PLAN['determinism']['statusBarOverride']['time'], '9:41')
        self.assertEqual(
            {slot for shot in PLAN['shots'] for slot in shot['deviceSlots']},
            {'IPHONE', 'IPAD'},
        )
        self.assertEqual(
            {(d['slot'], d['width'], d['height']) for d in PLAN['devices']},
            {('IPHONE', 1320, 2868), ('IPAD', 2064, 2752)},
        )
        ids = [shot['screenshotId'] for shot in PLAN['shots']]
        self.assertEqual(len(ids), len(set(ids)))

    def test_workflow_has_required_capture_guards(self):
        for token in ('simctl list devices -j', 'simctl bootstatus',
                      'status_bar', 'AppleLocale',
                      'flutter drive', 'store_screenshot_driver.dart',
                      'validate_store_screenshots.py', 'qualification',
                      'NOT_UPLOADED',
                      'actions/upload-artifact@v4', 'trap cleanup EXIT'):
            self.assertIn(token, WORKFLOW)

    def test_run_blocks_do_not_inline_expressions(self):
        for block in re.findall(r'(?ms)^\s+run: \|\n(.*?)(?=^\s+- name:|^\s+uses:|\Z)', WORKFLOW):
            self.assertNotIn('${{', block)

    def test_driver_writes_host_side_pngs(self):
        driver = (ROOT / 'test_driver/store_screenshot_driver.dart').read_text()
        self.assertIn('integrationDriver', driver)
        self.assertIn('onScreenshot', driver)
        self.assertIn('writeAsBytes', driver)

    def test_fixture_driver_binds_real_planflow_screens_and_content(self):
        source = (ROOT / 'integration_test/store_screenshot_capture_test.dart').read_text(encoding='utf-8')
        for widget in ('HomeScreen', 'CalendarScreen', 'ConfirmScreen', 'GroupDashboardScreen'):
            self.assertIn(widget, source)
        for value in ('팀 주간 회의', 'PlanFlow 데모 그룹', '그룹 일정 공유',
                      '_OfflineEventRepository', '_OfflineGroupRepository'):
            self.assertIn(value, source)
        self.assertNotIn('Supabase.initialize', source)

    def test_manifest_is_pending_and_never_local_qualified(self):
        self.assertIn("'qualification': 'PENDING'", WORKFLOW)
        self.assertIn("'storeUpload': 'NOT_UPLOADED'", WORKFLOW)
        self.assertNotIn('LOCAL_QUALIFIED', WORKFLOW)

    def test_workflow_uses_flutter_drive_as_the_only_capture_build_path(self):
        self.assertIn('- name: Resolve Flutter dependencies', WORKFLOW)
        self.assertIn('flutter pub get', WORKFLOW)
        self.assertNotIn('flutter build ios --simulator', WORKFLOW)
        self.assertNotIn('simctl install', WORKFLOW)
        self.assertIn("'buildProvenance': 'flutter-drive-canonical'", WORKFLOW)

    def test_created_simulator_records_its_selected_runtime(self):
        self.assertIn('simctl create "PlanFlow-$slot-${GITHUB_RUN_ID}"', WORKFLOW)
        self.assertIn('test "$resolved_runtime" = "$runtime_id"', WORKFLOW)
        self.assertIn('runtimeIdentifier:$runtime', WORKFLOW)

    def test_manifest_records_pending_per_asset_review_and_locators(self):
        for token in (
            "'sourceLocator': shot['route']",
            "'finalLocator': path.name",
            "'piiReview': 'PENDING'",
            "'visualReview': 'PENDING'",
            "'captureDeviceModel': device['model']",
            "'captureDeviceUdid': device['udid']",
            "'captureRuntimeIdentifier': device['runtimeIdentifier']",
            "'captureOs': device['runtimeName']",
            "'captureOsVersion': device['runtimeVersion']",
        ):
            self.assertIn(token, WORKFLOW)

    def test_home_fixture_injection_is_offline_and_location_safe(self):
        home = (ROOT / 'lib/screens/home/home_screen.dart').read_text(encoding='utf-8')
        fixture = (ROOT / 'integration_test/store_screenshot_capture_test.dart').read_text(encoding='utf-8')
        self.assertIn('!AppEnv.isSupabaseReady && widget.eventRepository == null', home)
        self.assertIn('locationLat: 37.3947', fixture)
        self.assertIn('locationLng: 127.1112', fixture)
        # banned-ok: This assertion protects deterministic Store screenshot pixels.
        self.assertIn('nowProvider: () => DateTime(2026, 9, 21, 9)', fixture)

    def test_validator_accepts_exact_slot_mapping(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp) / 'out'
            out.mkdir()
            for index, shot in enumerate(PLAN['shots']):
                slot = shot['deviceSlots'][0]
                device = next(d for d in PLAN['devices'] if d['slot'] == slot)
                png = _valid_png(device['width'], device['height'], index + 1)
                (out / f"{shot['screenshotId']}-{slot}.png").write_bytes(png)
            result = subprocess.run(
                ['python', 'scripts/ios/validate_store_screenshots.py',
                 'config/store/capture-plan.json', str(out)],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_validator_rejects_truncated_png_even_with_valid_header(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp) / 'out'
            out.mkdir()
            for index, shot in enumerate(PLAN['shots']):
                slot = shot['deviceSlots'][0]
                device = next(d for d in PLAN['devices'] if d['slot'] == slot)
                png = _valid_png(device['width'], device['height'], index + 1)
                if index == 0:
                    png = png[:-7]
                (out / f"{shot['screenshotId']}-{slot}.png").write_bytes(png)
            result = subprocess.run(
                ['python', 'scripts/ios/validate_store_screenshots.py',
                 'config/store/capture-plan.json', str(out)],
                capture_output=True, text=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('SCREENSHOT_VALIDATION_FAIL', result.stderr)

    def test_validator_rejects_cross_device_cartesian_artifact(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp) / 'out'
            out.mkdir()
            # A phone-only shot incorrectly emitted for IPAD must fail even
            # though the dimensions themselves can be made to look valid.
            shot = PLAN['shots'][0]
            device = next(d for d in PLAN['devices'] if d['slot'] == 'IPAD')
            png = _valid_png(device['width'], device['height'], 211)
            (out / f"{shot['screenshotId']}-IPAD.png").write_bytes(png)
            result = subprocess.run(
                ['python', 'scripts/ios/validate_store_screenshots.py',
                 'config/store/capture-plan.json', str(out)],
                capture_output=True, text=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
