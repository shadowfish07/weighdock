# Third-party notices

This application is distributed under GPL-3.0-or-later. See LICENSE. It is supplied without warranty.

## openScale

Source: https://github.com/oliexdev/openScale
Pinned revision: `87edad4813e400cd4871109fc72a0bcf4d13f336`
License: GPL-3.0-or-later.

The Swift S400 decoder, packet aggregation, body-fat equation and gates, and public protocol test fixtures are adapted from:

- `S400Decryptor.kt`, `MiScaleS400Handler.kt`, `BroadcastScaleAdapter.kt`: Copyright (C) 2025 olie.xdev <olie.xdeveloper@googlemail.com>.
- `S400Aggregator.kt`, `S400BodyComposition.kt`: Copyright (C) 2026 Dany Mestas.
- `S400DecryptorTest.kt`, `S400BodyCompositionTest.kt`: copyright notices retained in the Swift adaptations and original reference files.

Original algorithm files are retained under Reference/. The upstream decoder credits https://github.com/lswiderski/mi-scale-exporter and https://github.com/lswiderski/MiScaleBodyComposition as protocol references.

Modifications (2026-10-26): Swift/macOS port, Apple AES primitive with authenticated CCM, unsigned impedance extraction, real timer-driven session expiry, weight-only fallback, persistent deduplication, minimal body-fat-only pipeline, no invalid-body-fat substitution with zero, no MAC/key/packet logging.

The Deurenberg body-fat subset and its formula-specific gates are retained for explicit legacy/offline comparison. New measurements from version 0.2.0 use the BodyMiScale formula below, with generic input/contact validation. Neither calculation is a claim of clinical accuracy or guaranteed agreement with Xiaomi's proprietary app.

## BodyMiScale compatibility algorithm and offline study

Source: https://github.com/dckiller51/bodymiscale, release `2026.10.4`, revision
`3d75ed80e2f3b437f96c7b442a144f4fd9c12c97`; merged PR #476.
Formula transcription from S400 Pro firmware by RX14; integration and tests by
BodyMiScale contributors. Apache-2.0, see Reference/BodyMiScale/LICENSE and
Reference/BodyMiScale/NOTICE.md. The retained Python reference is not executed.

Modifications (2026-10-27): isolated Swift body-fat/lean-mass subset and offline
anonymous comparisons, separate 3–55 formula and 5–75 metric clamps, input and
overflow validation. From app 0.2.0, new measurements use the formula-level
body-fat result through S400Core; old stored fat and delivery states are not
recalculated. The former scientific path is retained only for explicit offline
comparison. No claim
of direct standard-S400 firmware reverse engineering, clinical accuracy, or
reproducing the author's QEMU tests is made.

## Google GTMAppAuth

Source: https://github.com/google/GTMAppAuth
Version: 6.0.0, revision `57094cd46bc8700d3a887e2a429f42b6e8ea3f0b`.
Copyright Google LLC. Apache-2.0, see Vendor/GTMAppAuth/LICENSE.
The vendored Package.swift changes only dependency references to local paths for offline builds.

## AppAuth-iOS/macOS

Source: https://github.com/openid/AppAuth-iOS
Version: 3.0.0, revision `a972daac82d449d58ab119e91c68153e29ddac33`.
Copyright The AppAuth Authors. Apache-2.0, see Vendor/AppAuth-iOS/LICENSE.

## Google GTMSessionFetcher

Source: https://github.com/google/gtm-session-fetcher
Version: 5.0.0, revision `fb7f2740b1570d2f7599c6bb9531bf4fad6974b7`.
Copyright Google LLC. Apache-2.0, see Vendor/gtm-session-fetcher/LICENSE.

Retained vendored source, copyright headers, runtime privacy resources, and licenses are preserved. The source export omits third-party example applications and unrelated project tooling, while retaining every package target path needed to resolve and build this application. GTMAppAuth's local dependency path adjustment is described above. Complete corresponding application source and build scripts are in this directory; keep the matching source available with any redistributed build and honor GPL source-distribution requirements.
