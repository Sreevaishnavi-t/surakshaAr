# SurakshaAR — continuation prompt

You are picking up an in-progress project cold. Read this whole brief before touching anything.

## The project

**SurakshaAR** — an offline AR vocational safety-training and certification platform for
Jharkhand's mining / steel / mica sector, built for Smart India Hackathon 2026.
Flutter 3.44 / Dart 3.12, Android only, `minSdk 29`, `applicationId org.suraksha.surakshaar`.

**Hard constraint, set by the project owner: it must work fully offline.** No cloud
backend, no analytics, no worker data leaving the handset. The `INTERNET` permission in
`app/android/app/src/main/AndroidManifest.xml` is deliberate and commented — Android
classifies a LAN socket under it, and the only networking is optional record sync to a
supervisor's laptop over a shared hotspot. Do not add anything that calls the public internet.

English is the primary/source language. Hindi and Santali (Ol Chiki) are translations that
have not been done yet. Do not treat English strings as placeholders.

## Repo

`C:\Users\srira\My Folder\SIH` — branch `main`, tree clean, all work committed.

```
app/              the Flutter application (this is where ~all the code is)
docs/             deck sources + a STALE handoff doc (see Traps below)
dashboard/  server/  packages/cert-core/     empty by the owner's explicit choice
keys/  tools/
```

## Verification baseline — must hold before and after any change

```bash
cd app
flutter test        # 189 tests, all passing
dart analyze lib    # exactly 7 issues, all pre-existing info-level lints
dart analyze test   # No issues found!
```

The 7 lints in `lib` are the accepted baseline, not a to-do list. If your change makes it 8,
that is a regression you introduced. Never leave a `TODO(human)` in the tree.

## The AR engine — the part most likely to mislead you

There is **no ARCore**. Tracking is **3-DoF, rotation only**, from
`TYPE_GAME_ROTATION_VECTOR` (gyro + accelerometer, magnetometer-free on purpose — steel
plants and underground galleries wreck magnetometers), with a Madgwick AHRS IMU-only
fallback. **Walking genuinely cannot be tracked.** Content following the worker when they
walk is correct behaviour, not a bug. Only rotation is expected to hold.

Scale comes from a gravity-aligned ground plane. Gravity supplies 3 of the 4 plane
parameters for free, so **camera height is the single remaining unknown and therefore
multiplies every real-world measurement the engine makes** — door widths, fire placement,
wall distance. If measurements are wrong by a consistent *ratio*, suspect camera height
before suspecting the detector.

Door detection is geometric, not ML: `app/lib/ar/environment/`.

One non-obvious invariant, discovered by measurement and now pinned by a test — **rows, not
columns, carry measurement accuracy.** A door's width is measured between the two
floor-contact points found by tracing *up* a grid column; its height is a ray through the
topmost row the jamb reached. So row height is depth quantisation. The grid is
`32 columns × 64 rows` (`SceneScanner.gridColumns` / `gridRows`). Doubling columns changes
nothing and doubles cost. Do not "optimise" this back to square without reading the comment
there first.

Also: `DoorDetector._findJambs` indexes `floor.columns[x]` with the same `x` it uses for the
luma grid, and `FloorDetector.detect` emits exactly one `ColumnBoundary` per grid column.
**The floor scan and the edge pass must use the same column count** or jambs silently pair
against the wrong floor boundaries.

## What was just finished (most recent first)

| Commit | What |
|---|---|
| `1d3d3ae` | Deck claims cut back to what the repo can actually back up |
| `6815105` | Detector overlay — a debug instrument behind a "Detector" chip in the scan phase |
| `c1b1139` | Analysis grid 32×24 → 32×64, plus a camera-height/measured-metres coupling test |
| `bd4f043` | Camera height derived from the worker's stature and phone hold (the slider used to be dead — it returned a constant while claiming to measure) |

A release APK was built and verified: `app/build/app/outputs/flutter-apk/`, per-ABI split,
arm64-v8a is 41.5 MB. Signed with the **Android debug key** — fine for sideloading a demo,
must not ship.

## What is left

### 1. On-device checks — BLOCKED, needs the owner's Android handset

The owner has stated the phone is not available; all of this is deferred and **must not be
guessed at or reported as done**. When a device appears, do these in order:

- **World-lock first — it decides whether there is a bug at all.** Open a drill, read
  `hasPose` / `sampleCount` on the diagnostics screen. Turn in place: content must hold its
  bearing. Walk sideways: content *will* follow, and that is correct 3-DoF behaviour. If
  turning alone shifts content, rotation tracking is broken — suspects are the EventChannel
  subscription lifecycle and `DevicePose.fromSensorQuaternion`'s w-first reordering.
- **Floor height, in airplane mode.** Set real stature and hold on the scan gate; the fire's
  base must sit *on* the tunnel floor. Tuning knobs if it reads consistently low or high:
  `_eyeHeightRatio`, `_eyeLevelDropMetres`, `_chestLevelDropMetres` in
  `app/lib/ar/environment/camera_height.dart`.
- **Door thresholds, with the Detector overlay on.** A real single door should label near
  0.9 × 2.05 m. Jambs found but no candidate ⇒ `maxWidthMetres = 1.6` or
  `minHeightMetres = 1.5` is rejecting it. Nothing found at all ⇒ `minEdgeStrength = 14.0`
  is too high for that room's contrast. All in `app/lib/ar/environment/door_detector.dart`.
- **Known untestable-at-desk risk:** `FloorDetector.seedRows = 2` and
  `minConfidenceRows = 3` are counted in grid *rows*, and the grid just went 24 → 64 rows,
  so the seed strip is now about a third of the image fraction it was. Synthetic scenes
  cannot detect this, because a rendered wall is a hard high-contrast step. **On a real
  floor, watch for rooms reading as roughly 1 m deep** — that is the trace tripping early,
  and scaling those two constants proportionally (2 → 5, 3 → 8) is the fix.

### 2. Desk-side work that is genuinely available

- **`docs/HANDOFF.md` is stale and actively misleading.** It says 100 tests and
  "flutter analyze must stay clean"; reality is 189 tests and 7 accepted info lints. It also
  points at a machine-local plan file you will not have. Worth rewriting against this brief.
- **APK size.** `app/android/app/build.gradle.kts` has `isMinifyEnabled = false` and
  `isShrinkResources = false`, disabled while a device-specific crash was being isolated.
  R8 typically takes 30–40% off the ~9 MB of `classes*.dex`. Re-enabling needs verified keep
  rules — CameraX reaches classes reflectively, which produces release-only failures that
  never appear in debug. **Do not re-enable without a device to test the release build on.**
- **Unused permissions from a plugin.** `camera_android_camerax` injects `RECORD_AUDIO`
  (and `WRITE_EXTERNAL_STORAGE`, which implies `READ_EXTERNAL_STORAGE`) for video recording
  the app never does. A judge reading the permission list sees a safety-training app asking
  for the microphone. Removable with `tools:node="remove"` in the app manifest. Verify after
  with `aapt2 dump badging` on the rebuilt APK.
- **Deck.** Sources in `docs/deck/` (`content.py`, `build.py`, `render.ps1`, `template.pptx`,
  `README.md`). Build with `python build.py` then `./render.ps1` from that directory — note
  `python`, not `python3`, on this machine. Two fields only the owner can supply still render
  as guillemets on slide 1: Problem Statement ID and Team ID. Theme is set to
  "Smart Education", assumed rather than confirmed. **Ask; do not invent these.**

## Out of scope — by the owner's explicit decision

`dashboard/`, `server/`, `packages/cert-core/` and the Hindi/Santali ARB files are empty on
purpose. They are real gaps and the deck now says so honestly. **Do not start building them**
unless asked.

## Traps

- Do not trust `docs/HANDOFF.md` numbers (see above).
- `OrganisationKey` is a dev placeholder — `dev-root-2026a`, `isDevelopmentRoot: true`.
  **Must not ship to production.**
- `.gitignore` must keep excluding `keys/`, `*.key`, `*.pem` (except `**/*.pub.pem`),
  `*.sqlite`. Never commit a private key.
- `python3` does not resolve on this Windows machine; use `python`.
- Diagnostics are never transmitted anywhere.
- Git commit attribution line in use: `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`

## How the owner works

Small, self-contained commits with prose subject lines that say what changed for the user
(see `git log`). Code comments explain *why*, not *what*, and they are expected — match the
surrounding density. Tests are expected to pin non-obvious invariants with a `reason:` that
says what breaking it would mean. If you find the agreed approach is wrong once you measure
it, say so explicitly rather than quietly doing something else.

## Start here

```bash
cd "C:/Users/srira/My Folder/SIH/app" && flutter test && dart analyze lib
```

Confirm 189 and 7. Then say what you intend to do and why before changing anything — several
of the items above are blocked on hardware, and picking one that is not is the first real
decision.
