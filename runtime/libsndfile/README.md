# Hermeneus decoder revision 1.2.2-hermeneus.2

Base: libsndfile 1.2.2 (LGPL-2.1-or-later); archive SHA-256 is pinned in rebuild_sndfile.py.

- unaligned.patch preserves upstream commit 474e4d328b1e6240b93ec6ed14efb7c6a44bee57 as provenance.
- unaligned-1.2.2.patch backports that fix to the release byte-counting implementation and clears scratch bytes before every field read. Multi-byte writes use helpers accepting void pointers.
- cue-label.patch is upstream PR #1170, commit 8adad503eb15ac63e3425edec11b08cb6cf6b549. It is an unmerged candidate backport, not an official new release.

Rebuild with scripts/rebuild_sndfile.py, then copy its library and build.json here. Rebuild both workers and run scripts/record_decoders.py. The packagers reject mismatched decoder or worker records.

External FLAC/Vorbis/Opus/MPEG codecs are disabled in this narrow library. User compressed audio continues through the bundled FFmpeg fallback; diarization already normalizes all inputs to PCM WAV with FFmpeg. WAV/AIFF PCM is decoded locally by the patched library.

Source and patches are shipped for LGPL relinking/rebuilding; no upstream release-wide security clearance is claimed. The local validation includes sanitizer regressions for malformed MPEG WAV headers and short/long cue labels.

References:
https://github.com/libsndfile/libsndfile/issues/1150
https://github.com/libsndfile/libsndfile/pull/1170
https://github.com/libsndfile/libsndfile/issues/1169

## Decoder .2 follow-up (2026-10-17)

- ima-counts-1.2.2.patch backports the three frame-count widening operations from upstream commits 9a829113c88a51e57c1e46473e90609e4b7df151 and cdadf9a65fdc1f28da9d235eb443d5f5e57010d2. The unchanged upstream patches are retained as ima-aiff-upstream.patch and ima-wav-upstream.patch.
- ircam-bounds-1.2.2.patch adapts unmerged candidate c69a058fdf70c9995ee15a3747af1d372452824d (PR #1099); ircam-upstream.patch preserves the proposal. Unlike that proposal, compare samplerate and INT_MAX as double: converting INT_MAX to float rounds up to 2147483648, which would still admit an out-of-range cast. Validate channels, blockwidth and the fixed data offset before use. In 1.2.2 blockwidth is int; the accepted maximum is 1024 channels times 4 bytes (4096), so the validated product fits before narrowing.
- This is local hardening with regression evidence, not an upstream release or a claim that every possible interpretation of CVE-2025-52194 is resolved. No application-level exploit has been demonstrated.
- Tests exercise real WAV IMA parsing through bounded virtual I/O (1.28 GB logical input), little/big endian IRCAM PCM compatibility, NaN/infinite/negative/zero/2^31/huge sample rates, zero channels and truncated headers. The prior .1 sanitizer build reproduces integer overflow and float-cast overflow; .2 rejects malformed IRCAM and preserves the exact 2525000000-frame WAV count.

https://github.com/libsndfile/libsndfile/pull/1123
https://github.com/libsndfile/libsndfile/pull/1099
