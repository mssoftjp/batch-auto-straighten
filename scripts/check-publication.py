"""Check source boundaries and committed Git content before sharing."""
from pathlib import Path, PurePosixPath
import argparse
import json
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from release_privacy import content_findings, ignored_source_files, private_name


# The README demo GIF is the only kind of binary file published. Keep it
# small and directly under docs/media so no other binary can slip in beside it.
MEDIA_DIR = 'docs/media'
MEDIA_LIMIT = 10 * 1024 * 1024


def publishable_media(name, data):
    path = PurePosixPath(name)
    return (path.parent.as_posix() == MEDIA_DIR and path.suffix == '.gif'
            and data[:6] in (b'GIF87a', b'GIF89a') and len(data) <= MEDIA_LIMIT)


# Commit identities that may appear in public history. The project address is
# public; personal addresses must never be used for published commits.
PUBLIC_EMAILS = {'contributors@localhost', 'info@ms-soft.jp', 'noreply@github.com'}


def public_email(email):
    return email in PUBLIC_EMAILS or email.endswith('@users.noreply.github.com')


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args])


def inspect(files, read):
    # Git can create an empty untracked-files snapshot for a stash. There is no
    # content to publish in an empty tree; every nonempty snapshot still needs
    # its own ignore rules and all content checks below.
    if not files:
        return []
    errors = []
    if '.gitignore' not in files:
        errors.append('Missing committed .gitignore publication rules')
    else:
        ignored = ignored_source_files(files, read)
        if ignored:
            errors.append('Ignored files are not publishable: ' + ', '.join(sorted(ignored)))
    for name in sorted(files):
        if private_name(name):
            errors.append('Credential or local operation file is not publishable')
        data = read(name)
        if not publishable_media(name, data):
            try:
                data.decode('utf-8')
            except UnicodeDecodeError:
                errors.append(f'{name}: non-text file')
            if b'\0' in data:
                errors.append(f'{name}: binary data')
        for category in content_findings(data):
            errors.append(f'{name}: {category}')
    # Historical snapshots still use the former model location.
    for model_path in ('models/image-analysis-v1.json',
                       'src/batch_auto_straighten/models/image-analysis-v1.json'):
        if model_path not in files:
            continue
        model = json.loads(read(model_path))
        fields = {'schema', 'name', 'feature_version', 'orientation_caps_deg', 'feature_names',
                  'intercept', 'coefficients', 'feature_implementation_sha256',
                  'geometry_implementation_sha256', 'geometry_config'}
        if set(model) != fields:
            errors.append('Runtime model contains unexpected metadata')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--index', action='store_true', help='Check staged files before the initial public commit')
    args = parser.parse_args()
    if args.index:
        entries = git('ls-files', '--stage', '-z').decode().split('\0')
        files = {}
        for entry in filter(None, entries):
            metadata, name = entry.split('\t', 1)
            mode, oid, stage = metadata.split()
            if stage != '0' or mode not in ('100644', '100755'):
                raise SystemExit('Only regular, unconflicted files may be published')
            files[name] = oid
    else:
        entries = git('ls-tree', '-r', '-z', 'HEAD').decode().split('\0')
        files = {}
        for entry in filter(None, entries):
            metadata, name = entry.split('\t', 1)
            mode, kind, oid = metadata.split()
            if kind != 'blob' or mode not in ('100644', '100755'):
                raise SystemExit('Only regular files may be published')
            files[name] = oid
    errors = inspect(files, lambda name: git('cat-file', 'blob', files[name]))
    if not args.index:
        if git('status', '--porcelain', '--untracked-files=no').strip():
            errors.append('Tracked files have uncommitted changes')
        # Inspect every reachable snapshot with the ignore rules committed alongside
        # it, so old notes cannot leak through tags or branches. This also permits
        # the publication rules to evolve without invalidating earlier snapshots.
        for commit in git('rev-list', '--all').decode().splitlines():
            names = git('ls-tree', '-r', '--name-only', commit).decode().splitlines()
            errors.extend(f'{commit[:12]}: {error}' for error in
                          inspect(names, lambda name: git('show', f'{commit}:{name}')))
        emails = git('log', '--all', '--format=%ae%n%ce').decode().splitlines()
        if not all(public_email(email) for email in emails):
            errors.append('Git history contains a non-public commit email address')
    if errors:
        raise SystemExit('\n'.join(errors))
    print(f'PASS: {len(files)} public text files; no disallowed files or detected private content')


if __name__ == '__main__':
    main()
