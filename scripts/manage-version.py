"""Read, validate, or update the stable SemVer used by every release surface."""
from argparse import ArgumentParser
from pathlib import Path
import re
import tomllib

ROOT = Path(__file__).resolve().parents[1]
VERSION_RE = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)")


def versions():
    pyproject = tomllib.loads((ROOT / "pyproject.toml").read_text())
    init_text = (ROOT / "src/batch_auto_straighten/__init__.py").read_text()
    info_text = (ROOT / "src/lightroom/Info.lua").read_text()
    return {
        "pyproject.toml": pyproject["project"]["version"],
        "src/batch_auto_straighten/__init__.py": re.search(
            r'^__version__ = "([^"]+)"$', init_text, re.MULTILINE).group(1),
        "src/lightroom/Info.lua": re.search(
            r'display = "([^"]+)"', info_text).group(1),
    }


def current_version():
    found = versions()
    unique = set(found.values())
    if len(unique) != 1:
        details = ", ".join(f"{name}={version}" for name, version in found.items())
        raise SystemExit(f"Version mismatch: {details}")
    version = unique.pop()
    if VERSION_RE.fullmatch(version) is None:
        raise SystemExit(f"Version is not stable SemVer: {version}")
    return version


def replace_once(path, pattern, replacement):
    text = path.read_text()
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit(f"Expected one version field in {path.relative_to(ROOT)}")
    return updated


def set_version(version):
    if VERSION_RE.fullmatch(version) is None:
        raise SystemExit("Version must be stable SemVer: MAJOR.MINOR.PATCH")
    major, minor, patch = version.split(".")
    updates = {
        ROOT / "pyproject.toml": replace_once(
            ROOT / "pyproject.toml", r'^version = "[^"]+"$', f'version = "{version}"'),
        ROOT / "src/batch_auto_straighten/__init__.py": replace_once(
            ROOT / "src/batch_auto_straighten/__init__.py",
            r'^__version__ = "[^"]+"$', f'__version__ = "{version}"'),
        ROOT / "src/lightroom/Info.lua": replace_once(
            ROOT / "src/lightroom/Info.lua",
            r'VERSION = \{ major = [0-9]+, minor = [0-9]+, revision = [0-9]+, display = "[^"]+" \}',
            f'VERSION = {{ major = {major}, minor = {minor}, revision = {patch}, display = "{version}" }}'),
    }
    for path, text in updates.items():
        path.write_text(text)
    current_version()


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("version", nargs="?", help="new MAJOR.MINOR.PATCH")
    parser.add_argument("--check", action="store_true", help="validate without changing files")
    args = parser.parse_args()
    if args.check and args.version:
        parser.error("--check cannot be combined with a new version")
    if args.version:
        set_version(args.version)
    print(current_version())


if __name__ == "__main__":
    main()
