# Development

This repository contains the source needed to build Batch Auto Straighten.
Generated plug-in folders are kept out of Git. Users install the signed, notarized
ZIP or DMG attached to a GitHub Release; see [RELEASING.md](RELEASING.md).

## Repository layout

```text
src/
  lightroom/                 Lua plug-in code, strings and interface resources
    Resources/              Small, uncompressed PDF vector icons
  native/                   Swift camera metadata and crop-preview helper
  batch_auto_straighten/     Python image-analysis package and executable entry
    models/                 Runtime model used by that package
  installer/                Offline installation guide included in the DMG
scripts/                    Build, version, release and publication tools
tests/                      Python and Lua regression tests
docs/                       Development and release guides
licenses/                   Third-party license texts copied into releases
README.md                   User guide, English first with Japanese translation
CHANGELOG.md                Release changes
LICENSE                     License for this project's original code and model
NOTICE                      Third-party attribution and license inventory
SECURITY.md                 Security reporting instructions
pyproject.toml              Python package, dependency and test configuration
setup.cfg                   Python intermediate build directory
.github/                    Hosted CI and packaging checks
.githooks/                  Local publication checks
```

`src/` contains the product code and resources that become part of the plug-in
or installer, including the Swift helper. The executable entry point lives with
the Python runtime, and the installation HTML lives with the installer rather
than with the build scripts.

`batch_auto_straighten/` is the Python import package, not a redundant copy of
the repository name. Imports, tests, the editable install and the bundled runtime
all use this name. Keeping this boundary keeps Python modules out of the
directories that hold Lua and Swift files. Package discovery is restricted to
this Python package.

`scripts/` runs on the developer's machine or in CI to build and check products,
and `tests/` verifies them; neither is runtime code. `docs/` describes development
and release operations. Files at the root stay easy for users and tools to find.

The license files serve three different purposes: `LICENSE` covers the original
work, `NOTICE` lists third-party origins and license references, and `licenses/`
stores third-party license texts. Release packaging also adds the license texts
collected from the Python, NumPy, OpenCV and PyInstaller installations it
actually uses. See `NOTICE` for the paths in the source repository and in the
package.

## Runtime responsibilities

| Module | Responsibility |
|---|---|
| `BatchAutoStraighten.lua` | Batch lifetime, cancellation, grouping and the decision to apply each correction. |
| `CropControl.lua` | Lightroom selection/module ownership, crop-tool readiness and stable save verification. |
| `DirectCrop.lua` | Eligibility and geometry for crop writes that avoid opening Develop. |
| `HorizonMath.lua`, `RunPolicy.lua`, `GroupPlan.lua` | Angle math, user options and reference-photo selection. |
| `HelperLaunch.lua`, `HelperProtocol.lua` | Bounded helper invocation and validation of its JSON response. |
| `PhotoMarks.lua`, `QuickCollection.lua` | Queued photo marks, conflict checks and persistence verification. |
| `SaveCheckpoint.lua`, `RecoveryDialog.lua` | Durable evidence for the active save and recovery after interruption. |
| `RunReport.lua`, `ResultDialog.lua` | Shared result counts, diagnostic text and the results table. |
| `StartDialog.lua`, `ReviewDialog.lua`, `PluginInfoProvider.lua` | Settings, angle approval and plug-in information. |
| `Localization.lua` | Read current translations when Lightroom retains a stale dictionary after reload. |

The batch owns changes to the selection and module state. Crop and mark writes
must recheck that state and the relevant settings after any SDK call that can
yield. An applied angle becomes a shared reference only after its complete crop
has settled. A reference photo that needs no correction takes both its shared
angle and its settings from a single unchanged catalog snapshot; when Develop is
open, the Develop control is also checked against that angle. Keep these guards
when changing how work is scheduled.

The current helper and checkpoint schemas are persisted contracts and are
independent of the plug-in version. Keep schema checks, recovery records,
camera-format readers and Lightroom normalization rules, even when removing
development-era code. The publication checker still inspects historical model
paths because it audits reachable Git history, and the release tools must be able
to resume from saved receipts.

The Python model pins the implementation hashes of `image_features.py` and
`image_geometry.py`. A change to either file requires reviewing model
consistency; the loader deliberately rejects a model paired with different
source bytes.

## Generated and local files

| Location | Purpose |
|---|---|
| `.local/development/BatchAutoStraighten.lrdevplugin/` | Generated development plug-in using the local Python environment. |
| `.local/package-build/` | Default unsigned packaging work and frozen runtime. |
| `.local/python-build/` | Python wheel build intermediates. |
| `.local/` (other subdirectories) | Local dependency builds, caches and private development material. |
| `.venv/` | Local Python environment. |
| `out/unsigned/` | Unsigned ZIPs for local or CI checks. |
| `out/releases/<candidate>/` | Isolated signing work and notarization records. |
| `out/public-assets/<release>/` | Verified ZIP/DMG and checksums exported for publication. |

Use `.local/` for intermediate work and `out/` for archives and release work.
The build scripts do not create top-level `build/` or `dist/` directories.
Keep existing release directories where they are, because saved DMG records can
refer to a completed ZIP by its absolute path. New release candidates use the
layout above. Only the files exported under `out/public-assets/` are intended for
publication.

These locations and all `.lrplugin` / `.lrdevplugin` directories are ignored.
`.gitignore` publishes `src/`, `scripts/`, `tests/`, `docs/`, `licenses/`,
`.github/` and `.githooks/` as whole directories and lists only root files
individually, so new source files in these directories need no allowlist entry.
Caches, generated plug-in bundles, Finder metadata and local test fixtures stay
excluded. Keep local notes and temporary material under `.local/`.

The publication checker applies the ignore rules saved with each snapshot it
inspects, including nested `.gitignore` files. Historical snapshots are checked
against their own rules.

The release assembly copies `src/lightroom/` using the same Git ignore rules,
including rules in nested `.gitignore` files. New Lua modules, translations and
resources are included automatically; the ignore files themselves are not
bundled. The angle-link icons are original vector paths stored as text-only PDFs,
so no generated raster files or fonts are needed.

ZIP and DMG assets, together with `SHA256SUMS`, are published through GitHub
Releases after the checks in [RELEASING.md](RELEASING.md). The repository's source
archives are for development. Generated folders and private release records stay
local.

## Build and test

Run these commands from the repository root. Development requires macOS 26 or
later, the Xcode command line tools, Python 3.12 or later, and Lua 5.1 or LuaJIT
for the Lua tests.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -e '.[dev,package]'
.venv/bin/python scripts/build_plugin.py
```

To assemble a self-contained test ZIP, first build the minimal OpenCV runtime:

```sh
.venv/bin/python scripts/build-minimal-opencv.py
.venv/bin/python scripts/package-plugin.py
```

The OpenCV build downloads its pinned source archive if it is not already cached.
The packager writes to `out/unsigned/` by default and keeps its temporary work
under `.local/package-build/`.

In Lightroom Classic's Plug-in Manager, add
`.local/development/BatchAutoStraighten.lrdevplugin`. After editing source, build
again and reload that same copy. Quit Lightroom or let any active plug-in run
finish before rebuilding. This copy uses the Python environment that ran the
build and is for local development only.

```sh
.venv/bin/python scripts/manage-version.py --check
.venv/bin/python -m pytest
for test_file in tests/*.lua; do
  luajit "$test_file"
done
```

Tests generate helper runtimes under `.local/` and do not write binaries into
`src/`. The Lua suite runs the real runtime modules against a mocked SDK,
covering cancellation, concurrent edits, delayed saves, RAW/HEIF matching and
recovery. The Python tests cover the native helpers, image analysis, assembly and
release tools, and also check module inclusion and translation completeness.

Follow [COPY_STYLE.md](COPY_STYLE.md) when editing UI text. Keep `LOC` text,
English and Japanese translation keys and format arguments in sync, and remove
both translations when a key is no longer used. Reload the built plug-in in
Lightroom to check labels and tooltips; automated checks cannot confirm that the
UI looks right.
