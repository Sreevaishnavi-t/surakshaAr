# -*- coding: utf-8 -*-
"""Deck content, kept separate from the build so wording can be revised alone."""

FILL_OPEN = "«"   # guillemets mark a value only the team can supply
FILL_CLOSE = "»"


def _fill(what):
    return FILL_OPEN + what + FILL_CLOSE


TITLE_FIELDS = [
    ("Problem Statement ID – ", _fill("from SIH portal")),
    ("Problem Statement Title – ",
     "AR-Based Vocational Training Simulator for Industrial Safety in "
     "Jharkhand’s Mining & Manufacturing Sector"),
    ("Theme – ", "Smart Education"),
    ("PS Category – ", "Software"),
    ("Team ID – ", _fill("from SIH portal")),
    ("Team Name – ", "Technova"),
]

SLIDES = {
    2: {
        "title": "SURAKSHAAR — OFFLINE AR SAFETY TRAINING",
        "left_head": "What it is",
        "left": [
            "An offline AR safety-training and certification platform running on any "
            "Android 10+ phone — no headset, no ARCore, no internet at any point.",
            "The worker sweeps the phone across their workplace; the app finds the floor, "
            "the clear space and real doorways, then builds a mine gallery fitted to that room.",
            "Five DGMS-aligned domains: Fire & Explosion, Gas Leak & Confined Space, "
            "Machinery & Lockout-Tagout, Roof Fall & Working at Height, Electrical & First Aid.",
            "Drills score what the worker does under time pressure — action sequencing, "
            "reaction time, PPE selection — not attendance.",
        ],
        "right_head": "Why it is different",
        "right": [
            "Runs on the low-cost handset a contract worker already carries. ARCore-based AR "
            "needs certified hardware most budget phones do not have.",
            "The certificate is a cryptographically signed QR code any inspector can verify "
            "offline, on a fresh install, with no account and no network.",
            "Audio-first throughout, so a worker who reads slowly or not at all can still "
            "run the drill. English ships today; the string layer is script-agnostic and "
            "Hindi and Santali (Ol Chiki) are the next translation pass.",
            "Genuinely offline end to end — exercised in airplane mode; no worker data "
            "ever leaves the handset.",
            "A working release APK backed by 189 automated tests, not a mock-up.",
        ],
    },
    3: {
        "title": "TECHNICAL APPROACH",
        "left_head": "Platform and stack",
        "left": [
            "Flutter 3.44 / Dart — one Android APK, minSdk 29 (Android 10 and above).",
            "Kotlin platform channel reading TYPE_GAME_ROTATION_VECTOR: gyroscope plus "
            "accelerometer, magnetometer deliberately excluded because magnetic heading is "
            "unusable underground and beside steel-plant motors.",
            "Madgwick AHRS filter in Dart as the fallback for handsets with no fused sensor.",
            "Camera2 lens metadata gives the true field of view, so overlays stay aligned "
            "instead of sliding as the worker turns.",
            "SQLite on the phone, with signed record bundles as the export format. The "
            "supervisor dashboard that consumes them is specified and not yet built; the "
            "bundle is what the phone already produces.",
        ],
        "right_head": "How the AR works",
        "right": [
            "Gravity-referenced pose makes the floor plane known rather than estimated — "
            "only the camera height has to be measured.",
            "Room sensing: each camera frame is reduced to a 32×64 grid and traced upward "
            "from the worker’s feet, using brightness and texture together so a grey wall "
            "above a grey floor is still detected. Tall rather than square on purpose: rows "
            "are what set how precisely a doorway can be measured.",
            "Door detection without machine learning: vertical edge pairs meeting the floor "
            "are accepted only if they measure about 0.9 m by 2 m in real metres. Geometry "
            "does the semantic filtering, so no model weights ship in the APK.",
            "All content is procedural vector art — no 3D assets, no licensing risk, and "
            "a steady frame rate on mid-range hardware.",
            "Certificate: CBOR, zlib, Ed25519 signature and base45 QR, following the approach "
            "India already uses for DIVOC and CoWIN credentials.",
        ],
    },
    4: {
        "title": "FEASIBILITY AND VIABILITY",
        "left_head": "Why it is feasible",
        "left": [
            "The hardware requirement is a phone the workforce already owns — no headset "
            "purchase, no ARCore certification, no data plan.",
            "A release APK builds today, with 189 automated tests covering projection "
            "mathematics, environment detection, adaptive assessment and certificate "
            "cryptography.",
            "Nothing in the design needs a cloud contract or a per-site recurring cost: "
            "records move as signed files, and the planned supervisor dashboard is a laptop "
            "on a local hotspot.",
            "Fits existing statutory practice under the Mines Act 1952 and the Factories Act "
            "1948 rather than asking regulators to adopt something new.",
        ],
        "right_head": "Risks, and how they are handled",
        "right": [
            "Magnetic interference underground — handled by magnetometer-free sensor "
            "fusion, chosen for exactly this reason.",
            "Rotation-only tracking rather than SLAM — drills are designed around looking "
            "around, and the simulated gallery is fitted to the measured room so nothing is "
            "placed inside a real wall.",
            "Santali is a low-resource language — every translated string is badged for "
            "native review with a Hindi fallback before it is shown, so no unverified safety "
            "wording is ever presented as authoritative.",
            "Device fragmentation — an in-app diagnostics screen reads Android’s own "
            "process-exit records, so a fault at a remote site is diagnosable without a laptop.",
            "Falsified training records — every entry is signed by the device key and "
            "counter-signed by the organisation before a certificate counts as verified.",
        ],
    },
    5: {
        "title": "IMPACT AND BENEFITS",
        "left_head": "Impact",
        "left": [
            "Jharkhand’s coal, steel and mica workforce — hundreds of thousands of "
            "workers, many of them young tribal recruits with no prior industrial exposure.",
            "DGMS Dhanbad recorded 48 fatal mine accidents in Jharkhand in 2022–23, a "
            "large share involving workers with under 30 days of orientation.",
            "Classroom training on static manuals retains under 20% after one week; practising "
            "the drill with visible consequences targets exactly that gap.",
            "Signed records carry each worker’s days-since-induction, so the under-30-day "
            "cohort can be surfaced by name and acted on before an accident rather than after.",
        ],
        "right_head": "Benefits",
        "right": [
            "Social — audio-first delivery, with translation into the worker’s own language, "
            "reaching the contract labour that headset programmes exclude entirely.",
            "Economic — effectively no marginal cost per worker trained; avoided accidents "
            "reduce compensation, downtime and lost production.",
            "Regulatory — certification that evidences comprehension rather than "
            "attendance, and that an inspector can verify offline at the pit head.",
            "Environmental — no headset hardware to manufacture, ship, power or dispose of.",
            "Scale — works for the small mines and contractors that could never fund a "
            "simulator room, which is where the orientation gap is widest.",
        ],
    },
    6: {
        "title": "RESEARCH AND REFERENCES",
        "left_head": "Statutory and domain sources",
        "left": [
            "Directorate General of Mines Safety, Dhanbad — annual statistics of mine "
            "accidents and standard notes on causation.",
            "The Mines Act 1952, the Mines Rules 1955 and the Mines Vocational Training Rules "
            "1966 — periodic training and certification obligations.",
            "The Factories Act 1948 — safety training duties for steel and manufacturing "
            "units.",
            "DGMS circulars on confined-space entry, gas testing, and support of roof and sides.",
            "ISO 7010 — registered safety signs, followed for every pictogram in the app.",
        ],
        "right_head": "Technical references",
        "right": [
            "S. Madgwick, An efficient orientation filter for inertial and inertial/magnetic "
            "sensor arrays, 2010 — basis of the fallback pose filter.",
            "DIVOC and CoWIN verifiable credential design, Government of India — model for "
            "the offline-verifiable QR certificate.",
            "RFC 8032 (Ed25519 signatures), RFC 8949 (CBOR) and Base45 encoding for compact QR "
            "payloads.",
            "Google ML Kit — on-device barcode scanning, used with no network dependency.",
            "Project source and build: github.com/sriram4n/surakshaar",
        ],
    },
}
