# BodyMiScale offline reference

Source: https://github.com/dckiller51/bodymiscale

- Release: `2026.10.4`
- Release commit: `3d75ed80e2f3b437f96c7b442a144f4fd9c12c97`
- Merged PR: https://github.com/dckiller51/bodymiscale/pull/476
- PR merge commit: `3109f4c13534929667e50e0012dd64fc15ae6333`
- Original formula contribution and explicit Apache-2.0 permission: https://github.com/dckiller51/bodymiscale/issues/474
- License: Apache-2.0; complete upstream license retained in `LICENSE`.

The formula transcription is credited to RX14, from **S400 Pro firmware**;
the BodyMiScale integration and public tests are credited to the BodyMiScale
contributors. This is not a claim that standard S400 firmware was directly
decompiled or that these formulas measure clinical body fat accurately.

`xiaomi_home.py` is a byte-for-byte, inert source reference from the release.
It was read, not imported or executed. The release formula and public test file
were verified byte-identical to the final merged PR versions. File hashes and
the inspected dependency metadata are recorded in `source-manifest.json`.

Modifications, 2026-10-27: Swift-only body-fat/lean-mass subset, explicit unit
names, finite/positive input and overflow checks, separate formula/integration
clamps, an optional dual-band adapter, anonymous minimal public fixtures and
offline differential tests. No muscle/water/BMR/body-age port, smoothing,
networking, or runtime storage was added to the formula module.

Production adoption, 2026-10-27: S400Menu 0.2.0 selects this formula for newly
received measurements through its existing input-validation adapter. The app
retains its year-difference age convention and stores an optional algorithm
identifier with new calculated results. Previously stored results and upload
queues are not recalculated. Formula-level rounding and the 3–55% clamp are
used; the Home Assistant integration's separate 5% floor is not used.

The new Swift module and adapted fixture tests retain Apache-2.0 attribution;
the complete S400Menu application remains GPL-3.0-or-later. Keep both sets of
notices and licenses with redistributed source or builds.

The public fixture subset retains only calculation inputs and body-fat/lean-mass
expectations needed for this study. Participant identities, handles, original
labels, timestamps, and unrelated health metrics are not included. The full
upstream test file is not copied into this repository.
