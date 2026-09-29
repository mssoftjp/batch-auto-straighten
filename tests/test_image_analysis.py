import json
from pathlib import Path

import cv2
import numpy as np
import pytest

from batch_auto_straighten.image_analysis import load_model, predict_features, predict_image
from batch_auto_straighten.image_features import line_distributions

ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / "src/batch_auto_straighten/models/image-analysis-v1.json"


def test_blank_image_abstains_without_modification(tmp_path):
    path = tmp_path / "blank.png"
    cv2.imwrite(str(path), np.zeros((400, 600), dtype=np.uint8))
    original = path.read_bytes()
    result = predict_image(load_model(MODEL), path)
    assert result["status"] == "abstain"
    assert result["ui_angle_deg"] is None
    assert path.read_bytes() == original


def test_stale_feature_contract_is_rejected(tmp_path):
    model = json.loads(MODEL.read_text())
    model["feature_implementation_sha256"] = "0" * 64
    path = tmp_path / "model.json"
    path.write_text(json.dumps(model))
    with pytest.raises(ValueError, match="implementation changed"):
        load_model(path)


def test_model_contract_and_coefficients():
    model = load_model(ROOT / "src/batch_auto_straighten/models/image-analysis-v1.json")
    assert model["orientation_caps_deg"] == [10, 20, 30]
    assert len(model["coefficients"]) == 21
    features = dict.fromkeys(model["feature_names"], 0.0)
    assert predict_features(model, features) == model["intercept"]


def test_image_line_distribution_has_correction_sign():
    image = np.zeros((600, 800), dtype=np.uint8)
    for y in range(60, 500, 60):
        cv2.line(image, (50, y), (750, y + 25), 255, 2)
    result = line_distributions(image)
    expected = -np.degrees(np.arctan2(25, 700))
    assert result["h10_median"] == pytest.approx(expected, abs=0.1)


def test_prediction_uses_only_declared_features():
    model = load_model(MODEL)
    features = dict.fromkeys(model["feature_names"], 0.2)
    a = predict_features(model, features)
    features["unrelated_value"] = -9999
    assert predict_features(model, features) == a
    features[model["feature_names"][0]] = float("nan")
    with pytest.raises(ValueError, match="non-finite"):
        predict_features(model, features)
