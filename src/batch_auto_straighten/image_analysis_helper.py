"""Bounded JSON adapter from local image analysis to Lightroom Classic."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import signal
import tempfile
from time import perf_counter

SCHEMA = "batch-auto-straighten.horizon.v2"
PROCESS_LIMIT_SECONDS = 15
# Weak vanishing-point fits must agree with the robust vertical-line center.
# Two degrees is a conservative disagreement bound, not a desired output angle.
WEAK_GEOMETRY_MAX_MEDIAN_DISAGREEMENT_DEG = 2.0


def conflicting_weak_geometry(result: dict) -> bool:
    geometry = result["geometry"]
    if geometry["status"] != "abstain":
        return False
    features = result.get("features")
    if features is None:
        return True
    # v20_median is stored relative to the vanishing-point diagnostic angle.
    return abs(features["v20_median"]) > WEAK_GEOMETRY_MAX_MEDIAN_DISAGREEMENT_DEG

def analyze(photo_id: str, image: Path, bundle: Path) -> dict:
    started = perf_counter()
    timing = {}
    payload = {"schema": SCHEMA, "id": photo_id, "source": "image_analysis"}
    try:
        import cv2
        import numpy as np
        from batch_auto_straighten.image_analysis import load_model, predict_image

        timing["imports_seconds"] = perf_counter() - started
        loaded = perf_counter()
        runtime = json.loads((bundle / "python/runtime.json").read_text())
        if runtime["opencv_version"] != cv2.__version__ or runtime["numpy_version"] != np.__version__:
            raise ValueError("image_analysis_runtime_changed")
        model = load_model(bundle / "models/image-analysis-v1.json")
        timing["model_load_seconds"] = perf_counter() - loaded
        predicting = perf_counter()
        result = predict_image(model, image)
        timing["predict_seconds"] = perf_counter() - predicting
        payload["model_id"] = model["name"]
        if result["status"] == "abstain":
            payload.update(kind="none", detail="insufficient_image_analysis_evidence")
        elif conflicting_weak_geometry(result):
            payload.update(kind="none", detail="conflicting_weak_geometry")
        else:
            # The model predicts the UI correction of this already-upright preview.
            # Lightroom adds this correction to its current UI angle.
            payload.update(kind="horizon", correction_degrees=result["ui_angle_deg"],
                           elapsed_seconds=result["elapsed_seconds"])
    except Exception as exc:
        payload.update(kind="error", detail="image_analysis_failed", error=str(exc))
    timing["total_seconds"] = perf_counter() - started
    payload["timing"] = timing
    return payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    model = args.bundle / "models/image-analysis-v1.json"
    if args.output.resolve() in (args.image.resolve(), model.resolve(),
                                (args.bundle / "python/runtime.json").resolve()):
        raise ValueError("Output must not overwrite an input")
    signal.alarm(PROCESS_LIMIT_SECONDS)
    try:
        result = analyze(args.id, args.image, args.bundle)
        text = json.dumps(result, allow_nan=False) + "\n"
        # Exclusive creation avoids overwriting an input or following a link.
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8",
                                         dir=args.output.parent, delete=False) as stream:
            temp = Path(stream.name)
            try:
                stream.write(text)
                stream.close()
                temp.replace(args.output)
            finally:
                temp.unlink(missing_ok=True)
    finally:
        signal.alarm(0)


if __name__ == "__main__":
    main()
