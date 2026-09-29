"""Reject local credentials and operational records from public source/payloads."""
from pathlib import Path, PurePosixPath
import os
import re
import subprocess
import tempfile


def ignored_source_files(files, read):
    """Apply a snapshot's Git ignore rules without consulting the current index."""
    names = sorted(files)
    if not names:
        return set()
    for name in names:
        path = PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts or '.git' in path.parts:
            raise ValueError('Invalid source path')
    # Hooks can inherit GIT_DIR/GIT_INDEX_FILE; global excludes must not change
    # which source files a historical snapshot or exported checkout publishes.
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)
    with tempfile.TemporaryDirectory(prefix='source-ignore-') as directory:
        subprocess.run(['git', 'init', '-q', '--template=', directory],
                       env=env, check=True, capture_output=True)
        for name in names:
            if PurePosixPath(name).name == '.gitignore':
                target = Path(directory) / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(read(name))
        result = subprocess.run(
            ['git', '-C', directory, '-c', 'core.excludesFile=' + os.devnull,
             'check-ignore', '--no-index', '-z', '--stdin'],
            input=('\0'.join(names) + '\0').encode(), env=env, capture_output=True)
        if result.returncode not in (0, 1):
            raise ValueError('Cannot evaluate source ignore rules')
        return set(filter(None, result.stdout.decode().split('\0')))


def private_name(name):
    path = PurePosixPath(name)
    leaf = path.name.lower()
    return (any(part.lower() in {'.git', '.local', '.venv', '.ssh', '.aws', 'out', 'logs'} for part in path.parts)
            or (leaf.startswith('.env') and leaf != '.env.example')
            or leaf.endswith(('.p8', '.p12', '.pfx', '.key', '.pem', '.keychain', '.keychain-db',
                              '.mobileprovision', '.provisionprofile', '.log'))
            or leaf in {'prepared.json', 'prepared-dmg.json', 'state.json', 'release.json', 'notary-log.json',
                        'submission.zip', 'submission.dmg', 'source.zip',
                        'credentials.json', '.netrc', '.npmrc', '.pypirc', '.ds_store'})


def content_findings(data):
    patterns = {
        'personal filesystem path': rb'(?:/Users/|/home/)[A-Za-z0-9_.-]+/',
        'mounted personal storage path': rb'/Volumes/[A-Za-z0-9_.-]+/',
        'private camera filename': rb'\bRX\d{5,}\b',
        'private key': rb'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----',
        'access token': rb'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16}|sk-[A-Za-z0-9_-]{24,})\b',
    }
    return [category for category, pattern in patterns.items() if re.search(pattern, data)]


def check_bundle(bundle):
    """Scan the actual assembled files, including binary payloads; never echo data."""
    bundle = Path(bundle).resolve()
    private_paths = (str(Path.home()).encode(), str(Path(__file__).resolve().parents[1]).encode())
    for path in bundle.rglob('*'):
        relative = path.relative_to(bundle).as_posix()
        if private_name(relative):
            raise ValueError('Package contains a credential or local operation file')
        if path.is_symlink():
            if not path.resolve(strict=True).is_relative_to(bundle):
                raise ValueError('Package contains an external symlink')
        elif path.is_file():
            data = path.read_bytes()
            if content_findings(data) or any(token in data for token in private_paths):
                raise ValueError('Package contains private content; inspect locally without sharing logs')
