"""Build the local image-analysis adapter from the checked-out source."""
import os
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope='session', autouse=True)
def image_analysis_runtime():
    env = dict(os.environ, PYTHONPATH=str(ROOT / 'src'))
    subprocess.run([sys.executable, str(ROOT / 'scripts/build-image-analysis-helper.py')],
                   check=True, cwd=ROOT, env=env, timeout=30)
