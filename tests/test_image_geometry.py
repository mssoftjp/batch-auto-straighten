from pathlib import Path

import cv2
import numpy as np
import pytest

from batch_auto_straighten.image_geometry import estimate_segments, predict_image


def converging_lines(correction, perspective, count=70):
    rng=np.random.default_rng(12)
    x=rng.uniform(-.42,.42,count)
    y=rng.uniform(-.25,.25,count)
    t=(np.tan(np.radians(correction))-perspective*x)/(1-perspective*y)
    # Deliberately denser on the left: uncentered averages should be wrong.
    half=rng.uniform(.03,.09,count)
    return np.column_stack([x-t*half,y-half,x+t*half,y+half])*1000+[500,350,500,350]


@pytest.mark.parametrize('angle,perspective',[(2,.18),(-3,-.12),(0,0),(1.5,0)])
def test_recovers_center_direction_despite_perspective_and_outliers(angle,perspective):
    lines=converging_lines(angle,perspective)
    outliers=converging_lines(angle+7,-perspective,count=18)
    estimate=estimate_segments(np.vstack([lines,outliers]),(700,1000))
    assert estimate.status=='candidate'
    assert estimate.angle_deg==pytest.approx(angle,abs=.03)
    assert estimate.inverse_vp_distance==pytest.approx(perspective,abs=.003)


def test_known_clockwise_rotation_changes_correction_with_opposite_sign():
    lines=converging_lines(1,.1)
    theta=np.radians(3)
    rotation=np.array([[np.cos(theta),-np.sin(theta)],[np.sin(theta),np.cos(theta)]])
    points=lines.reshape(-1,2)-[500,350]
    rotated=(points@rotation.T+[500,350]).reshape(-1,4)
    result=estimate_segments(rotated,(700,1000))
    assert result.angle_deg==pytest.approx(-2,abs=.03)


def test_blank_and_narrow_evidence_abstain(tmp_path: Path):
    path=tmp_path/'blank.png'
    cv2.imwrite(str(path),np.full((700,1000),128,np.uint8))
    assert predict_image(path).angle_deg is None
    lines=converging_lines(1,0)
    lines[:,[0,2]]=(lines[:,[0,2]]-500)*.05+500
    assert estimate_segments(lines,(700,1000)).status=='abstain'


def test_real_raster_detection_and_sign(tmp_path: Path):
    path=tmp_path/'perspective.png'
    image=np.full((700,1000),240,np.uint8)
    for line in converging_lines(-2,.08):
        a,b=np.round(line.reshape(2,2)).astype(int)
        cv2.line(image,tuple(a),tuple(b),20,2,cv2.LINE_AA)
    cv2.imwrite(str(path),image)
    result=predict_image(path)
    assert result.status=='candidate'
    assert result.angle_deg==pytest.approx(-2,abs=.15)


def test_rejects_nonfinite_lines():
    with pytest.raises(ValueError):
        estimate_segments(np.array([[0,0,float('nan'),10]]),(100,100))
