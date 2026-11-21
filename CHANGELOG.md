# Changelog

This project follows [Semantic Versioning](https://semver.org/). User-visible changes are recorded here before a version tag is created.

## 0.18.8 - 2026-11-22

- Restore aligned Photo, Result, Angle, Method and Details columns in the results table, keeping all photos in one scroll area.
- Remove the separate selected-photo details panel so each explanation stays with its photo.

## 0.18.7 - Unreleased

- Close the progress dialog before showing results so it cannot cover the completed report.
- Replace result pages with one native scrolling list containing every photo and details for the selected entry.

## 0.18.6 - Unreleased

- Prepare incomplete RAW white-balance settings before analysis so Lightroom's deferred initialization does not stop the batch.
- Ignore empty filter and profile defaults while continuing to detect actual Develop edits.
- Display large result sets in pages of 50 photos.

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
