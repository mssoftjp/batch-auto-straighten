import hashlib
import math
import subprocess
from pathlib import Path

import pytest
import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / '.local/development/BatchAutoStraighten.lrdevplugin/bin/horizon-helper'


@pytest.fixture(scope='module', autouse=True)
def build():
    subprocess.run(['bash', str(ROOT / 'scripts/build-horizon-helper.sh')], check=True, capture_output=True)


@pytest.mark.parametrize('size,degrees', [((1200, 800), 0), ((1200, 800), 15), ((1200, 800), -15), ((800, 1200), 25), ((800, 1200), -25)])
def test_only_crop_frame_rotates(tmp_path, size, degrees):
    w, h = size
    source = tmp_path / 'source.png'
    picture = np.full((h, w, 3), 200, dtype=np.uint8)
    # An off-center landmark detects accidental rotation of the photograph.
    cv2.circle(picture, (w//2+80, h//2), 15, (0, 0, 230), -1)
    cv2.imwrite(str(source), picture)
    original = hashlib.sha256(source.read_bytes()).hexdigest()
    output = tmp_path / 'preview.png'
    subprocess.run([str(HELPER), '--id', 'preview', '--image', str(source), '--output', str(output), '--preview-degrees', str(degrees)], check=True)
    assert hashlib.sha256(source.read_bytes()).hexdigest() == original
    result = cv2.cvtColor(cv2.imread(str(output)), cv2.COLOR_BGR2RGB)
    fit = min(700/w, 400/h)
    cw, ch = round(w*fit), round(h*fit)
    assert result.shape == (ch, cw, 3)
    # The source fills the complete bitmap, including its corners (no letterbox).
    assert result[:3, :3].min() > 80
    assert result[-3:, -3:].min() > 80
    r, g, b = result[ch//2, round(cw/2+80*cw/w)]
    assert r > 200 and g < 15 and b < 15, 'photograph landmark moved or darkened'
    # Verify a corner of the tilted white outline in source-image coordinates.
    a = math.radians(degrees)
    c, s = abs(math.cos(a)), abs(math.sin(a))
    crop_scale = min(cw/(cw*c+ch*s), ch/(cw*s+ch*c))
    x, y = cw*crop_scale/2, ch*crop_scale/2
    px = round(cw/2+x*math.cos(a)-y*math.sin(a))
    py = round(ch/2-x*math.sin(a)-y*math.cos(a))
    patch = result[max(0,py-2):min(ch,py+3), max(0,px-2):min(cw,px+3)]
    assert patch.min(axis=2).max() > 220
    if degrees:
        # Source area above the crop is darkened; the source center retains its color.
        top = result[8, cw//2]
        assert max(top) < 130
        inside = result[ch//2+5, cw//2+5]
        assert min(inside) >= 190


@pytest.mark.parametrize('angle', ['nan', 'inf', '91', '-91', 'bad'])
def test_invalid_angle_never_creates_preview(tmp_path, angle):
    output = tmp_path / 'bad.png'
    p = subprocess.run([str(HELPER), '--id', 'preview', '--image', str(ROOT/'tests/fixtures/horizon/blank.png'), '--output', str(output), '--preview-degrees', angle], capture_output=True)
    assert p.returncode != 0
    assert not output.exists()
