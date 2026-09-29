"""Assemble the local development plug-in from public source files."""
from pathlib import Path
import os
import shutil
import subprocess
import sys

from release_privacy import ignored_source_files

ROOT = Path(__file__).resolve().parents[1]
LIGHTROOM_SOURCE = ROOT / 'src/lightroom'
DEVELOPMENT_BUNDLE = ROOT / '.local/development/BatchAutoStraighten.lrdevplugin'


def copy_lightroom_sources(bundle):
    """Copy the source directory using the repository's Git ignore rules."""
    sources = {path.relative_to(ROOT).as_posix(): path
               for path in LIGHTROOM_SOURCE.rglob('*') if path.is_file() or path.is_symlink()}
    rules = {'.gitignore': ROOT / '.gitignore', **sources}
    parent_rules = LIGHTROOM_SOURCE.parent / '.gitignore'
    if parent_rules.is_file():
        rules[parent_rules.relative_to(ROOT).as_posix()] = parent_rules
    ignored = ignored_source_files(rules, lambda name: rules[name].read_bytes())
    bundle.mkdir(parents=True, exist_ok=True)
    for name, source in sorted(sources.items()):
        if name in ignored or source.name == '.gitignore':
            continue
        if source.is_symlink():
            raise ValueError('Lightroom source files must not be symlinks')
        target = bundle / source.relative_to(LIGHTROOM_SOURCE)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def main():
    copy_lightroom_sources(DEVELOPMENT_BUNDLE)
    for name in ('LICENSE', 'NOTICE', 'README.md'):
        shutil.copy2(ROOT / name, DEVELOPMENT_BUNDLE / name)
    env = dict(os.environ, PYTHONPATH=str(ROOT / 'src'))
    subprocess.run([sys.executable, str(ROOT / 'scripts/build-image-analysis-helper.py'),
                    str(DEVELOPMENT_BUNDLE)], check=True, env=env)
    subprocess.run(['bash', str(ROOT / 'scripts/build-horizon-helper.sh'),
                    str(DEVELOPMENT_BUNDLE)], check=True)
    print(f'Development plug-in: {DEVELOPMENT_BUNDLE}')


if __name__ == '__main__':
    main()
