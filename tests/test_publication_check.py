"""Old history must report policy findings, not crash or skip content scans."""
import importlib.util
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location('publication', Path(__file__).resolve().parents[1] / 'scripts/check-publication.py')
pc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pc)


def test_empty_history_snapshot_has_no_publishable_content():
    def read(name):
        raise AssertionError(f'Empty snapshots must not read a file: {name}')
    assert pc.inspect([], read) == []
    assert pc.inspect({}, read) == []


def test_history_without_allowlist_still_scans_private_content():
    files = {'old.txt': b'-----BEGIN ' + b'PRIVATE KEY-----'}
    findings = pc.inspect(files, files.__getitem__)
    assert 'Missing committed .gitignore publication rules' in findings
    assert 'old.txt: private key' in findings


def test_historical_file_rules_still_apply_to_their_snapshot():
    files = {'.gitignore': b'*\n!*/\n!/.gitignore\n', 'unexpected.txt': b'fixture'}
    assert pc.inspect(files, files.__getitem__) == ['Ignored files are not publishable: unexpected.txt']
    files['.gitignore'] += b'!/unexpected.txt\n'
    assert pc.inspect(files, files.__getitem__) == []


def test_directory_rules_allow_new_sources_but_reject_excluded_files(monkeypatch):
    monkeypatch.setenv('GIT_DIR', '/nonexistent/inherited-hook-repository')
    files = {'.gitignore': b'/*\n!/.gitignore\n!/src/\n**/__pycache__/\n',
             'src/new module.lua': b'return {}\n',
             'src/Resources/.gitignore': b'*.txt\n!public.txt\n',
             'src/Resources/public.txt': b'public fixture\n'}
    assert pc.inspect(files, files.__getitem__) == []
    files.update({'src/__pycache__/cache.pyc': b'fixture',
                  'src/Resources/private.txt': b'fixture', 'notes.txt': b'fixture'})
    assert pc.inspect(files, files.__getitem__) == [
        'Ignored files are not publishable: notes.txt, src/Resources/private.txt, src/__pycache__/cache.pyc']


def test_directory_publication_keeps_content_checks():
    files = {'.gitignore': b'/*\n!/.gitignore\n!/src/\n',
             'src/new.lua': b'-----BEGIN ' + b'PRIVATE KEY-----'}
    assert pc.inspect(files, files.__getitem__) == ['src/new.lua: private key']


def test_model_metadata_is_checked_in_current_and_historical_layouts():
    for name in ('models/image-analysis-v1.json',
                 'src/batch_auto_straighten/models/image-analysis-v1.json'):
        files = {'.gitignore': ('!/.gitignore\n!/' + name + '\n').encode(),
                 name: json.dumps({'unexpected': 'metadata'}).encode()}
        assert pc.inspect(files, files.__getitem__) == ['Runtime model contains unexpected metadata']


def test_credentials_and_receipts_are_rejected_even_when_allowlisted():
    for name in ('AuthKey_fixture.p8', 'identity.p12', '.env.local', 'prepared.json', 'state.json',
                 'release.json', 'notary-log.json', 'submission.zip', 'prepared-dmg.json',
                 'submission.dmg', 'source.zip', 'out/public.txt'):
        files = {'.gitignore': ('!/.gitignore\n!/' + name + '\n').encode(), name: b'fixture'}
        assert 'Credential or local operation file is not publishable' in pc.inspect(files, files.__getitem__)


def test_actual_payload_rejects_secrets_and_escaping_symlinks(tmp_path):
    import pytest
    from release_privacy import check_bundle
    bundle = tmp_path / 'plugin'
    bundle.mkdir()
    data = bundle / 'helper'
    data.write_bytes(b'\x00Mach-O fixture\x00' + b'-----BEGIN ' + b'ENCRYPTED PRIVATE KEY-----')
    with pytest.raises(ValueError, match='private content'): check_bundle(bundle)
    data.write_bytes(b'safe binary\x00')
    check_bundle(bundle)
    external = tmp_path / 'external'
    external.write_text('fixture')
    (bundle / 'link').symlink_to(external)
    with pytest.raises(ValueError, match='external symlink'): check_bundle(bundle)
    (bundle / 'link').unlink()
    (bundle / 'build.log').write_text('nonsecret but private operation log')
    with pytest.raises(ValueError, match='local operation file'): check_bundle(bundle)


def test_precommit_hook_blocks_allowlisted_credential_before_commit(tmp_path):
    import shutil
    import subprocess
    root = Path(__file__).resolve().parents[1]
    (tmp_path / 'scripts').mkdir()
    for name in ('check-publication.py', 'release_privacy.py'):
        shutil.copyfile(root / 'scripts' / name, tmp_path / 'scripts' / name)
    shutil.copytree(root / '.githooks', tmp_path / '.githooks')
    files = ['.gitignore','scripts/check-publication.py','scripts/release_privacy.py',
             '.githooks/pre-commit','.githooks/pre-push','.env.local']
    (tmp_path / '.gitignore').write_text('\n'.join('!/' + name for name in files))
    (tmp_path / '.env.local').write_text('harmless fake credential fixture')
    def git(*args):
        return subprocess.run(['git','-C',str(tmp_path),*args], capture_output=True, text=True)
    assert git('init','-q').returncode == 0
    assert git('config','core.hooksPath','.githooks').returncode == 0
    assert git('add','.').returncode == 0
    result = git('-c','user.name=Fixture','-c','user.email=contributors@localhost','commit','-m','fixture')
    assert result.returncode != 0
    assert 'not publishable' in result.stderr + result.stdout
    assert git('rev-parse','--verify','HEAD').returncode != 0
    assert 'harmless fake credential fixture' not in result.stderr + result.stdout


def test_only_small_demo_gifs_in_docs_media_may_be_binary():
    gif = b'GIF89a' + b'\0' * 64
    rules = b'/*\n!/.gitignore\n!/docs/\n'
    files = {'.gitignore': rules, 'docs/media/demo.gif': gif}
    assert pc.inspect(files, files.__getitem__) == []
    video = b'\0\0\0\x18ftypisom' + b'\0' * 64
    for name, data in (('docs/demo.gif', gif), ('docs/media/nested/demo.gif', gif),
                       ('docs/media/demo.mp4', video), ('docs/media/demo.gif', video),
                       ('docs/media/demo.gif', gif + b'\0' * pc.MEDIA_LIMIT)):
        files = {'.gitignore': rules, name: data}
        assert f'{name}: binary data' in pc.inspect(files, files.__getitem__)


def test_demo_media_keeps_private_content_checks():
    files = {'.gitignore': b'/*\n!/.gitignore\n!/docs/\n',
             'docs/media/demo.gif': b'GIF89a\0' + b'/Users' + b'/someone/clip.mov'}
    assert pc.inspect(files, files.__getitem__) == ['docs/media/demo.gif: personal filesystem path']


def test_only_project_and_noreply_commit_emails_are_public():
    for email in ('info@ms-soft.jp', 'contributors@localhost', 'noreply@github.com',
                  '12345+someone@users.noreply.github.com'):
        assert pc.public_email(email)
    for email in ('someone@example.com', 'info@ms-soft.jp.example', ''):
        assert not pc.public_email(email)
