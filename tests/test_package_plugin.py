"""Local ZIP packaging and opt-in Developer ID signing preserve existing products."""
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]


def _load_packager():
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        'package_plugin', ROOT / 'scripts/package-plugin.py')
    packager = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packager)
    return packager


def test_distribution_names_follow_project_conventions():
    packager = _load_packager()
    assert packager.PLUGIN_STEM == 'BatchAutoStraighten'
    assert packager.LIGHTROOM_SOURCE == ROOT / 'src/lightroom'
    assert packager.DISTRIBUTION_BUNDLE_NAME == 'BatchAutoStraighten.lrplugin'
    assert packager.distribution_archive_name('0.18.0', 'arm64') == (
        'BatchAutoStraighten-0.18.0-macos-arm64.zip')
    readme = (ROOT / 'README.md').read_text(encoding='utf-8')
    assert 'Batch Auto Straighten.lrplugin' not in readme
    assert packager.DISTRIBUTION_BUNDLE_NAME in readme


def test_prepare_build_directory_removes_stale_products(tmp_path):
    packager = _load_packager()
    work = tmp_path / 'package-build' / 'arm64'
    stale_bundle = work / 'Batch Auto Straighten.lrplugin'
    stale_bundle.mkdir(parents=True)
    (work / 'regression-runtime.spec').write_text('stale\n')
    (work / '.DS_Store').write_text('finder metadata\n')

    packager.prepare_build_directory(work)

    assert work.is_dir()
    assert [path.name for path in work.iterdir()] == ['.DS_Store']


def test_assembly_copies_only_public_lightroom_sources(tmp_path, monkeypatch):
    _load_packager()
    import build_plugin
    root = tmp_path / 'checkout'
    source = root / 'src/lightroom'
    source.mkdir(parents=True)
    (source / 'Info.lua').write_text('return {}\n')
    (source / 'TranslatedStrings_ja.txt').write_text('translation fixture\n')
    (source / 'local-note.txt').write_text('local work\n')
    (source / 'Resources').mkdir()
    (source / 'Resources/link.pdf').write_text('vector resource fixture\n')
    (source / 'Resources/private.pdf').write_text('local work\n')
    (source / 'Resources/.gitignore').write_text('private.pdf\n')
    (source / 'NewModule.lua').write_text('return {}\n')
    (source / '__pycache__').mkdir()
    (source / '__pycache__/cache.pyc').write_bytes(b'cache')
    (root / '.gitignore').write_text(
        '/*\n!/src/\n**/__pycache__/\n/src/lightroom/local-note.txt\n')
    monkeypatch.setattr(build_plugin, 'ROOT', root)
    monkeypatch.setattr(build_plugin, 'LIGHTROOM_SOURCE', source)
    bundle = tmp_path / 'product.lrplugin'
    build_plugin.copy_lightroom_sources(bundle)
    paths = sorted(path.relative_to(bundle).as_posix() for path in bundle.rglob('*') if path.is_file())
    assert paths == ['Info.lua', 'NewModule.lua', 'Resources/link.pdf', 'TranslatedStrings_ja.txt']
    for name in paths:
        assert (bundle / name).read_bytes() == (source / name).read_bytes()
    (root / '.gitignore').unlink()
    with pytest.raises(FileNotFoundError):
        build_plugin.copy_lightroom_sources(tmp_path / 'missing-rules.lrplugin')


def test_packaging_cli_separates_optional_signing_from_notarization():
    result = subprocess.run(
        [sys.executable, str(ROOT / 'scripts/package-plugin.py'), '--help'],
        capture_output=True, text=True,
    )
    assert result.returncode == 0
    assert 'zip' in result.stdout.lower()
    assert 'signing-identity' in result.stdout
    assert 'work-dir' in result.stdout
    assert 'output-dir' in result.stdout
    assert 'notary-profile' not in result.stdout
    assert 'development-only' not in result.stdout


def test_runtime_dependencies_are_present_in_assembled_bundle(tmp_path):
    import re

    packager = _load_packager()
    bundle = tmp_path / 'BatchAutoStraighten.lrplugin'
    packager.copy_lightroom_sources(bundle)
    modules = {path.name for path in bundle.glob('*.lua')}
    assert {'Info.lua', 'BatchAutoStraighten.lua', 'PluginInfoProvider.lua'} <= modules
    for name in modules:
        # Covers module loads and the menu/provider entry points in Info.lua.
        dependencies = re.findall(r'["\']/?([A-Za-z0-9_]+\.lua)["\']',
                                  (bundle / name).read_text())
        assert set(dependencies) <= modules, (name, set(dependencies) - modules)
    for name in ('TranslatedStrings_en.txt', 'TranslatedStrings_ja.txt',
                 'Resources/AngleLimitsLinked.pdf', 'Resources/AngleLimitsSeparate.pdf'):
        assert (bundle / name).read_bytes() == (packager.LIGHTROOM_SOURCE / name).read_bytes()


@pytest.mark.parametrize('directory', ['Batch Auto Straighten', "日本語's source"])
def test_prefix_map_flag_survives_cmake_compiler_command(tmp_path, directory):
    import importlib.util
    spec = importlib.util.spec_from_file_location('opencv_build', ROOT / 'scripts/build-minimal-opencv.py')
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    source = tmp_path / directory
    source.mkdir()
    (source / 'CMakeLists.txt').write_text('cmake_minimum_required(VERSION 3.20)\nproject(quote_test C CXX)\nadd_executable(quote_test main.cpp)\n')
    (source / 'main.cpp').write_text('#include <cstdio>\nint main(){puts(__FILE__);}\n')
    cmake = Path(sys.executable).parent / 'cmake'
    flag = builder.prefix_map_flag(source)
    build = tmp_path / 'build'
    subprocess.run([str(cmake), '-S', str(source), '-B', str(build),
                    '-DCMAKE_C_FLAGS=' + flag, '-DCMAKE_CXX_FLAGS=' + flag], check=True, capture_output=True)
    subprocess.run([str(cmake), '--build', str(build)], check=True, capture_output=True)
    result = subprocess.run([str(build / 'quote_test')], check=True, capture_output=True, text=True)
    assert result.stdout.strip() == '/build/batch-auto-straighten/main.cpp'


def test_signing_requires_a_developer_id_identity():
    packager = _load_packager()
    assert packager.signing_options(None) == []
    identity = 'Developer ID Application: Example'
    assert packager.signing_options(identity) == ['--codesign-identity', identity]
    for bad in ('', '-', 'Apple Development: Example'):
        with pytest.raises(ValueError, match='Developer ID'):
            packager.signing_options(bad)


def test_signed_build_requires_isolated_output_before_importing_dependencies(tmp_path, monkeypatch):
    monkeypatch.delenv('GITHUB_ACTIONS', raising=False)
    result = subprocess.run([sys.executable, str(ROOT / 'scripts/package-plugin.py'),
                             '--signing-identity', 'Developer ID Application: Example'],
                            cwd=tmp_path, capture_output=True, text=True)
    assert result.returncode == 2
    assert 'new --work-dir and --output-dir' in result.stderr
    assert list(tmp_path.iterdir()) == []


def test_hosted_signing_is_rejected_before_build_dependencies(tmp_path):
    import os
    result = subprocess.run(
        [sys.executable, str(ROOT / 'scripts/package-plugin.py'), '--signing-identity',
         'Developer ID Application: Example', '--work-dir', str(tmp_path / 'build'),
         '--output-dir', str(tmp_path / 'package')],
        env={**os.environ, 'GITHUB_ACTIONS': 'true'}, capture_output=True, text=True,
    )
    assert result.returncode == 2
    assert 'local-only' in result.stderr
    assert list(tmp_path.iterdir()) == []
