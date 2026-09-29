import json
from pathlib import Path

import pytest
from batch_auto_straighten import image_analysis_helper as helper
from batch_auto_straighten import image_analysis as model_api

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / '.local/development/BatchAutoStraighten.lrdevplugin'

@pytest.mark.parametrize('result,kind', [
    ({'status': 'prediction', 'ui_angle_deg': 0.0, 'elapsed_seconds': .1}, 'horizon'),
    ({'status': 'prediction', 'ui_angle_deg': -1.25, 'elapsed_seconds': .1}, 'horizon'),
    ({'status': 'abstain'}, 'none'),
])
def test_protocol_keeps_zero_and_abstention_separate(monkeypatch, result, kind):
    monkeypatch.setattr(model_api, 'predict_image', lambda *args: dict(result, geometry={'status':'candidate'}))
    payload = helper.analyze('test', Path('/unused.jpg'), BUNDLE)
    assert payload['kind'] == kind
    assert payload['source'] == 'image_analysis'
    assert payload['model_id'] == 'image-analysis-v1'
    if kind == 'horizon':
        assert payload['correction_degrees'] == result['ui_angle_deg']
        assert 'vision_degrees' not in payload


def test_missing_image_fails_without_fallback(tmp_path):
    result = helper.analyze('missing', tmp_path / 'absent.jpg', BUNDLE)
    assert result['kind'] == 'error'
    assert result['source'] == 'image_analysis'
    assert 'correction_degrees' not in result


def test_changed_runtime_fails_closed(tmp_path):
    (tmp_path / 'python').mkdir()
    (tmp_path / 'python/runtime.json').write_text(json.dumps({'opencv_version':'wrong','numpy_version':'wrong'}))
    result = helper.analyze('runtime', Path('/unused.jpg'), tmp_path)
    assert result['kind'] == 'error'
    assert result['error'] == 'image_analysis_runtime_changed'


def test_bundle_matches_frozen_model_and_extractor():
    assert (BUNDLE / 'models/image-analysis-v1.json').read_bytes() == (ROOT / 'src/batch_auto_straighten/models/image-analysis-v1.json').read_bytes()
    for source in (BUNDLE / 'python/batch_auto_straighten').glob('*.py'):
        assert source.read_bytes() == (ROOT / 'src/batch_auto_straighten' / source.name).read_bytes()


@pytest.mark.parametrize('status,disagreement,blocked', [
    ('abstain', -6.05, True), ('abstain', 6.05, True),
    ('abstain', .36, False), ('abstain', -.02, False),
    ('candidate', -4.8, False),
])
def test_guard_rejects_conflicting_weak_geometry_only(status, disagreement, blocked):
    result={'geometry': {'status': status}, 'features': {'v20_median': disagreement}}
    assert helper.conflicting_weak_geometry(result) is blocked



def test_pending_name_cannot_overwrite_image(monkeypatch, tmp_path):
    image = tmp_path / 'result.pending'
    image.write_bytes(b'original image')
    output = tmp_path / 'result'
    monkeypatch.setattr(helper, 'analyze', lambda *args: {'kind': 'none'})
    monkeypatch.setattr('sys.argv', ['helper', '--bundle', str(BUNDLE), '--id', 't',
                                   '--image', str(image), '--output', str(output)])
    helper.main()
    assert image.read_bytes() == b'original image'
    assert json.loads(output.read_text()) == {'kind': 'none'}
    assert sorted(p.name for p in tmp_path.iterdir()) == ['result', 'result.pending']


def test_pending_symlink_is_not_followed(monkeypatch, tmp_path):
    image = tmp_path / 'image.jpg'
    image.write_bytes(b'original image')
    output = tmp_path / 'result'
    output.with_suffix('.pending').symlink_to(image)
    monkeypatch.setattr(helper, 'analyze', lambda *args: {'kind': 'none'})
    monkeypatch.setattr('sys.argv', ['helper', '--bundle', str(BUNDLE), '--id', 't',
                                   '--image', str(image), '--output', str(output)])
    helper.main()
    assert image.read_bytes() == b'original image'
    assert json.loads(output.read_text()) == {'kind': 'none'}


def test_packaged_entry_arms_deadline_before_native_import(tmp_path):
    import subprocess
    import sys
    # Run the actual distributable entry with a native import stalled on purpose.
    script = '''
import builtins, runpy, signal, sys, time
from batch_auto_straighten import image_analysis_helper
image_analysis_helper.PROCESS_LIMIT_SECONDS = 1
original = builtins.__import__
def slow(name, *args, **kwargs):
    if name == 'cv2':
        assert signal.alarm(0) > 0, 'native import outside deadline'
        signal.alarm(1)
        time.sleep(10)
    return original(name, *args, **kwargs)
builtins.__import__ = slow
sys.argv = ['entry', '--id', 'slow', '--image', '/tmp/unused.jpg', '--output', sys.argv[1]]
runpy.run_path(sys.argv_entry, run_name='__main__')
'''
    script = script.replace('sys.argv_entry', repr(str(ROOT / 'src/batch_auto_straighten/entry.py')))
    result = subprocess.run([sys.executable, '-c', script, str(tmp_path / 'out.json')],
                            timeout=5, capture_output=True, text=True)
    import signal
    assert result.returncode == -signal.SIGALRM, result.stderr
    assert not (tmp_path / 'out.json').exists()
