"""Build a self-contained macOS .lrplugin zip; optionally sign native components."""
from importlib.metadata import distribution
import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import sysconfig

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from release_privacy import check_bundle
from build_plugin import LIGHTROOM_SOURCE, copy_lightroom_sources
MINIMAL_CV = ROOT / '.local/opencv-minimal/install/python'
PLUGIN_STEM = 'BatchAutoStraighten'
DISTRIBUTION_BUNDLE_NAME = f'{PLUGIN_STEM}.lrplugin'


def distribution_archive_name(version, arch):
    return f'{PLUGIN_STEM}-{version}-macos-{arch}.zip'


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def prepare_build_directory(path):
    """Remove stale build products without replacing the watched directory itself."""
    path.mkdir(parents=True, exist_ok=True)
    for child in path.iterdir():
        # macOS may recreate this while an Open panel is displaying the folder.
        if child.name == '.DS_Store':
            continue
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink()


def signing_options(identity):
    if identity is None:
        return []
    if not (identity.startswith('Developer ID Application:') or re.fullmatch(r'[A-Fa-f0-9]{40}', identity)):
        raise ValueError('An explicit Developer ID Application identity is required')
    return ['--codesign-identity', identity]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--signing-identity', help='Developer ID Application identity; omission keeps local ad-hoc packaging')
    parser.add_argument('--work-dir', type=Path, help='New build directory; never replaces the active Lightroom copy')
    parser.add_argument('--output-dir', type=Path, help='New directory for the ZIP (default: out/unsigned)')
    args = parser.parse_args()
    try:
        signing = signing_options(args.signing_identity)
    except ValueError as error:
        parser.error(str(error))
    if signing and os.environ.get('GITHUB_ACTIONS') == 'true':
        parser.error('Developer ID signing is local-only; do not use hosted workflow credentials')
    if signing and (args.work_dir is None or args.output_dir is None):
        parser.error('Signed packaging requires new --work-dir and --output-dir paths')
    sys.path.insert(0, str(MINIMAL_CV))
    import cv2
    import numpy as np
    if sys.platform != 'darwin':
        raise SystemExit('Build this package on macOS')
    if not Path(cv2.__file__).resolve().is_relative_to(MINIMAL_CV.resolve()):
        raise SystemExit('Run scripts/build-minimal-opencv.py first')
    arch = platform.machine()
    if arch not in ('arm64', 'x86_64'):
        raise SystemExit('Unsupported CPU architecture')
    version = re.search(r'display = "([0-9.]+)"',
                        (LIGHTROOM_SOURCE / 'Info.lua').read_text()).group(1)
    work = args.work_dir.resolve() if args.work_dir else ROOT / '.local' / 'package-build' / arch
    output = args.output_dir.resolve() if args.output_dir else ROOT / 'out' / 'unsigned'
    if args.output_dir:
        output.mkdir(parents=True, exist_ok=False)
    if args.work_dir:
        work.mkdir(parents=True, exist_ok=False)
    else:
        prepare_build_directory(work)
    bundle = work / DISTRIBUTION_BUNDLE_NAME
    bundle.mkdir()
    copy_lightroom_sources(bundle)
    for name in ('LICENSE', 'NOTICE', 'README.md'):
        shutil.copy2(ROOT / name, bundle / name)
    run('bash', ROOT / 'scripts/build-horizon-helper.sh', bundle)
    if signing:
        run('/usr/bin/codesign', '--force', '--sign', args.signing_identity, '--timestamp',
            '--options', 'runtime', '--identifier', 'jp.mssoft.lightroom.batchautostraighten.horizon-helper',
            bundle / 'bin/horizon-helper')
    spec = importlib.util.spec_from_file_location('image_analysis_build', ROOT / 'scripts/build-image-analysis-helper.py')
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    builder.build(bundle)
    # The distributable records versions only, never the developer's Python path.
    (bundle / 'python/runtime.json').write_text(json.dumps({
        'opencv_version': cv2.__version__, 'numpy_version': np.__version__,
        'model_id': 'image-analysis-v1', 'runtime': 'bundled',
    }, indent=2) + '\n')
    env = dict(os.environ, PYINSTALLER_CONFIG_DIR=str(work / 'cache'),
               PYTHONPATH=os.pathsep.join((str(MINIMAL_CV), str(ROOT / 'src'))))
    run(sys.executable, '-m', 'PyInstaller', '--noconfirm', '--clean', '--onedir',
        '--name', 'image-analysis-runtime', '--distpath', work / 'frozen',
        '--workpath', work / 'build', '--specpath', work,
        '--exclude-module', 'batch_auto_straighten', '--exclude-module', 'pytest',
        '--exclude-module', 'tkinter', '--exclude-module', 'scipy',
        '--exclude-module', 'matplotlib',
        '--paths', MINIMAL_CV,
        '--hidden-import=cv2', '--hidden-import=numpy', *signing,
        ROOT / 'src/batch_auto_straighten/entry.py', env=env, cwd=ROOT)
    shutil.copytree(work / 'frozen/image-analysis-runtime', bundle / 'bin/image-analysis-runtime', symlinks=True)
    if signing:
        # PyInstaller collects the framework resources after signing the Python
        # binary. Seal the assembled framework so strict resource validation passes.
        run('/usr/bin/codesign', '--force', '--sign', args.signing_identity, '--timestamp',
            '--options', 'runtime', bundle / 'bin/image-analysis-runtime/_internal/Python.framework')
    launcher = bundle / 'bin/image-analysis-helper'
    launcher.write_text('#!/bin/sh\nset -eu\n'
                        'HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\n'
                        'exec "$HERE/image-analysis-runtime/image-analysis-runtime" "$@"\n')
    launcher.chmod(0o755)
    licenses = bundle / 'licenses'
    licenses.mkdir()
    # PyInstaller also collects native dependencies of Python's standard library.
    # Keep their notices even when a particular Python build omits a dependency.
    native_licenses = licenses / 'native-runtime'
    native_licenses.mkdir()
    for name in ('zstandard-LICENSE.txt', 'mpdecimal-COPYRIGHT.txt'):
        shutil.copy2(ROOT / 'licenses' / name, native_licenses / name)
    for name in ('numpy', 'pyinstaller'):
        dist = distribution(name)
        for entry in dist.files or []:
            if any(word in Path(entry).name.lower() for word in ('license', 'copying', 'copyright')):
                target = licenses / name / entry
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(dist.locate_file(entry), target)
    shutil.copy2(Path(sysconfig.get_path('stdlib')) / 'LICENSE.txt', licenses / 'Python-LICENSE.txt')
    cv_source = ROOT / '.local/opencv-source/opencv-5.0.0'
    shutil.copytree(MINIMAL_CV.parent / 'share/licenses/opencv5', licenses / 'opencv-built-components')
    for name in ('LICENSE', '3rdparty/libjpeg-turbo/LICENSE.md',
                 '3rdparty/libjpeg-turbo/README.ijg', '3rdparty/libpng/LICENSE',
                 '3rdparty/zlib/LICENSE', '3rdparty/ittnotify/include/ittnotify.h',
                 'modules/flann/include/opencv2/flann.hpp',
                 'modules/flann/include/opencv2/flann/defines.h'):
        target = licenses / 'opencv' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(cv_source / name, target)
    # Validate assembled bytes, not just source or Git ignore rules.
    check_bundle(bundle)
    output.mkdir(parents=True, exist_ok=True)
    archive = output / distribution_archive_name(version, arch)
    run('ditto', '-c', '-k', '--keepParent', '--norsrc', '--noextattr', bundle, archive)
    print(f'Package: {archive}')
    print(f'Plugin: {bundle}')


if __name__ == '__main__':
    main()
