from pathlib import Path
import importlib.util
import re

ROOT = Path(__file__).resolve().parents[1]


def _version_module():
    spec = importlib.util.spec_from_file_location(
        "manage_version", ROOT / "scripts/manage-version.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_release_versions_are_in_sync():
    versioning = _version_module()
    version = versioning.current_version()
    assert versioning.VERSION_RE.fullmatch(version)


def test_unsigned_workflow_cannot_publish_a_release():
    workflow = (ROOT / ".github/workflows/release.yml").read_text()
    assert 'test "$GITHUB_REF_NAME" = "v$version"' in workflow
    assert 'git merge-base --is-ancestor "$GITHUB_SHA" origin/main' in workflow
    assert "python scripts/check-publication.py" in workflow
    assert "workflow_dispatch:" in workflow
    assert "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a" in workflow
    assert "UNSIGNED-TEST-ONLY-" in workflow
    assert "contents: read" in workflow
    assert "push:" not in workflow
    assert ": write" not in workflow
    assert "gh release" not in workflow
    assert "actions/attest@" not in workflow


def test_ci_covers_every_lua_test_and_publication_boundary():
    workflow = (ROOT / ".github/workflows/ci.yml").read_text()
    assert "tests/*.lua" in workflow
    assert "lua-5.1.5.tar.gz" in workflow
    assert "2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333" in workflow
    assert "runs-on: macos-26" in workflow
    assert "-e '.[dev,package]'" in workflow
    assert "python scripts/check-publication.py" in workflow
    assert "bash scripts/build-horizon-helper.sh" in workflow
    assert "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1" in workflow
    assert not re.search(r"secrets\.[A-Za-z0-9_]+", workflow)
