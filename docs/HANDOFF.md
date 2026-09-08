# SurakshaAR — handoff

Written for an agent picking this up cold. Repo: https://github.com/sriram4n/surakshaar (public, `main`).

## What this is

An offline, Android-only AR vocational safety training platform for Jharkhand's
mining/steel/mica sector — see [README context in git log](../) for the full
problem statement. Short version: young, often first-time industrial workers,
sub-20%-retention classroom training, VR headsets unaffordable, no digital
certification that proves comprehension rather than attendance. The product:
phone-camera AR safety drills, an adaptive quiz, a cryptographically verifiable
QR certificate, and a local compliance dashboard — all functioning with the
radio off.

The full design reasoning (why no ARCore, why English is primary with Hindi/
Santali as reviewed translations, why CBOR/Ed25519/base45 for the certificate,
sync model) lives in the original plan at
`C:\Users\srira\.claude\plans\build-a-ar-based-vocational-sparkling-spring.md`
on the machine this was built on — read it if you want the *why* behind
decisions below, not just the *what*.

## Build/test loop

```bash
cd app
flutter test              # 100 tests, must stay green
flutter analyze           # must stay clean
flutter build apk --release
```

Toolchain on the dev machine: Flutter 3.44.8, Dart 3.12.2, Android SDK 36,
NDK 30, JDK 25 via Android Studio's bundled JBR. `flutter doctor` clean.
`minSdk 29`, `targetSdk 36`, `applicationId org.suraksha.surakshaar`.

## What's actually built (vertical slice, Phases 1–2 of the original plan)

**`app/`** — the Flutter app. This is where essentially all the work is.

- `lib/ar/` — the whole AR engine, no ARCore, no 3D assets:
  - `pose/` — `PoseService` streams device orientation from a Kotlin platform
    channel (`android/app/.../PoseChannel.kt`), preferring
    `TYPE_GAME_ROTATION_VECTOR` (gyro+accel, **no magnetometer** — deliberate,
    magnetic heading is useless underground/near machinery). Falls back to a
    Dart-side `MadgwickAhrs` filter (`pose/madgwick.dart`, 8 tests) fed by a
    raw IMU channel when no fused sensor exists. `DevicePose.upright()` is the
    default pose before any sensor sample arrives — **not** `identity`, which
    points the camera at the floor and was the cause of an early "nothing
    renders" bug (see Known issues).
  - `scene/` — `ArCamera` does pinhole projection (world→device→screen),
    `ArScenePainter` culls/sorts/draws. Nodes are pure vector `CustomPainter`
    art (`nodes/basic_nodes.dart`, `fx/fire_fx.dart`, `fx/gas_fx.dart`) — no
    glTF/bitmap assets, keeps the APK small and sidesteps asset licensing.
    Icon glyphs are cached as `ui.Paragraph`s (`basic_nodes.dart`) rather than
    laid out every frame — was costing ~500 layouts/sec.
  - `anchor/` — QR-marker planar anchoring via `google_mlkit_barcode_scanning`
    (fully on-device). Two-tier: marker-anchored when a printed marker is
    visible, gyro-anchored (calibrate-and-lock) otherwise.
  - `camera/ar_camera_view.dart` — wraps `camera` package.
    `ImageFormatGroup.nv21` is now **opt-in** (`forImageStream: true`) — only
    the certificate scanner needs it; forcing it on the drill camera was
    standing up an unused CameraX analysis pipeline (see Known issues).

- `lib/modules/` — five safety domains, each `m{1..5}_*`: fire, gas/confined
  space, machinery/LOTO, strata/working-at-height, electrical/first-aid. M1
  (fire) and M2 (gas) are built to full 3-act depth per the plan; M3–M5 exist
  as scaffolded single-act modules. `modules/engine/` has the step-machine /
  scenario base classes shared across all of them.

- `lib/assessment/` — adaptive quiz engine (wrong answer → easier same-concept
  item, mandatory-item gating for life-critical questions).

- `lib/certificate/` — CBOR payload → zlib → Ed25519 sign → base45 encode →
  `SJH1:` prefix QR. Two-tier trust: provisional (device key, signed on first
  run) vs verified (org-countersigned on sync). Org **public** key is compiled
  into the app so any fresh install verifies offline
  (`data/device_identity.dart` has `OrganisationKey`, currently
  `dev-root-2026a` — **this is a dev key, not production-grade**, see below).

- `lib/core/`:
  - `diagnostics.dart` — on-device crash diagnostics. Breadcrumbs are written
    **synchronously** (`writeAsStringSync` with `flush: true`) specifically so
    the trail survives a native process death with no lag — this was itself a
    bug fix (see Known issues / recent debugging).
  - `exit_reasons.dart` + Kotlin `ExitReasonChannel.kt` — reads Android's
    `ActivityManager.getHistoricalProcessExitReasons()` (API 30+): tells you
    whether a previous process death was `LOW_MEMORY`, `CRASH_NATIVE`, `ANR`,
    or user-initiated, plus PSS/RSS at death and a best-effort tombstone
    (printable strings extracted from the protobuf, no protobuf runtime
    linked). Surfaced in the in-app Diagnostics screen
    (`features/diagnostics/diagnostics_screen.dart`).
  - `l10n/` — only `arb/app_en.arb` exists. **Hindi and Santali translation
    files do not exist yet.** English is the primary/source language per
    explicit user instruction (overriding an earlier assumption that Santali
    should be primary — see plan file for the reasoning trail).

- `lib/data/` — sqflite repositories. Numeric reads from SQLite go through
  `_readNumber()` helpers that don't assume `int` vs `double` — SQLite is
  dynamically typed and a naive `as double?` cast on an integral score value
  threw and caused an infinite-loading bug (see Known issues).

- `lib/features/` — screens: enrolment, module list, AR session, assessment,
  certificate display, QR verify scanner, diagnostics.

**Empty / not started**: `dashboard/`, `server/`, `packages/cert-core/`,
`tools/` (only has `keygen.mjs`), `docs/` (only this file now). That's Phase 3
(web compliance dashboard + LAN sync server) and Phase 4 (Hindi/Santali
localisation content, marker sheet PDF, TTS narration) from the original plan
— **entirely unbuilt**. The plan's sync design: Fastify + better-sqlite3 server
on a supervisor's laptop, mDNS discovery with manual-IP fallback, signed
`.json` bundle export/import as the no-network fallback. None of that exists
as code yet.

## Known issues / recent debugging (read this before touching AR code)

There's an **unresolved native crash** on a real device when starting an AR
drill (works fine on one tablet, crashes on a different phone). This consumed
most of the last several sessions. Chronology of what was tried, fixed, and
ruled out — useful so you don't repeat dead ends:

1. **Fixed, real bug**: pose defaulted to `DevicePose.identity` (camera points
   at floor) instead of `DevicePose.upright()`, causing every node to cull —
   "app opens, nothing renders." Fixed, tested (`test/ar/projection_test.dart`
   has explicit regression tests documenting why identity is wrong).
2. **Fixed, real bug**: `MaskFilter.blur` sigmas were written in **canvas
   units** (metres) but the renderer scales canvas by `pixelsPerMetre`
   (hundreds). A 0.75m sigma became a ~450px blur on 46 smoke particles/frame.
   Fixed via `NodeRenderContext.blurUnits()` — sigma now specified in screen
   pixels and capped (`test/ar/blur_scaling_test.dart`).
3. **Fixed, real bug**: infinite spinner on the module screen from the SQLite
   `as double?` cast issue described above.
4. **Fixed, real bug**: `ImageFormatGroup.nv21` was forced on every camera
   controller including the AR drill, which never streams frames — stood up
   an unused native YUV→NV21 ImageAnalysis pipeline on CameraX. Made opt-in.
5. **Investigated and REJECTED (important — don't re-derive this)**: a theory
   that a node projecting near the camera's near-plane produces an enormous
   `canvas.scale` (~4000px/m) and blows up GPU blur allocation. Disproven by
   simulating the actual render-loop cull (which includes a screen-margin
   reject the theory's author initially overlooked) across all headings —
   worst surviving scale in practice is ~200px/m, not ~4000. **This is not
   the bug.**
6. **Still open at last check**: added per-node first-paint breadcrumbs
   (`ar_renderer.dart`, `_traceFirstFrame`) — on the last real-device run,
   `ar.render.first.complete` was reached with a normal-scale node drawn
   cleanly, meaning **Dart-side painting is not where the crash is**. Working
   theory going in: the crash is in GPU rasterization (happens on a separate
   thread after Dart's paint call returns, so Dart breadcrumbs can't see it)
   or is a native crash/OOM unrelated to rendering entirely. This is exactly
   why `exit_reasons.dart`/`ExitReasonChannel.kt` were added — to get
   Android's own `CRASH_NATIVE`/`LOW_MEMORY`/`ANR` classification and PSS/RSS
   at death without needing `adb logcat` on a device with no dev tools nearby.
   **The next step for whoever continues this is to get that exit-reason
   report from the crashing device and read the tombstone.** There's also a
   `_safeMode` toggle on the AR session screen (renders camera only, no scene)
   to bisect camera-layer vs renderer-layer if the exit reason doesn't say.
   A secondary unexplained symptom: `frames.pose.first` breadcrumb never
   fired even seconds into a run on the crashing device — sensor stream may
   be silently dead, possibly the same root cause as the crash.
7. There is one deliberately unfinished piece: `verdictFor()` in
   `diagnostics_screen.dart` is a `TODO(human)` stub (returns `''`) — it's
   meant to turn a raw `ProcessExit` into a plain-English one-liner. Doesn't
   block anything; fill it in or leave it.

**If you're picking this up to keep chasing the crash**: get the app onto the
crashing device, trigger it, reopen the app, go to the in-app Diagnostics
screen, and read the new "Why the app closed last time" section — that's the
`ExitReasonChannel` output and it should finally say definitively
`CRASH_NATIVE` (with tombstone) vs `LOW_MEMORY` vs something else.

## Security/production notes to not forget

- `OrganisationKey` in `data/device_identity.dart` is currently a **hardcoded
  dev root key** (`dev-root-2026a`, `isDevelopmentRoot: true`, surfaced with a
  visible warning banner on the home screen). Do not ship this. Production
  needs a real key ceremony — see the plan file's threat-model notes.
- No secrets are committed. `.gitignore` excludes `keys/`, `*.key`, `*.pem`
  (except `*.pub.pem`), local sqlite DBs. Verified clean before the initial
  push.
- R8/minification is currently **disabled** in the release build
  (unminified APK is ~85MB). Re-enabling it with verified keep rules (for the
  Kotlin platform channels especially — reflection-sensitive) should shrink it
  to somewhere near 25MB, but do this *after* the crash is resolved, since
  disabling R8 was itself a deliberate step to rule out stripping-related
  causes.

## Suggested next steps, roughly in priority order

1. Resolve the native crash (see #6 above — get the exit-reason report).
2. Re-enable R8 once crash-free, verify APK still works, shrink size.
3. Build the dashboard + sync server (`dashboard/`, `server/`,
   `packages/cert-core/` are empty scaffolding waiting for this — Fastify +
   better-sqlite3 + React/Vite per the plan).
4. Hindi translation (`app_hi.arb`) — English strings all exist in
   `app_en.arb` as the source of truth; this is a translation pass, not new
   UI work.
5. Santali (`app_sat.arb`) — needs the "pending native review" badge
   infrastructure the plan describes; do not ship unreviewed Santali safety
   copy as authoritative.
6. Flesh out M3–M5 to the same depth as M1/M2 if time allows; they're
   currently single-act.
7. Marker sheet PDF, TTS narration recording, demo video, README for the repo
   root (currently has none — a first-time visitor gets a bare file tree).

Every commit message in `git log` on this repo is written with the actual
root-cause reasoning for that change — read them in order if you want the
full narrative rather than this summary.
