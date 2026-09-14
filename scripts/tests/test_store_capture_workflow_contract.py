"""Contract tests for the CI-only iOS screenshot capture pipeline."""
import json
import re
import struct
import subprocess
import tempfile
import unittest
import zlib
from pathlib import Path

from scripts.ios.validate_store_screenshots import png_info

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


def _rgba16_png(alpha):
    """Return a one-pixel RGBA PNG using 16-bit samples."""
    pixels = b'\x00' + struct.pack('>HHHH', 0x1234, 0x5678, 0x9ABC, alpha)
    ihdr = struct.pack('>IIBBBBB', 1, 1, 16, 6, 0, 0, 0)
    return (
        b'\x89PNG\r\n\x1a\n'
        + _png_chunk(b'IHDR', ihdr)
        + _png_chunk(b'IDAT', zlib.compress(pixels, level=9))
        + _png_chunk(b'IEND', b'')
    )


def _filtered_png(depth, color_type, filter_type, alpha=None):
    """Build a small PNG whose rows use the requested PNG filter."""
    channels = 3 if color_type == 2 else 4
    sample_bytes = depth // 8
    bytes_per_pixel = channels * sample_bytes
    row_bytes = 3 * bytes_per_pixel
    rows = []
    for row_number in range(2):
        row = bytearray(row_bytes)
        for index in range(0, row_bytes, sample_bytes):
            value = (17 + row_number * 29 + index * 3) & 0xFF
            row[index:index + sample_bytes] = bytes(
                [value] * sample_bytes
            )
        if color_type == 6:
            alpha_value = (1 << depth) - 1 if alpha is None else alpha
            alpha_bytes = alpha_value.to_bytes(sample_bytes, 'big')
            row[3 * sample_bytes:4 * sample_bytes] = alpha_bytes
            row[7 * sample_bytes:8 * sample_bytes] = alpha_bytes
            row[11 * sample_bytes:12 * sample_bytes] = alpha_bytes
        rows.append(row)

    encoded = bytearray()
    prior = bytearray(row_bytes)
    for row in rows:
        filtered = bytearray(row_bytes)
        for index, value in enumerate(row):
            left = row[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            above = prior[index]
            upper_left = prior[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            else:
                predictor = _paeth(left, above, upper_left)
            filtered[index] = (value - predictor) & 0xFF
        encoded.extend((filter_type,))
        encoded.extend(filtered)
        prior = row
    ihdr = struct.pack('>IIBBBBB', 3, 2, depth, color_type, 0, 0, 0)
    return (
        b'\x89PNG\r\n\x1a\n'
        + _png_chunk(b'IHDR', ihdr)
        + _png_chunk(b'IDAT', zlib.compress(bytes(encoded), level=9))
        + _png_chunk(b'IEND', b'')
    )


def _paeth(left, above, upper_left):
    estimate = left + above - upper_left
    distances = (
        (abs(estimate - left), left),
        (abs(estimate - above), above),
        (abs(estimate - upper_left), upper_left),
    )
    return min(distances)[1]


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
        self.assertIn('nowProvider: () => DateTime.utc(2026, 9, 21, 1)', fixture)
        self.assertIn('_FakeSmartPreparationAlarmService', fixture)
        self.assertIn('headerSummaryOverride: const HomeHeaderSummary', fixture)
        self.assertIn('debugShowCheckedModeBanner: false', fixture)

    def test_confirm_fixture_uses_fixed_local_now(self):
        fixture = (ROOT / 'integration_test/store_screenshot_capture_test.dart').read_text(encoding='utf-8')
        self.assertIn("'start_at': '2026-09-21T01:00:00.000Z'", fixture)
        self.assertIn("'end_at': '2026-09-21T02:00:00.000Z'", fixture)

    def test_personal_agenda_cards_have_stable_event_keys(self):
        calendar = (ROOT / 'lib/screens/calendar/calendar_widgets.dart').read_text(encoding='utf-8')
        fixture = (ROOT / 'integration_test/store_screenshot_capture_test.dart').read_text(encoding='utf-8')
        self.assertIn("key: ValueKey('calendar-personal-event-${event.id}')", calendar)
        self.assertIn('find.byKey(', fixture)
        self.assertIn("const ValueKey('calendar-personal-event-store-fixture-event')", fixture)
        self.assertIn("parsedSchedule: <String, dynamic>{", fixture)
        self.assertIn("'parse_attempt_id': 'store-fixture-parse-attempt'", fixture)
        self.assertIn("'start_at': '2026-09-21T01:00:00.000Z'", fixture)
        self.assertIn("'end_at': '2026-09-21T02:00:00.000Z'", fixture)
        self.assertIn("'location_lat': 37.3947", fixture)
        self.assertIn("'location_lng': 127.1112", fixture)

    def test_ipad_calendar_readiness_uses_personal_event_key(self):
        fixture = (ROOT / 'integration_test/store_screenshot_capture_test.dart').read_text(encoding='utf-8')
        ipad_case = re.search(
            r"case 'ipad13-calendar':\s*(.*?)\s*break;", fixture, re.S,
        )
        self.assertIsNotNone(ipad_case)
        self.assertIn("find.byKey(", ipad_case.group(1))
        self.assertIn("calendar-personal-event-store-fixture-event", ipad_case.group(1))
        self.assertIn("findsOneWidget", ipad_case.group(1))

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

    def test_validator_accepts_opaque_16_bit_rgba_png(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'opaque.png'
            path.write_bytes(_rgba16_png(0xFFFF))
            self.assertEqual(png_info(path), (1, 1, True))

    def test_validator_rejects_partial_alpha_16_bit_rgba_png(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'partial-alpha.png'
            path.write_bytes(_rgba16_png(0xFFFE))
            self.assertEqual(png_info(path), (1, 1, False))

    def test_png_info_decodes_all_supported_depth_types_and_filters(self):
        for depth in (8, 16):
            for color_type in (2, 6):
                for filter_type in range(5):
                    with self.subTest(depth=depth, color_type=color_type, filter=filter_type):
                        with tempfile.TemporaryDirectory() as temp:
                            path = Path(temp) / 'matrix.png'
                            path.write_bytes(_filtered_png(depth, color_type, filter_type))
                            self.assertEqual(png_info(path), (3, 2, True))

    def test_png_info_rejects_nonopaque_rgba_at_both_supported_depths(self):
        for depth, alpha in ((8, 254), (16, 0xFFFE)):
            with self.subTest(depth=depth):
                with tempfile.TemporaryDirectory() as temp:
                    path = Path(temp) / 'partial-alpha.png'
                    path.write_bytes(_filtered_png(depth, 6, 4, alpha))
                    self.assertEqual(png_info(path), (3, 2, False))

    def test_png_info_rejects_invalid_filter(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'invalid-filter.png'
            png = bytearray(_filtered_png(8, 2, 0))
            idat = png.index(b'IDAT')
            payload_start = idat + 4
            payload_length = struct.unpack('>I', png[idat - 4:idat])[0]
            payload = zlib.decompress(png[payload_start:payload_start + payload_length])
            replacement = zlib.compress(bytes((5,)) + payload[1:], level=9)
            rebuilt = png[:idat - 4] + _png_chunk(b'IDAT', replacement)
            rebuilt += _png_chunk(b'IEND', b'')
            path.write_bytes(rebuilt)
            with self.assertRaisesRegex(ValueError, 'invalid PNG filter'):
                png_info(path)

    def test_png_info_rejects_crc_mismatch(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'bad-crc.png'
            png = bytearray(_filtered_png(8, 2, 0))
            png[-1] ^= 1
            path.write_bytes(png)
            with self.assertRaisesRegex(ValueError, 'CRC mismatch'):
                png_info(path)

    def test_png_info_rejects_missing_or_truncated_iend(self):
        for suffix in ('missing', 'truncated'):
            with self.subTest(suffix=suffix):
                with tempfile.TemporaryDirectory() as temp:
                    path = Path(temp) / f'{suffix}.png'
                    png = _filtered_png(8, 2, 0)
                    path.write_bytes(png[:-12] if suffix == 'missing' else png[:-1])
                    with self.assertRaisesRegex(ValueError, 'missing IEND|truncated PNG chunk'):
                        png_info(path)


if __name__ == '__main__':
    unittest.main()
