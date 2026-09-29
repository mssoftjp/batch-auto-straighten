"""Image tilt candidate from vertical-line convergence.

Public OpenCV LSD detects subpixel segments. A robust fit of t = p + c*q
estimates a homogeneous vertical vanishing point (p, 1, q), including infinity.
Coordinates are centered on the rendered image. atan(p) is the proposed UI
correction, not proof of agreement with Lightroom or physical camera roll.
No Adobe implementation is used. This module never modifies Lightroom.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np

ALGORITHM = "vertical-vp-lsd-v1"
CONFIG = {
    "long_side": 1600, "min_length_fraction": 0.025,
    "near_vertical_deg": 20.0, "max_correction_deg": 15.0,
    "max_inverse_vp_distance": 1.0, "pair_min_separation": 0.1,
    "max_pairs": 2048, "max_segments": 2048, "seed": 0,
    "residual_deg": 0.5, "iterations": 8,
    "min_inliers": 6, "min_support": 0.5, "min_x_span": 0.2,
}

@dataclass(frozen=True)
class GeometryEstimate:
    status: str
    angle_deg: float | None
    diagnostic_angle_deg: float | None
    inverse_vp_distance: float | None
    support: float
    inliers: int
    vertical_segments: int
    x_span: float
    reason: str


def detect_segments(image: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    if image is None or image.ndim != 2 or not image.size:
        raise ValueError("Expected a nonempty grayscale image")
    h,w = image.shape
    scale = min(1.0, CONFIG["long_side"] / max(h,w))
    if scale < 1:
        image = cv2.resize(image, (round(w*scale),round(h*scale)), interpolation=cv2.INTER_AREA)
    lines = cv2.createLineSegmentDetector(cv2.LSD_REFINE_STD).detect(image)[0]
    if lines is None:
        return image, np.empty((0,4))
    lines = lines.reshape(-1,4).astype(np.float64)
    length = np.linalg.norm(lines[:,2:]-lines[:,:2],axis=1)
    return image, lines[length >= max(image.shape)*CONFIG["min_length_fraction"]]


def estimate_segments(lines: np.ndarray, shape: tuple[int,int]) -> GeometryEstimate:
    """Pure geometric estimator; shape=(height,width), segments in pixel units."""
    h,w = shape
    lines = np.asarray(lines,dtype=float)
    if h <= 0 or w <= 0 or lines.ndim != 2 or lines.shape[1] != 4 or not np.all(np.isfinite(lines)):
        raise ValueError("Invalid image shape or line segments")
    d = lines[:,2:]-lines[:,:2]
    length = np.linalg.norm(d,axis=1)
    keep = (length >= max(h,w)*CONFIG["min_length_fraction"]) & (np.abs(d[:,0]) < np.abs(d[:,1])*np.tan(np.radians(CONFIG["near_vertical_deg"])))
    lines,d,length = lines[keep],d[keep],length[keep]
    # Bound both pair enumeration and scoring memory. Stable longest-first order.
    indices = np.argsort(-length,kind="stable")[:CONFIG["max_segments"]]
    lines,d,length = lines[indices],d[indices],length[indices]
    n = len(lines)
    def unavailable(reason):
        return GeometryEstimate("abstain",None,None,None,0,0,n,0,reason)
    if n < CONFIG["min_inliers"]:
        return unavailable("insufficient_vertical_segments")
    mid = ((lines[:,:2]+lines[:,2:])/2-[w/2,h/2])/max(h,w)
    t = d[:,0]/d[:,1]
    c = -mid[:,0]+t*mid[:,1]
    weights = np.minimum(length/max(h,w),0.2)
    ii,jj = np.triu_indices(n,1)
    separated = np.abs(c[ii]-c[jj]) > CONFIG["pair_min_separation"]
    ii,jj = ii[separated],jj[separated]
    if len(ii)>CONFIG["max_pairs"]:
        chosen = np.random.default_rng(CONFIG["seed"]).choice(len(ii),CONFIG["max_pairs"],replace=False)
        ii,jj = ii[chosen],jj[chosen]
    q = (t[ii]-t[jj])/(c[ii]-c[jj])
    p = t[ii]-c[ii]*q
    p,q = np.r_[p,t],np.r_[q,np.zeros(n)]
    valid = (np.abs(p)<np.tan(np.radians(CONFIG["max_correction_deg"]))) & (np.abs(q)<CONFIG["max_inverse_vp_distance"])
    p,q = p[valid],q[valid]
    if not len(p):
        return unavailable("no_admissible_vanishing_point")
    best_score,best = -1.0,None
    threshold = CONFIG["residual_deg"]
    for start in range(0,len(p),128):
        pp,qq = p[start:start+128],q[start:start+128]
        residual = np.degrees(np.arctan(t[:,None])-np.arctan(pp[None,:]+c[:,None]*qq[None,:]))
        scores = (weights[:,None]*np.maximum(0,1-(residual/threshold)**2)).sum(axis=0)
        i = int(np.argmax(scores))
        if scores[i]>best_score:
            best_score,best = float(scores[i]),np.array([pp[i],qq[i]])
    design = np.column_stack([np.ones(n),c])
    params = best
    for _ in range(CONFIG["iterations"]):
        residual = np.degrees(np.arctan(t)-np.arctan(design@params))
        robust = weights*np.maximum(0,1-(residual/threshold)**2)**2
        weighted = design*np.sqrt(robust[:,None])
        if np.linalg.matrix_rank(weighted)<2:
            return unavailable("degenerate_spatial_support")
        params = np.linalg.lstsq(weighted,t*np.sqrt(robust),rcond=None)[0]
    residual = np.degrees(np.arctan(t)-np.arctan(design@params))
    inliers = np.abs(residual)<threshold
    support = float(weights[inliers].sum()/weights.sum())
    span = float(np.ptp(mid[inliers,0])) if inliers.any() else 0.0
    angle = float(np.degrees(np.arctan(params[0])))
    accepted = (inliers.sum()>=CONFIG["min_inliers"] and support>=CONFIG["min_support"]
                and span>=CONFIG["min_x_span"] and abs(angle)<CONFIG["max_correction_deg"]
                and abs(params[1])<CONFIG["max_inverse_vp_distance"])
    return GeometryEstimate("candidate" if accepted else "abstain",angle if accepted else None,
                            angle,float(params[1]),support,int(inliers.sum()),n,span,
                            "supported_geometry" if accepted else "insufficient_or_implausible_geometry")


def predict_image(path: Path) -> GeometryEstimate:
    image = cv2.imread(str(path),cv2.IMREAD_GRAYSCALE)
    if image is None:
        raise ValueError(f"Cannot read image: {path}")
    image,lines = detect_segments(image)
    return estimate_segments(lines,image.shape)
