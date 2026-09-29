# Changelog

This project follows [Semantic Versioning](https://semver.org/). User-visible changes are recorded here before a version tag is created.

## 0.18.5 - 2026-09-30

Initial public release.

- Batch tilt correction using local image analysis, with optional use of recorded camera-level data and automatic fallback to image analysis.
- Match same-named photos to a selected RAW/DNG or JPEG/HEIF reference, or straighten each photo independently.
- Left and right angle limits that can be linked or set separately, with a choice to review or skip corrections over the limit.
- Skip photos that already have an angle adjustment, or reset their crop before applying a new angle.
- Minimize view changes or show each photo in Develop; optionally update flags, color labels and Quick Collection membership.
- Verify saved crops before continuing, keep completed work when stopped, and review an interrupted adjustment on the next run.
- English and Japanese interface, user guide and offline installation instructions.
- Apple silicon distribution for macOS 26 or later, with local Developer ID signing and notarization workflows for ZIP and DMG packages.
