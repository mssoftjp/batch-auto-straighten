from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "src" / "lightroom"


def _read(name: str) -> str:
    return (PLUGIN / name).read_text(encoding="utf-8")


def test_project_is_mit_with_third_party_notice():
    license_text = (ROOT / "LICENSE").read_text(encoding="utf-8")
    assert "MIT License" in license_text
    assert "Copyright (c) 2026 mssoft.jp" in license_text
    notice = (ROOT / "NOTICE").read_text(encoding="utf-8")
    assert "Copyright (C) 2010-2026 David Heiko Kolf" in notice
    assert "License: MIT" in notice
    assert "not bundled" in notice.lower() or "optional" in notice.lower()


def test_dkjson_version_and_license_are_pinned():
    text = _read("dkjson.lua")
    assert "Version 2.11" in text
    assert "dkjson 2.11" in text
    assert "Copyright (C) 2010-2026 David Heiko Kolf" in text
    assert "Permission is hereby granted" in text


def test_info_lua_exposes_plugin_extras_menu():
    text = _read("Info.lua")
    assert "LrExportMenuItems" in text
    assert 'title = "Batch Auto Straighten"' in text
    assert "BatchAutoStraighten.lua" in text
    assert "jp.mssoft.lightroom.batchautostraighten" in text


def test_plugin_manager_shows_guidance_and_project_links():
    info = _read("Info.lua")
    provider = _read("PluginInfoProvider.lua")
    repository_url = "https://github.com/mssoftjp/batch-auto-straighten"
    assert 'LrPluginInfoProvider = "PluginInfoProvider.lua"' in info
    assert f'LrPluginInfoUrl = "{repository_url}"' in info
    assert "sectionsForTopOfDialog" in provider
    assert "Info.VERSION.display" in provider
    assert f'REPOSITORY_URL = "{repository_url}"' in provider
    assert 'RELEASES_URL = REPOSITORY_URL .. "/releases"' in provider
    assert provider.count("Http.openUrlInBrowser") == 2


def test_python_and_plugin_versions_match():
    import tomllib
    from batch_auto_straighten import __version__
    root = Path(__file__).resolve().parents[1]
    assert __version__ == tomllib.loads((root / 'pyproject.toml').read_text())['project']['version']
    assert __version__ in _read('Info.lua')
