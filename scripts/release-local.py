#!/usr/bin/env python3
"""Build ZIP/DMG locally; delegate distribution verification and notarization."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ADAPTER = Path('examples/batch-auto-straighten/release.py')
DMG_ADAPTER = ADAPTER.with_name('dmg_release.py')


def run(*args, capture=False, log=None):
    return subprocess.run([str(a) for a in args], cwd=ROOT, check=True,
                          text=True, stdout=log if log is not None else (subprocess.PIPE if capture else None),
                          stderr=subprocess.STDOUT if log is not None else None).stdout


def clean_commit():
    if run('git', 'status', '--porcelain', '--untracked-files=all', capture=True).strip():
        raise ValueError('Commit source changes and use a clean worktree before prepare')
    return run('git', 'rev-parse', 'HEAD', capture=True).strip()


def tools_root(value):
    # Only explicit locations: no accidental selection of another tools checkout.
    location = value or os.environ.get('MAC_RELEASE_TOOLS_ROOT')
    if not location:
        raise ValueError('Set MAC_RELEASE_TOOLS_ROOT or --tools-root to the shared tools checkout')
    root = Path(location).expanduser().resolve()
    if not (root / ADAPTER).is_file():
        raise ValueError('Shared Batch Auto Straighten release adapter was not found')
    return root


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def metadata(path, team):
    data = json.loads(path.read_text())
    if data.get('team_id') != team or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', data.get('version', '')):
        raise ValueError('Saved Team/version mismatch')
    return data


def archive_path(output, version):
    return output / 'package' / f'BatchAutoStraighten-{version}-macos-arm64.zip'


def private_output(output):
    """An ignored directory is safe only while none of its files are tracked."""
    ancestor = output
    while not ancestor.is_dir():
        ancestor = ancestor.parent
    found = subprocess.run(['git', '-C', str(ancestor), 'rev-parse', '--show-toplevel'],
                           capture_output=True, text=True, check=False, env={**os.environ, 'LC_ALL': 'C'})
    if found.returncode:
        if found.returncode == 128 and 'not a git repository' in found.stderr:
            return
        raise ValueError('Cannot establish output Git boundary')
    repo = Path(found.stdout.strip()).resolve()
    relative = output.relative_to(repo).as_posix()
    tracked = subprocess.run(['git', '-C', str(repo), 'ls-files', '-z', '--', relative],
                             capture_output=True, check=True)
    ignored = subprocess.run(['git', '-C', str(repo), 'check-ignore', '-q', '--no-index', '--',
                              relative + '/.release-private-probe'], capture_output=True)
    if tracked.stdout or ignored.returncode != 0:
        raise ValueError('Release output must be Git-ignored and contain no tracked files')


def prepare_dmg(args, output, base, dmg_base, identity):
    commit = clean_commit()
    saved = metadata(output / 'release.json', args.team_id)
    version = saved['version']
    source = output / f'BatchAutoStraighten-{version}-macos-arm64.zip'
    run(*dmg_base, 'verify-archive', '--help', capture=True)
    run(*base, 'verify-release', '--output', output, *identity, '--expected-version', version)
    destination = Path(args.destination).expanduser().resolve()
    private_output(destination)
    destination.mkdir(parents=True, exist_ok=False, mode=0o700)
    contents = destination / 'contents'
    contents.mkdir()
    guide = ROOT / 'src/installer/Install.html'
    guide_digest = sha256(guide)
    archive = destination / f'BatchAutoStraighten-{version}-macos-arm64.dmg'
    with (destination / 'build-dmg.log').open('x') as log:
        os.chmod(destination / 'build-dmg.log', 0o600)
        run('/usr/bin/ditto', '-x', '-k', source, contents, log=log)
        shutil.copyfile(guide, contents / 'Install.html')
        # Check the actual DMG payload, including the public installation guide.
        sys.path.insert(0, str(ROOT / 'scripts'))
        from release_privacy import check_bundle
        check_bundle(contents)
        run('/usr/bin/hdiutil', 'create', '-srcfolder', contents, '-volname',
            f'Batch Auto Straighten {version}', '-format', 'UDZO', '-fs', 'HFS+', '-o', archive, log=log)
        run('/usr/bin/codesign', '--sign', args.signing_identity, '--timestamp', '--identifier',
            'jp.mssoft.lightroom.batchautostraighten.dmg', archive, log=log)
    digest = sha256(archive)
    run(*dmg_base, 'verify-archive', '--archive', archive, '--zip-release', output,
        '--guide-sha256', guide_digest, *identity, '--expected-version', version)
    if clean_commit() != commit or sha256(archive) != digest or sha256(source) != saved['sha256']:
        raise ValueError('Source or DMG changed during preparation')
    (destination / 'prepared-dmg.json').write_text(json.dumps({
        'format': 'dmg', 'version': version, 'team_id': args.team_id, 'archive': archive.name,
        'sha256': digest, 'source_zip_sha256': saved['sha256'], 'zip_release': str(output),
        'source_commit': saved['source_commit'], 'packaging_commit': commit,
        'installation_guide_sha256': guide_digest,
    }, indent=2) + '\n')
    print(f'Prepared signed DMG: {destination}. Submit with submit-dmg.')


def execute(args):
    if os.environ.get('GITHUB_ACTIONS') == 'true':
        raise ValueError('This signing workflow is local-only; do not run it in GitHub Actions')
    adapter = tools_root(args.tools_root) / ADAPTER
    output = Path(args.output).expanduser().resolve()
    private_output(output)
    key = os.environ.get('MAC_RELEASE_API_KEY_PATH')
    if key and Path(key).expanduser().resolve().is_relative_to(ROOT):
        raise ValueError('Keep Apple credentials outside the development repository; use Keychain')
    base = [sys.executable, adapter]
    dmg_base = [sys.executable, adapter.with_name(DMG_ADAPTER.name)]
    identity = ['--team-id', args.team_id]
    if args.command == 'prepare-dmg':
        prepare_dmg(args, output, base, dmg_base, identity)
    elif args.command == 'submit-dmg':
        saved = metadata(output / 'prepared-dmg.json', args.team_id)
        name = f'BatchAutoStraighten-{saved["version"]}-macos-arm64.dmg'
        if saved.get('format') != 'dmg' or saved.get('archive') != name or sha256(output / name) != saved['sha256']:
            raise ValueError('Prepared DMG changed or invalid')
        source = Path(saved['zip_release'])
        source_metadata = metadata(source / 'release.json', args.team_id)
        if (source_metadata.get('sha256') != saved['source_zip_sha256']
                or source_metadata.get('source_commit') != saved['source_commit']):
            raise ValueError('DMG source ZIP binding changed')
        run(*dmg_base, 'release', '--archive', output / name, '--zip-release', source,
            '--guide-sha256', saved['installation_guide_sha256'], '--output', output / 'notarization',
            *identity, '--expected-version', saved['version'])
        print(f'For status/resume/verify use --output {output / "notarization"}')
    elif args.command == 'prepare':
        commit = clean_commit()
        version = run(sys.executable, ROOT / 'scripts/manage-version.py', '--check', capture=True).strip()
        # Check adapter compatibility before an expensive signing build.
        run(*base, 'verify-archive', '--help', capture=True)
        output.mkdir(parents=True, exist_ok=False, mode=0o700)
        # Compiler output can include local paths and certificate subjects.
        with (output / 'build.log').open('x') as log:
            os.chmod(output / 'build.log', 0o600)
            run(sys.executable, ROOT / 'scripts/package-plugin.py', '--signing-identity', args.signing_identity,
                '--work-dir', output / 'build', '--output-dir', output / 'package', log=log)
        archive = archive_path(output, version)
        digest = sha256(archive)
        run(*base, 'verify-archive', '--archive', archive, *identity, '--expected-version', version)
        if clean_commit() != commit or sha256(archive) != digest:
            raise ValueError('Source or ZIP changed during preparation; no receipt produced')
        receipt = {'source_commit': commit, 'version': version, 'team_id': args.team_id, 'sha256': digest}
        (output / 'prepared.json').write_text(json.dumps(receipt, indent=2) + '\n')
        print(f'Prepared and verified: {output}. Submit is a separate command.')
    elif args.command == 'submit':
        receipt = metadata(output / 'prepared.json', args.team_id)
        if not re.fullmatch('[a-f0-9]{40}', receipt.get('source_commit', '')):
            raise ValueError('Prepared source commit is missing or invalid')
        archive = archive_path(output, receipt['version'])
        if sha256(archive) != receipt['sha256']:
            raise ValueError('Prepared ZIP changed; refusing submission')
        # Adapter creates this directory exclusively and locks it, preventing
        # a second upload even after a timeout with an uncertain Apple response.
        run(*base, 'release', '--archive', archive, '--output', output / 'notarization',
            *identity, '--expected-version', receipt['version'], '--source-commit', receipt['source_commit'])
        print(f'For status/resume/verify use --output {output / "notarization"}')
    else:
        filename = 'release.json' if args.command in ('verify', 'export') else 'state.json'
        saved = metadata(output / filename, args.team_id)
        if saved.get('format') == 'dmg':
            base = dmg_base
        if args.command == 'export':
            if saved.get('format') == 'dmg':
                raise ValueError('Export from the ZIP release with --dmg-output to produce both formats')
            destination = Path(args.destination).expanduser().resolve()
            private_output(destination)
            if destination.exists():
                raise ValueError('Export destination must be a new directory')
            archive_name = f'BatchAutoStraighten-{saved["version"]}-macos-arm64.zip'
            if (saved.get('archive') != archive_name or saved.get('notarization') != 'Accepted'
                    or saved.get('notarization_ticket_check') != 'passed'
                    or not re.fullmatch('[a-f0-9]{64}', saved.get('sha256', ''))):
                raise ValueError('Export requires a completed notarized release')
            # Re-extract and check every native signature, ticket, and helper.
            run(*base, 'verify-release', '--output', output, *identity, '--expected-version', saved['version'])
            assets = [(output / archive_name, saved['sha256'])]
            if getattr(args, 'dmg_output', None):
                dmg_output = Path(args.dmg_output).expanduser().resolve()
                private_output(dmg_output)
                dmg_saved = metadata(dmg_output / 'release.json', args.team_id)
                dmg_name = f'BatchAutoStraighten-{saved["version"]}-macos-arm64.dmg'
                if (dmg_saved.get('format') != 'dmg' or dmg_saved.get('archive') != dmg_name
                        or dmg_saved.get('version') != saved['version']
                        or dmg_saved.get('source_zip_sha256') != saved['sha256']
                        or dmg_saved.get('source_commit') != saved.get('source_commit')):
                    raise ValueError('ZIP and DMG must contain the same release')
                run(*dmg_base, 'verify-release', '--output', dmg_output, *identity, '--expected-version', saved['version'])
                assets.append((dmg_output / dmg_name, dmg_saved['sha256']))
            destination.mkdir(parents=True, exist_ok=False, mode=0o700)
            # Verify every copy before exposing any final distribution filename.
            for source, digest in assets:
                partial = destination / (source.name + '.part')
                shutil.copyfile(source, partial)
                if sha256(partial) != digest:
                    raise ValueError('Verified archive changed during export; no distribution set produced')
            for source, _ in assets:
                (destination / (source.name + '.part')).rename(destination / source.name)
            (destination / 'SHA256SUMS').write_text(''.join(f'{digest}  {source.name}\n' for source, digest in assets))
            print(f'Exported {len(assets)} verified archive(s) and SHA256SUMS: {destination}. Publication is a separate step.')
            return
        # Saved version deliberately wins over the current source version.
        # An older release must remain resumable after development advances.
        command = {'resume': 'release', 'status': 'status', 'verify': 'verify-release'}[args.command]
        extra = ['--resume'] if args.command == 'resume' else []
        run(*base, command, *extra, '--output', output, *identity, '--expected-version', saved['version'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('prepare', 'submit', 'prepare-dmg', 'submit-dmg', 'status', 'resume', 'verify', 'export'):
        cmd = commands.add_parser(name)
        cmd.add_argument('--tools-root', help='Shared checkout; defaults to MAC_RELEASE_TOOLS_ROOT')
        cmd.add_argument('--team-id', required=True)
        cmd.add_argument('--output', required=True,
                         help='Prepared directory for submit/submit-dmg; ZIP release for prepare-dmg/export; notarization directory for status/resume/verify')
        if name in ('prepare', 'prepare-dmg'):
            cmd.add_argument('--signing-identity', required=True, help='Developer ID Application identity or fingerprint')
        if name in ('export', 'prepare-dmg'):
            cmd.add_argument('--destination', required=True, help='New directory for prepared DMG or exported assets')
        if name == 'export':
            cmd.add_argument('--dmg-output', help='Completed DMG notarization directory; export ZIP + DMG + SHA256SUMS')
    args = parser.parse_args()
    if not re.fullmatch('[A-Z0-9]{10}', args.team_id):
        parser.error('Expected a 10-character Team ID')
    try:
        execute(args)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        # Do not echo subprocess argv or credential environment variables.
        message = f'Command failed (exit {error.returncode})' if isinstance(error, subprocess.CalledProcessError) else str(error)
        print(f'Local release stopped: {message}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
