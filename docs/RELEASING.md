# Local Developer ID ZIP and DMG releases

Run this workflow from this development repository, using Python 3.12+ in its
packaging environment (`.venv`). First install the project's package and dev
dependencies and build the minimal OpenCV runtime as described in
[DEVELOPMENT.md](DEVELOPMENT.md#build-and-test). You also need the Xcode
command line tools, a valid Developer ID Application identity with its private
key in Keychain, and a checkout of the shared `apple-developer-tools`. Lua tests
require Lua 5.1 or LuaJIT; a newer Lua interpreter installed on the system may be
incompatible.

Building and signing happen in this repository. The shared tools handle ZIP/DMG
signature verification, helper tests with synthetic images, submission to Apple
and final ticket verification. The entry point works from any current directory
and supports paths with spaces. The Team ID and signing identity must be
specified explicitly.

```sh
export MAC_RELEASE_TOOLS_ROOT=/path/to/apple-developer-tools
export MAC_RELEASE_NOTARY_PROFILE=mac-release
# Replace TEAM_ID and SIGNING_IDENTITY with your Developer ID team and identity.
# Test, review and commit source changes first. Choose NEW output directories for each candidate.
.venv/bin/python scripts/release-local.py prepare \
  --team-id TEAM_ID --signing-identity 'SIGNING_IDENTITY' --output out/releases/zip-candidate
```

`prepare` requires a clean worktree and checks version consistency. It builds and
signs into isolated directories, then re-extracts the ZIP to check native
signatures and the helpers. It never submits anything to Apple. On success,
`prepared.json` binds the source commit, version, Team and ZIP SHA-256; keep this
receipt with the package. Existing output directories are never overwritten.
Keep failed outputs for diagnosis and choose a new directory for the next build.

```sh
# This command uploads the previously checked ZIP to Apple exactly once.
.venv/bin/python scripts/release-local.py submit \
  --team-id TEAM_ID --output out/releases/zip-candidate
# Subsequent operations use the saved notarization directory.
.venv/bin/python scripts/release-local.py status \
  --team-id TEAM_ID --output out/releases/zip-candidate/notarization
.venv/bin/python scripts/release-local.py resume \
  --team-id TEAM_ID --output out/releases/zip-candidate/notarization
.venv/bin/python scripts/release-local.py verify \
  --team-id TEAM_ID --output out/releases/zip-candidate/notarization
```

Use `--tools-root` instead of the environment variable if you prefer. Credentials
stay in the configured Keychain profile; never put a private key or password in
these commands. `prepare` and `verify` need no Apple API credentials, although
`verify` still checks tickets online. `status` and `resume` use the saved version,
so they still work after the development source has moved on to a newer version.
Existing notarization directories created directly by the shared adapter are also
supported.

`In Progress` means the submission is pending. `Accepted` with
`local_phase: ticket_unconfirmed` means local ticket verification has not
finished: run **resume** again with the same submission and ZIP. This can happen
when the ticket becomes available late, but a persistent failure needs diagnosis.
Retrying does not require a new submission, signature, key or certificate. A zero
exit code from a pending operation does not mean it is complete; only
`release.json` records the finished package. Run `verify` to recheck it. If an
upload times out without a saved submission ID, check the submission history
with Apple; never delete the state and submit again blindly.

The final ZIP contains a single `BatchAutoStraighten.lrplugin` directory. Neither
the ZIP nor this plug-in layout can be stapled, so first use requires an online
ticket lookup. Verifying native signatures and helpers does not establish
Lightroom integration. Separately enable the exact extracted release and test it
on a disposable virtual copy, then test the downloaded package on a fresh Mac when
publishing.

This workflow does not push to Git, publish releases or configure hosted secrets.
The GitHub packaging workflow is a manual test only: it has read-only repository
permissions, labels its artifacts `UNSIGNED-TEST-ONLY` and never creates a
Release. Pushing a tag does not build or publish an unsigned package.
`scripts/check-publication.py --index` checks the staged public content; the
default command also audits **all reachable history**. Resolve any findings in
history before sharing it, regardless of this local release.

## Add a DMG from the completed ZIP

Keep the notarized ZIP unchanged. The DMG route uses that exact ZIP as its
source and does not rebuild or re-sign the plug-in. It places `Install.html` next
to the plug-in, creates a read-only UDZO disk image and signs the image with the
same Developer ID Application identity. No Installer certificate is needed.

The shared tools checkout must include
`examples/batch-auto-straighten/dmg_release.py`. After testing and committing the
packaging changes, run:

```sh
.venv/bin/python scripts/release-local.py prepare-dmg \
  --team-id TEAM_ID --signing-identity 'SIGNING_IDENTITY' \
  --output out/releases/zip-candidate/notarization --destination out/releases/dmg-candidate
# Uploads the signed DMG to Apple once; the ZIP is not submitted again.
.venv/bin/python scripts/release-local.py submit-dmg \
  --team-id TEAM_ID --output out/releases/dmg-candidate
.venv/bin/python scripts/release-local.py status \
  --team-id TEAM_ID --output out/releases/dmg-candidate/notarization
.venv/bin/python scripts/release-local.py resume \
  --team-id TEAM_ID --output out/releases/dmg-candidate/notarization
```

The prepared record binds the payload's source commit and ZIP hash, the packaging
commit, the guide hash and the signed DMG hash. The verifier mounts the image
read-only, compares every plug-in file, symlink and execute permission with the
source ZIP, and checks native signatures and both helpers. It always detaches its
mount. If mounting or detaching fails, it keeps the mountpoint for diagnosis.

After Apple accepts the DMG, `resume` saves the Apple log, staples a copy of the
image, validates its ticket and Gatekeeper assessment, and repeats the payload
and native checks before producing `release.json`. The originally submitted DMG
is preserved; its hash differs from the finished image because stapling adds the
ticket. If stapling or verification fails, keep the output and resume the same
submission. Never re-sign or resubmit to recover from delayed ticket availability.

`status`, `resume` and `verify` choose the ZIP or DMG adapter from the saved
record. The finished DMG output keeps a private `source.zip` for later
verification. An Accepted result from Apple alone does not qualify a DMG for
export.

## Export the public assets

After `resume` has produced `release.json`, export to a new directory:

```sh
.venv/bin/python scripts/release-local.py export \
  --team-id TEAM_ID --output out/releases/zip-candidate/notarization \
  --dmg-output out/releases/dmg-candidate/notarization \
  --destination out/public-assets/candidate
```

Before copying anything, `export` rechecks the exact ZIP for the saved version,
all native signatures and online notarization tickets, and both helpers. The
destination contains only the unchanged
`BatchAutoStraighten-<version>-macos-arm64.zip`, the stapled
`BatchAutoStraighten-<version>-macos-arm64.dmg`, and `SHA256SUMS` for both files.
Omit `--dmg-output` to export only the ZIP. Export rejects a DMG bound to a
different ZIP, version or source commit. Pending, rejected, ticket-unconfirmed,
modified or unverifiable releases cannot be exported. The source release
directory and its private records stay local. Export does not upload to Apple or
publish to GitHub.

When publication is authorized, attach only these exported files. Do not rebuild
the ZIP in CI, use `out/unsigned/*.zip`, or upload a preparation or notarization
directory. Match the tag to the saved `source_commit` and version, and complete
the public-history check before pushing. GitHub-generated source archives contain
source code, not the installable signed plug-in.

## Check first use before publication

Use a fresh Mac or VM that has never run this plug-in. Download the exact
candidate with Safari so that the normal download quarantine is applied, keep the
Mac online, and add the extracted `.lrplugin` in Lightroom Classic. On a
disposable photo or virtual copy, check **Image analysis only**, **Prefer camera
level (experimental)** and the angle review dialog. Check labels and tooltips in
both English and Japanese. Confirm that no unknown-developer or
cannot-check-for-malicious-software warnings appear. Keep the ZIP hash with the
local test result.

Do not remove quarantine or use Open Anyway to make this acceptance check pass.
The plug-in preserves quarantine and does not automatically retry a blocked
helper. Apple's acceptance and command-line ticket checks do not prove this
Lightroom path; see [Apple's testing guidance](https://developer.apple.com/forums/thread/130560).

For the stapled DMG, repeat this test on a fresh Mac or VM, disabling networking
before opening the downloaded DMG. Copy the plug-in to a permanent folder before
registering it in Lightroom, then eject the DMG and test both analysis modes and
the review preview. Do not register the copy inside the mounted image. The
installation guide works without a network connection. Stapler and Gatekeeper
command-line checks do not establish offline first use in Lightroom; the DMG
manifest keeps that test marked `not_verified` until it is recorded separately.
Normal download confirmations and macOS file-access permission prompts may still
appear. The ZIP still relies on an online lookup at first use.

## Public repository boundary

Keep signing credentials in Keychain or outside this development repository. The
local entry point rejects API key paths inside the source checkout and refuses to
run in GitHub Actions. Signed packaging also rejects GitHub Actions; the manual
unsigned/ad-hoc packaging check is for development only. Do not paste local
environment dumps, compiler logs or notarization records into public issues or CI
configuration.

An output directory inside any Git repository must be ignored and must contain no
tracked files. The entry point checks this before starting work. New preparation
folders are created with mode 700, and the captured compiler/signing log with
mode 600. Never upload that folder recursively: select only the verified final
distribution ZIP and any public notices or hash files you have explicitly
reviewed. Receipts and submission logs stay local.

The public-content check rejects credential and operation filenames even when
someone places them in a public source directory. Before making the ZIP, the
packager scans the assembled files for forbidden filenames, private key/token
patterns and personal paths. Gitignore and pattern checks are safeguards, not a
guarantee against every unknown secret. Inspect the final upload selection as
well as the source index and history. The Developer ID certificate subject and
Team ID remain visible in signed binaries; private keys are not part of a code
signature.

Local Git hooks run the index check before each commit and the full history check
before each push. Enable them in each checkout with
`git config --local core.hooksPath .githooks` after checking for existing custom
hooks; integrate with existing hooks rather than overwriting them. Check the
active setting with `git config --get core.hooksPath`; a clone does not inherit
it. Do not bypass a failing hook: resolve its findings before publication. Git
hooks can be bypassed, so they supplement review and do not guarantee secrecy on
their own.

## Local development checks

See [DEVELOPMENT.md](DEVELOPMENT.md) for the source layout, development plug-in
build, tests and Lightroom reload procedure. Run commands from the repository root.
