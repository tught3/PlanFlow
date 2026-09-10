# iPad 13-inch Screenshots – Source & Transformation

## Source

**Original assets:**
- File: `스크린샷 아이폰/가로/PlanFlow_tablet_landscape_1.png`
- File: `스크린샷 아이폰/가로/PlanFlow_tablet_landscape_2.png`
- Commit: `041df782` ("Add PlanFlow store listing assets")

These were original mockup screenshots rendered as 2064×2752 pixel PNG images.

## Content Audit (Android Chrome Detection)

**Finding:** Original mockup contained Samsung Android tablet chrome (system UI) artifacts:
- **Top bar** (y ~436–478): Samsung status bar with system icons
- **Bottom bar** (y ~2048–2145): Android navigation buttons + third-party app taskbar
- **Screen content region** (x ~696–1981, y ~478–2048): Actual app content

**Detection method:** Visual inspection of pixel data; confirmed no Apple device UI present.

## Applied Transformation

**Approach:** Remove Android chrome while preserving app content and canvas integrity.

**Specific operations:**
- Top chrome (y 436–478): Replaced with dominant background color from adjacent pixels
- Bottom chrome (y 2048–2145): Replaced with dominant background color from adjacent pixels
- Canvas size: **Preserved** (2064×2752)
- Content area: **Unchanged**
- Affine transforms: None (no crop, resize, or rotation)

**Geometry reference:** Precise y-ranges derived from `scratchpad/geometry.json` during processing.

## Apple App Store Compliance

**Spec reference:** [App Store Connect – Screenshot Specifications](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications)

**Applicable requirements:**
- **Device:** 13-inch iPad
- **Orientation:** Portrait (canvas taller than wide)
  - Portrait: 2064w × 2752h pixels ✓
  - Landscape: 2752w × 2064h pixels (not used)
- **Format:** PNG or JPEG (no alpha channel; images are opaque) ✓
- **Minimum:** 1 screenshot per device
- **Maximum:** 10 screenshots per device

## Filenames

**Note on orientation terminology:**
- Filename contains "landscape" because it depicts a **tablet held landscape** (user perspective)
- Canvas dimensions (2064w × 2752h) match Apple's **portrait slot** (taller than wide)
- This is consistent with tablet apps captured in landscape orientation but stored in portrait-format images

**Final filenames:**
- `01_ipad13_landscape_calendar.png`
- `02_ipad13_landscape_group.png`

## Known Limitations

- **Device bezel:** Mockup tablet bezel retained (no brand markings detected; considered acceptable)
- **Third-party interactions:** Demo data within app UI may reference external services; not sanitized
- **Alpha channel:** Removed (all pixels fully opaque per App Store requirements)

## Relation to Existing Documentation

**`docs/ios/screenshot-inventory.md`** previously listed these two files as:
- ✓ Dimensions: "exactly match 13-inch iPad portrait (2064×2752)"
- ✗ Content: Still contained Android chrome at submission time

This document captures the transformation applied to make them **content-compliant** while dimensions remained unchanged. The inventory file itself was not modified.

## Out of Scope

The following items are **not** addressed in this work:

- App Store metadata (privacy policy URL, age rating, category, content permissions)
- 6.9-inch iPhone screenshots (1260×2736) — separate deliverable
- Other device families (iPad Air, iPad mini, etc.)
