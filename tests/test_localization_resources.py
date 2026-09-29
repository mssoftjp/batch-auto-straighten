"""Verify UI translation completeness and printf compatibility."""
from pathlib import Path
import re

PLUGIN = Path(__file__).parents[1] / 'src' / 'lightroom'


def dictionary(language):
    result = {}
    for line in (PLUGIN / f'TranslatedStrings_{language}.txt').read_text(encoding='utf-8-sig').splitlines():
        match = re.fullmatch(r'"([^=]+)=(.*)"', line)
        assert match, line
        key, value = match.groups()
        assert key not in result, key
        result[key] = value
    return result


def formats(value):
    return re.findall(r'%(?!%)[-+ #0]*\d*(?:\.\d+)?[diouxXeEfgGqs]', value)


def test_languages_have_matching_keys_and_format_arguments():
    ja, en = dictionary('ja'), dictionary('en')
    assert ja.keys() == en.keys()
    assert ja['$$$/BatchAutoStraighten/Text069'] == 'カラーラベル'
    assert en['$$$/BatchAutoStraighten/Text069'] == 'Color label'
    for key in ja:
        assert formats(ja[key]) == formats(en[key]), key


def test_every_localized_literal_has_both_translations():
    ja, en = dictionary('ja'), dictionary('en')
    count = 0
    for path in PLUGIN.glob('*.lua'):
        for key, fallback in re.findall(r'LOC\("([^=]+)=((?:\\.|[^"\\])*)"\)', path.read_text()):
            assert key in ja and key in en, (path.name, key)
            assert en[key] == fallback, (path.name, key)
            count += 1
    assert count > 100


def test_translation_dictionaries_contain_only_used_keys():
    used = set()
    for path in PLUGIN.glob('*.lua'):
        used.update(re.findall(r'LOC\("([^=]+)=', path.read_text()))
    assert used == dictionary('en').keys()
