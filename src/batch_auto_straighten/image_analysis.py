"""Load and run the production image-analysis model on a local preview."""
from __future__ import annotations

from dataclasses import asdict
import hashlib
import json
import math
from pathlib import Path
import time

from batch_auto_straighten import image_features, image_geometry

SCHEMA = "batch-auto-straighten.image-analysis-model.v1"


def load_model(path: Path) -> dict:
    model = json.loads(path.read_text(encoding="utf-8"))
    if model.get("schema") != SCHEMA or model.get("feature_version") != image_features.FEATURE_VERSION:
        raise ValueError("Unsupported image-analysis model contract")
    for module, field in ((image_features, "feature_implementation_sha256"),
                          (image_geometry, "geometry_implementation_sha256")):
        actual = hashlib.sha256(Path(module.__file__).read_bytes()).hexdigest()
        if actual != model.get(field):
            raise ValueError("Image-analysis implementation changed")
    if model.get("geometry_config") != image_geometry.CONFIG:
        raise ValueError("Image-analysis geometry configuration changed")
    caps = model.get("orientation_caps_deg")
    if (not isinstance(caps, list) or not caps or
            any(value not in (10, 20, 30) for value in caps) or len(caps) != len(set(caps))):
        raise ValueError("Unsupported orientation cap")
    names = model.get("feature_names", [])
    if not names or len(names) != len(set(names)) or set(names) != set(model.get("coefficients", {})):
        raise ValueError("Invalid model coefficients")
    values = [model.get("intercept")] + list(model["coefficients"].values())
    if not all(isinstance(value, (float, int)) and math.isfinite(value) for value in values):
        raise ValueError("Non-finite model coefficients")
    return model


def predict_features(model: dict, features: dict) -> float:
    names = model["feature_names"]
    if not all(name in features and math.isfinite(features[name]) for name in names):
        raise ValueError("Missing or non-finite model feature")
    angle = float(features["vertical_deg"] + model["intercept"]
                  + sum(model["coefficients"][name] * features[name] for name in names))
    if not math.isfinite(angle):
        raise ValueError("Non-finite model prediction")
    return angle


def predict_image(model: dict, image_path: Path) -> dict:
    start = time.perf_counter()
    features, geometry = image_features.analysis_features(image_path, model["orientation_caps_deg"])
    angle = predict_features(model, features) if features is not None else None
    status = "prediction" if angle is not None and abs(angle) <= 15 else "abstain"
    return {"schema": SCHEMA, "model": model["name"], "status": status,
            "ui_angle_deg": angle if status == "prediction" else None,
            "diagnostic_angle_deg": angle, "geometry": asdict(geometry),
            "features": features, "elapsed_seconds": time.perf_counter() - start}
