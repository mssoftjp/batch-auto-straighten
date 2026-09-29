"""Bundle the image-analysis model and adapter for this Lightroom install.

Uses the invoking virtual environment; does not download/install dependencies.
Rebuild after moving the environment or changing its NumPy/OpenCV versions.
"""
import argparse
import json
from pathlib import Path
import shlex
import shutil
import sys

import cv2
import numpy as np
from batch_auto_straighten.image_analysis import load_model
from build_plugin import DEVELOPMENT_BUNDLE

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = DEVELOPMENT_BUNDLE
SOURCE_MODEL = ROOT / "src/batch_auto_straighten/models/image-analysis-v1.json"


def build(bundle=BUNDLE):
    model = load_model(SOURCE_MODEL)
    package = bundle / "python/batch_auto_straighten"
    package.mkdir(parents=True, exist_ok=True)
    module_names = ("__init__.py", "image_analysis_helper.py", "image_analysis.py",
                    "image_features.py", "image_geometry.py")
    for stale in package.glob("*.py"):
        if stale.name not in module_names:
            stale.unlink()
    for name in module_names:
        shutil.copy2(ROOT / "src/batch_auto_straighten" / name, package / name)
    (bundle / "models").mkdir(exist_ok=True)
    shutil.copy2(SOURCE_MODEL, bundle / "models/image-analysis-v1.json")
    entry = bundle / "python/image_analysis_entry.py"
    entry.write_text(
        "from pathlib import Path\nimport sys\n"
        "sys.path.insert(0, str(Path(__file__).resolve().parent))\n"
        "from batch_auto_straighten.image_analysis_helper import main\nmain()\n")
    (bundle / "python/runtime.json").write_text(json.dumps({
        "opencv_version": cv2.__version__, "numpy_version": np.__version__,
        "model_id": model["name"], "python_executable": sys.executable,
    }, indent=2) + "\n")
    launcher = bundle / "bin/image-analysis-helper"
    launcher.parent.mkdir(exist_ok=True)
    launcher.write_text(
        '#!/bin/sh\nset -eu\n'
        'BUNDLE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)\n'
        'exec ' + shlex.quote(sys.executable) +
        ' -I "$BUNDLE_DIR/python/image_analysis_entry.py" --bundle "$BUNDLE_DIR" "$@"\n')
    launcher.chmod(0o755)
    print(launcher)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', nargs='?', type=Path, default=BUNDLE)
    build(parser.parse_args().bundle)
