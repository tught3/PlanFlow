# iPad 13-inch Screenshots – Source & Transformation

## STATUS: REJECTED (2026-09-11 재검토)

Both files in this directory are marked `status: "REJECTED"` in
`config/store/screenshot-lineage.json` (`ipad13-01-calendar`,
`ipad13-02-group`) and must **not** be submitted to App Store Connect as-is.
Reasons (all directly PIL-measured on 2026-09-11, not assumed):

1. A **97-row solid-black residual band** remains at y2048–2144
   (screen-interior x696–1980) in both files. The chrome-removal step that
   was supposed to replace this band with the surrounding background color
   did not do so for the bottom band (it did succeed for the top band, see
   below).
2. The true source is a **non-uniform (distorted) resize**, not a
   dimension-preserving chrome-removal as previously documented. See
   "Corrected Lineage" below.
3. `ipad13-01-calendar` additionally carries unreviewed PII (real business
   names) inherited from its source image; see `piiFindings` in the
   lineage entry.

Re-capture via `config/store/capture-plan.json` (`ipad13-1-calendar-month`,
`ipad13-2-group-dashboard` shots, IPAD/13 device) is required before this slot can be
resubmitted.

## Corrected Lineage (measured 2026-09-11)

The previous version of this document claimed the ultimate source was
`스크린샷 아이폰/가로/PlanFlow_tablet_landscape_{1,2}.png` at 2064×2752 with
"no crop/resize" applied. Direct measurement traces the lineage one step
further back and corrects that claim:

- **True origin:** `docs/screenshots/store_final_v3/tablet_1200x1920/PlanFlow_tablet_landscape_{1,2}.png`,
  measured **2560×1600** (landscape, 16:10).
- **Non-uniform resize:** to a 2064×2752 (portrait) canvas —
  `scale_x = 2064/2560 = 0.80625`, `scale_y = 2752/1600 = 1.72`. The content
  is stretched, not letterboxed or uniformly scaled. This was verified by
  opening all three files (the 2560×1600 origin, the 2064×2752 intermediate
  `스크린샷 아이폰/가로/...`, and the final `app-store/ipad-13/...` file) and
  confirming the same UI composition appears in all three at the measured
  ratio.
- The intermediate `스크린샷 아이폰/가로/PlanFlow_tablet_landscape_{1,2}.png`
  files are themselves already 2064×2752 (same as the final canvas) — they
  are a distinct byte-for-byte asset from the final `ipad-13` files (sha256
  differs), confirming the resize happened *before* that intermediate step,
  not between it and the final file.
- Commit `18d82901` ("chore(screenshots): add iPad 13" store screenshots
  with Android chrome removed") is the commit that added the two files in
  this directory to the repository; it does not establish source-code
  equivalence at that point in time.

## Content Audit (Android Chrome Detection) — still accurate

**Finding:** The pre-resize mockup contained Samsung Android tablet chrome
(system UI) artifacts:
- **Top bar** (y ~436–478): Samsung status bar with system icons
- **Bottom bar** (y ~2048–2145): Android navigation buttons + third-party
  app taskbar
- **Screen content region** (x ~696–1981, y ~478–2048): Actual app content

**Detection method:** Direct pixel inspection with PIL (`Image.load()` +
per-pixel sampling), 2026-09-11; confirmed no Apple device UI present.

## Applied Transformation — corrected

**Top chrome band (y 436–478):** PIL-verified as **successfully** replaced
with a uniform background color `(238, 245, 251)` matching the surrounding
background. This part of the original claim was accurate.

**Bottom chrome band (y 2048–2144, x 696–1980):** PIL-verified as **NOT**
successfully replaced. The 97-row band is solid `(0, 0, 0)` black in both
files, not the surrounding background color. The original claim ("Replaced
with dominant background color from adjacent pixels") was false for this
band.

**Canvas size:** 2064×2752 (matches Apple's 13" portrait spec dimension),
but this is the *output* of a non-uniform resize from a 2560×1600 source,
not a size-preserving transform as previously claimed. "Affine transforms:
None (no crop, resize, or rotation)" was incorrect — a non-uniform resize
did occur upstream.

## Apple App Store Compliance

**Spec reference:** [App Store Connect – Screenshot Specifications](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications)

**Applicable requirements:**
- **Device:** 13-inch iPad
- **Orientation:** Portrait (canvas taller than wide)
  - Portrait: 2064w × 2752h pixels — dimensions match the spec, but content
    is REJECTED for the reasons above (residual band, PII, distortion)
  - Landscape: 2752w × 2064h pixels (not used)
- **Format:** PNG (no alpha channel; images are opaque)
- **Minimum:** 1 screenshot per device
- **Maximum:** 10 screenshots per device

## Filenames

**Note on orientation terminology:**
- Filename contains "landscape" because it depicts a **tablet held
  landscape** (user perspective)
- Canvas dimensions (2064w × 2752h) match Apple's **portrait slot** (taller
  than wide)
- This is consistent with tablet apps captured in landscape orientation but
  stored in portrait-format images

**Final filenames (REJECTED, pending re-capture):**
- `01_ipad13_landscape_calendar.png`
- `02_ipad13_landscape_group.png`

## Known Limitations

- **Residual chrome:** Bottom chrome band was not actually removed (see
  above) — this is the primary blocker, not a minor cosmetic issue.
- **Distortion:** Non-uniform resize (0.80625x horizontal, 1.72x vertical)
  from the 2560×1600 source may visibly stretch UI elements; not
  individually assessed for visual acceptability.
- **PII:** `ipad13-01-calendar` exposes real business names (see
  `piiFindings` in the lineage entry); `ipad13-02-group` was reviewed and no
  PII was found, but the review was not an exhaustive scan.
- **Device bezel:** Mockup tablet bezel retained (no brand markings
  detected; considered acceptable).
- **Alpha channel:** None present (all pixels fully opaque per App Store
  requirements).

## Relation to Existing Documentation

**`docs/ios/screenshot-inventory.md`** previously listed these two files as:
- Dimensions: "exactly match 13-inch iPad portrait (2064×2752)" — still true
  pixel-wise, but this document's prior claim about *how* that canvas was
  produced (no crop/resize) was wrong; see "Corrected Lineage" above.
- Content: contained Android chrome at submission time — still true for the
  bottom band; the top band chrome removal succeeded.

The inventory file itself was not modified as part of this correction.

## Out of Scope

The following items are **not** addressed in this work:

- App Store metadata (privacy policy URL, age rating, category, content
  permissions)
- 6.9-inch iPhone screenshots — separate deliverable. `IPHONE_69_ASSET_MISSING`
  is a manually-declared blocker in `config/store/store-profile.json`
  (`blockers[]`, platform `ios`), not something derived from
  `screenshot-lineage.json`; that document separately lists
  `{slot: IPHONE, displayClass: 6.9}` in its own `requiredSlots` with zero
  usable entries as of 2026-09-11, which independently produces a
  `SET_BELOW_MIN` finding. The three Apple-approved 6.9" dimensions are
  1260×2736, 1290×2796, and 1320×2868 (portrait; existing
  `스크린샷 아이폰/세로` assets are 1242×2688, the 6.5" spec, not one of these).
- Other device families (iPad Air, iPad mini, etc.)
- Actually re-capturing replacement assets (tracked separately via
  `config/store/capture-plan.json`)
