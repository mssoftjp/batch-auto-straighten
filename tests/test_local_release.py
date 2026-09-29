"""Local release handoff preserves artifact identity across source revisions."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('local_release', ROOT / 'scripts/release-local.py')
lr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lr)


@pytest.fixture
def setup(tmp_path, monkeypatch):
    # Mocked local-release operations must not inherit the runner's CI flag.
    # The hosted-CI rejection test sets it explicitly below.
    monkeypatch.delenv('GITHUB_ACTIONS', raising=False)
    tools = tmp_path / "shared tools's checkout"
    (tools / lr.ADAPTER).parent.mkdir(parents=True)
    (tools / lr.ADAPTER).write_text('# fixture')
    args = argparse.Namespace(command='prepare', output=str(tmp_path / 'new release'),
                              tools_root=str(tools), team_id='ABCDEFGHIJ', signing_identity='Developer ID Application: Example')
    monkeypatch.setattr(lr, 'clean_commit', lambda: 'a' * 40)
    calls = []
    def run(*argv, **kwargs):
        calls.append([str(v) for v in argv])
        if str(argv[1]).endswith('manage-version.py'):
            return '0.18.0\n'
        if str(argv[1]).endswith('package-plugin.py'):
            archive = lr.archive_path(Path(args.output), '0.18.0')
            archive.parent.mkdir()
            archive.write_bytes(b'signed fixture')
        return ''
    monkeypatch.setattr(lr, 'run', run)
    return args, calls


def test_prepare_binds_clean_commit_and_hash_without_upload(setup):
    args, calls = setup
    lr.execute(args)
    receipt = json.loads((Path(args.output) / 'prepared.json').read_text())
    assert receipt['source_commit'] == 'a' * 40
    assert receipt['sha256'] == lr.sha256(lr.archive_path(Path(args.output), '0.18.0'))
    assert any('verify-archive' in call and '--archive' in call for call in calls)
    assert not any('release' in call for call in calls)
    with pytest.raises(FileExistsError):
        lr.execute(args)
    assert sum(any('package-plugin.py' in part for part in call) for call in calls) == 1


def test_prepare_dirty_source_or_failed_preflight_never_creates_receipt(setup, monkeypatch):
    args, _ = setup
    def dirty():
        raise ValueError('dirty')
    monkeypatch.setattr(lr, 'clean_commit', dirty)
    with pytest.raises(ValueError): lr.execute(args)
    assert not Path(args.output).exists()
    monkeypatch.setattr(lr, 'clean_commit', lambda: 'a'*40)
    original = lr.run
    def failure(*argv, **kwargs):
        if 'verify-archive' in argv and '--archive' in argv:
            raise subprocess.CalledProcessError(1, ['fixture'])
        return original(*argv, **kwargs)
    monkeypatch.setattr(lr, 'run', failure)
    with pytest.raises(subprocess.CalledProcessError): lr.execute(args)
    assert not (Path(args.output) / 'prepared.json').exists()


def test_submit_hash_team_and_saved_source_binding(setup):
    args, calls = setup
    lr.execute(args)
    args.command = 'submit'
    calls.clear()
    lr.execute(args)
    assert calls[0][-1] == 'a'*40
    assert str(Path(args.output) / 'notarization') in calls[0]
    calls.clear()
    args.team_id = 'KLMNOPQRST'
    with pytest.raises(ValueError, match='Team'): lr.execute(args)
    args.team_id = 'ABCDEFGHIJ'
    lr.archive_path(Path(args.output), '0.18.0').write_bytes(b'changed')
    with pytest.raises(ValueError, match='changed'): lr.execute(args)
    assert calls == []


@pytest.mark.parametrize('command,filename', [('status','state.json'), ('resume','state.json'), ('verify','release.json')])
def test_existing_release_uses_saved_version_without_current_source(setup, monkeypatch, command, filename):
    args, calls = setup
    output = Path(args.output)
    output.mkdir()
    (output / filename).write_text(json.dumps({'version':'0.17.0','team_id':args.team_id}))
    args.command = command
    monkeypatch.setattr(lr, 'clean_commit', lambda: pytest.fail('Must not require current source'))
    lr.execute(args)
    assert '0.17.0' in calls[0]
    assert ('--resume' in calls[0]) == (command == 'resume')
    assert not any('submit' in call for call in calls)


def test_tools_root_explicit_and_environment(setup, monkeypatch):
    args, _ = setup
    monkeypatch.delenv('MAC_RELEASE_TOOLS_ROOT', raising=False)
    with pytest.raises(ValueError, match='MAC_RELEASE_TOOLS_ROOT'): lr.tools_root(None)
    monkeypatch.setenv('MAC_RELEASE_TOOLS_ROOT', args.tools_root)
    assert lr.tools_root(None) == Path(args.tools_root)
    with pytest.raises(ValueError, match='not found'): lr.tools_root(Path(args.output))


def test_output_guard_checks_real_git_index_and_ignore_rules(tmp_path):
    repo = tmp_path / 'public'
    repo.mkdir()
    subprocess.run(['git','init','-q',str(repo)], check=True)
    output = repo / 'release'
    with pytest.raises(ValueError, match='Git-ignored'): lr.private_output(output)
    (repo / '.gitignore').write_text('/release/\n')
    lr.private_output(output)
    output.mkdir()
    receipt = output / 'prepared.json'
    receipt.write_text('{}')
    subprocess.run(['git','-C',str(repo),'add','-f',str(receipt)], check=True)
    with pytest.raises(ValueError, match='tracked files'): lr.private_output(output)
    # Resolving an external-looking symlink cannot hide a tracked output.
    link = tmp_path / 'alias'
    link.symlink_to(output, target_is_directory=True)
    with pytest.raises(ValueError): lr.private_output(link.resolve())


def test_hosted_ci_and_in_repo_key_path_stop_before_build(setup, monkeypatch):
    args, calls = setup
    monkeypatch.setenv('GITHUB_ACTIONS','true')
    with pytest.raises(ValueError, match='local-only'): lr.execute(args)
    monkeypatch.delenv('GITHUB_ACTIONS')
    monkeypatch.setenv('MAC_RELEASE_API_KEY_PATH', str(lr.ROOT / 'fixture.p8'))
    with pytest.raises(ValueError, match='outside'): lr.execute(args)
    assert calls == []


def test_build_output_is_redirected_to_private_log(setup, monkeypatch, capsys):
    args, _ = setup
    original = lr.run
    def build(*argv, **kwargs):
        if str(argv[1]).endswith('package-plugin.py'):
            kwargs['log'].write('PRIVATE BUILD OUTPUT')
        return original(*argv, **kwargs)
    monkeypatch.setattr(lr, 'run', build)
    lr.execute(args)
    log = Path(args.output) / 'build.log'
    assert log.read_text() == 'PRIVATE BUILD OUTPUT'
    assert log.stat().st_mode & 0o777 == 0o600
    assert Path(args.output).stat().st_mode & 0o777 == 0o700
    assert 'PRIVATE BUILD OUTPUT' not in capsys.readouterr().out


def completed_release(args):
    output = Path(args.output)
    output.mkdir()
    archive = output / 'BatchAutoStraighten-0.17.0-macos-arm64.zip'
    archive.write_bytes(b'notarized fixture')
    receipt = {'version': '0.17.0', 'team_id': args.team_id, 'archive': archive.name,
               'notarization': 'Accepted', 'notarization_ticket_check': 'passed',
               'sha256': lr.sha256(archive)}
    (output / 'release.json').write_text(json.dumps(receipt))
    (output / 'state.json').write_text('private operation record')
    (output / 'notary-log.json').write_text('private operation log')
    args.command = 'export'
    args.destination = str(output.parent / "public assets's directory")
    return output, archive, receipt


def test_export_rechecks_saved_version_and_copies_only_public_assets(setup, monkeypatch):
    args, calls = setup
    _, archive, receipt = completed_release(args)
    monkeypatch.setattr(lr, 'clean_commit', lambda: pytest.fail('Must not require current source'))
    lr.execute(args)
    destination = Path(args.destination)
    assert {p.name for p in destination.iterdir()} == {archive.name, 'SHA256SUMS'}
    assert (destination / archive.name).read_bytes() == archive.read_bytes()
    assert (destination / 'SHA256SUMS').read_text() == f'{receipt["sha256"]}  {archive.name}\n'
    assert len(calls) == 1 and 'verify-release' in calls[0] and calls[0][-1] == '0.17.0'
    with pytest.raises(ValueError, match='new directory'):
        lr.execute(args)


@pytest.mark.parametrize('field,value', [('notarization', 'In Progress'),
                                        ('notarization_ticket_check', 'unconfirmed'),
                                        ('archive', '../other.zip'), ('sha256', 'invalid')])
def test_export_rejects_incomplete_or_invalid_receipt(setup, field, value):
    args, calls = setup
    output, _, receipt = completed_release(args)
    receipt[field] = value
    (output / 'release.json').write_text(json.dumps(receipt))
    with pytest.raises(ValueError, match='completed notarized'):
        lr.execute(args)
    assert calls == [] and not Path(args.destination).exists()


def test_export_verification_failure_produces_no_assets(setup, monkeypatch):
    args, _ = setup
    completed_release(args)
    def fail(*argv, **kwargs):
        raise subprocess.CalledProcessError(1, ['verify-release'])
    monkeypatch.setattr(lr, 'run', fail)
    with pytest.raises(subprocess.CalledProcessError):
        lr.execute(args)
    assert not Path(args.destination).exists()


def test_export_detects_zip_change_after_verification(setup, monkeypatch):
    args, _ = setup
    _, archive, _ = completed_release(args)
    def change(*argv, **kwargs):
        archive.write_bytes(b'changed after verification')
    monkeypatch.setattr(lr, 'run', change)
    with pytest.raises(ValueError, match='changed during export'):
        lr.execute(args)
    assert not (Path(args.destination) / archive.name).exists()
    assert not (Path(args.destination) / 'SHA256SUMS').exists()


def completed_dmg(args, zip_receipt):
    output = Path(args.output).parent / 'completed dmg'
    output.mkdir()
    archive = output / 'BatchAutoStraighten-0.17.0-macos-arm64.dmg'
    archive.write_bytes(b'stapled dmg fixture')
    receipt = {**zip_receipt, 'format': 'dmg', 'archive': archive.name,
               'source_zip_sha256': zip_receipt['sha256'], 'sha256': lr.sha256(archive),
               'stapler': 'passed', 'gatekeeper': 'passed'}
    (output / 'release.json').write_text(json.dumps(receipt))
    args.dmg_output = str(output)
    return output, archive, receipt


def test_export_both_formats_rechecks_and_preserves_the_same_zip(setup):
    args, calls = setup
    _, zip_archive, zip_receipt = completed_release(args)
    _, dmg_archive, _ = completed_dmg(args, zip_receipt)
    lr.execute(args)
    destination = Path(args.destination)
    assert {p.name for p in destination.iterdir()} == {zip_archive.name, dmg_archive.name, 'SHA256SUMS'}
    for archive in (zip_archive, dmg_archive):
        assert (destination / archive.name).read_bytes() == archive.read_bytes()
        assert f'{lr.sha256(archive)}  {archive.name}\n' in (destination / 'SHA256SUMS').read_text()
    assert len(calls) == 2 and all('verify-release' in call for call in calls)
    assert calls[1][1].endswith('dmg_release.py')


@pytest.mark.parametrize('field,value', [('source_zip_sha256', '0'*64), ('version', '0.16.0'),
                                        ('source_commit', 'wrong'), ('format', 'zip')])
def test_export_rejects_a_dmg_from_a_different_release(setup, field, value):
    args, _ = setup
    _, _, zip_receipt = completed_release(args)
    output, _, receipt = completed_dmg(args, zip_receipt)
    receipt[field] = value
    (output / 'release.json').write_text(json.dumps(receipt))
    with pytest.raises(ValueError, match='same release'):
        lr.execute(args)
    assert not Path(args.destination).exists()


def test_no_final_assets_when_dmg_copy_changes(setup, monkeypatch):
    args, _ = setup
    _, zip_archive, zip_receipt = completed_release(args)
    _, dmg_archive, _ = completed_dmg(args, zip_receipt)
    original = lr.shutil.copyfile
    def corrupt(source, destination):
        original(source, destination)
        if source.suffix == '.dmg': destination.write_bytes(b'bad copy')
    monkeypatch.setattr(lr.shutil, 'copyfile', corrupt)
    with pytest.raises(ValueError, match='changed during export'):
        lr.execute(args)
    assert not (Path(args.destination) / zip_archive.name).exists()
    assert not (Path(args.destination) / dmg_archive.name).exists()
    assert not (Path(args.destination) / 'SHA256SUMS').exists()


@pytest.mark.parametrize('command,filename', [('resume','state.json'),('status','state.json'),('verify','release.json')])
def test_dmg_operations_use_the_dmg_adapter_and_saved_version(setup, command, filename):
    args, calls = setup
    output = Path(args.output)
    output.mkdir()
    (output / filename).write_text(json.dumps({'format':'dmg','version':'0.17.0','team_id':args.team_id}))
    args.command = command
    lr.execute(args)
    assert calls[0][1].endswith('dmg_release.py') and calls[0][-1] == '0.17.0'
    assert ('--resume' in calls[0]) == (command == 'resume')


def test_submit_dmg_binds_prepared_image_and_original_zip(setup):
    args, calls = setup
    source, _, zip_receipt = completed_release(args)
    zip_receipt['source_commit'] = 'a'*40
    (source / 'release.json').write_text(json.dumps(zip_receipt))
    output = source.parent / 'prepared dmg'
    output.mkdir()
    name = 'BatchAutoStraighten-0.17.0-macos-arm64.dmg'
    (output / name).write_bytes(b'signed dmg')
    receipt = {**zip_receipt, 'format':'dmg', 'archive':name, 'sha256':lr.sha256(output/name),
               'zip_release':str(source), 'source_zip_sha256':zip_receipt['sha256'],
               'installation_guide_sha256':'c'*64}
    (output/'prepared-dmg.json').write_text(json.dumps(receipt))
    args.command, args.output = 'submit-dmg', str(output)
    lr.execute(args)
    assert 'release' in calls[0] and '--zip-release' in calls[0]
    assert calls[0][1].endswith('dmg_release.py')
    calls.clear()
    (output/name).write_bytes(b'tampered')
    with pytest.raises(ValueError, match='changed'): lr.execute(args)
    assert calls == []
