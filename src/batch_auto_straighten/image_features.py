"""Image-only features for Batch Auto Straighten tilt analysis.

No catalog API or Adobe implementation is used at inference. Feature
extraction is versioned together with the bundled image-analysis model.
"""
from pathlib import Path
import cv2
import numpy as np
from batch_auto_straighten.image_geometry import detect_segments, estimate_segments

FEATURE_VERSION = "joint-line-distribution-v1"

def horizontal_families(image):
    im,segments=detect_segments(image);h,w=im.shape
    segments=(segments-[w/2,h/2,w/2,h/2])/max(h,w)
    d=segments[:,2:]-segments[:,:2];length=np.linalg.norm(d,axis=1)
    keep=np.abs(d[:,1])<np.abs(d[:,0])*np.tan(np.radians(45))
    segments,d,length=segments[keep],d[keep],length[keep]
    idx=np.argsort(-length,kind='stable')[:1200]
    segments,d,length=segments[idx],d[idx],length[idx]
    n=len(segments)
    if n<8:return []
    a=np.column_stack([segments[:,:2],np.ones(n)]);b=np.column_stack([segments[:,2:],np.ones(n)])
    lines=np.cross(a,b);lines=lines/np.linalg.norm(lines[:,:2],axis=1)[:,None]
    mid=(segments[:,:2]+segments[:,2:])/2
    ii,jj=np.triu_indices(n,1)
    keep=np.linalg.norm(mid[ii]-mid[jj],axis=1)>.1;ii,jj=ii[keep],jj[keep]
    if len(ii)>4096:
        idx=np.random.default_rng(0).choice(len(ii),4096,replace=False);ii,jj=ii[idx],jj[idx]
    vp=np.cross(lines[ii],lines[jj]);vp=vp/np.linalg.norm(vp,axis=1)[:,None]
    # Most plausible horizon band for a near-upright street photo; no label input.
    keep=np.abs(vp[:,1])<(.5*np.abs(vp[:,2])+.3*np.abs(vp[:,0]))
    vp=vp[keep]
    weights=np.minimum(length,.2)
    active=np.ones(n,dtype=bool);out=[]
    def residual(v):
        delta=v[None,:,:2]-mid[:,None,:]*v[None,:,2:]
        denominator=np.maximum(np.linalg.norm(delta,axis=2),1e-9)
        return np.degrees(np.arcsin(np.clip(np.abs(lines@v.T)/denominator,0,1)))
    for iteration in range(4):
        scores=[]
        for start in range(0,len(vp),128):
            res=residual(vp[start:start+128]);scores.extend((weights[:,None]*active[:,None]*np.maximum(0,1-(res/.7)**2)).sum(axis=0))
        if not len(scores):break
        v=vp[np.argmax(scores)]
        for _ in range(5):
            res=residual(v[None,:])[:,0]
            robust=weights*active*np.maximum(0,1-(res/.7)**2)**2
            _,_,vh=np.linalg.svd(lines*np.sqrt(robust[:,None]),full_matrices=False)
            v=vh[-1]
        res=residual(v[None,:])[:,0];ok=(res<.7)&active
        if ok.sum()<6:break
        out.append({'vp':v.tolist(),'weight':float(weights[ok].sum()),'n':int(ok.sum()),'span':float(np.ptp(mid[ok,0]))})
        active[ok]=False
    return out


def analysis_features(path: Path, orientation_caps_deg: list[int]):
    """Return features plus raw geometry; None features means no VP evidence."""
    caps = orientation_caps_deg
    if not caps or any(value not in (10, 20, 30) for value in caps) or len(caps) != len(set(caps)):
        raise ValueError("Unsupported orientation cap")
    image = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
    if image is None:
        raise ValueError(f"Cannot read image: {path}")
    work, segments = detect_segments(image)
    geometry = estimate_segments(segments, work.shape)
    if geometry.diagnostic_angle_deg is None:
        return None, geometry
    v = geometry.diagnostic_angle_deg
    families = horizontal_families(image)
    candidates = []
    for i, a in enumerate(families):
        for b in families[i + 1:]:
            p, q = np.array(a['vp']), np.array(b['vp'])
            separation = np.degrees(np.arccos(np.clip(abs(p @ q), 0, 1)))
            if separation < 15:
                continue
            horizon = np.cross(p, q)
            angle = (np.degrees(np.arctan2(horizon[0], horizon[1])) + 90) % 180 - 90
            if abs(angle) > 15:
                continue
            # Preserve the diagnostic artifact's one-decimal separation contract.
            weight = np.sqrt(a['weight'] * b['weight'])
            weight *= np.sin(np.radians(round(float(separation), 1))) ** 2
            weight *= np.exp(-0.5 * ((angle - v) / 2.0) ** 2)
            candidates.append((float(weight), float(angle)))
    candidates.sort(reverse=True)
    h = candidates[0][1] if candidates else v
    distribution = line_distributions(image)
    features = {'vertical_deg': v,
                'inverse_vp_distance': geometry.inverse_vp_distance,
                'horizontal_delta_deg': h - v}
    for value in caps:
        hs = distribution[f'h{value}_support']
        for statistic in ('mean', 'median', 'mode'):
            name = f'h{value}_{statistic}'
            features[name + '_joint_support'] = (distribution[name] - v) * hs * (1 - geometry.support)
            name = f'v{value}_{statistic}'
            features[name] = distribution[name] - v
    if not all(np.isfinite(value) for value in features.values()):
        raise ValueError("Non-finite image features")
    return features, geometry


def line_distributions(image):
    image,lines=detect_segments(image);h,w=image.shape
    d=lines[:,2:]-lines[:,:2];length=np.linalg.norm(d,axis=1)/max(h,w)
    raster=(np.degrees(np.arctan2(d[:,1],d[:,0]))+90)%180-90
    ha=-raster
    va=np.where(raster>0,90-raster,-90-raster)
    out={}
    for axis,angles in [('h',ha),('v',va)]:
        for cap in (5,10,20,30):
            keep=abs(angles)<cap;a=angles[keep];weight=np.minimum(length[keep],.2)
            if not len(a):
                for stat in ('mean','median','mode','support'):out[f'{axis}{cap}_{stat}']=0.
                continue
            order=np.argsort(a)
            out[f'{axis}{cap}_mean']=float(np.average(a,weights=weight))
            out[f'{axis}{cap}_median']=float(a[order][np.searchsorted(np.cumsum(weight[order]),weight.sum()/2)])
            grid=np.arange(-cap,cap+.025,.05)
            score=(np.exp(-.5*((a[:,None]-grid)/.5)**2)*weight[:,None]).sum(axis=0)
            mode=grid[np.argmax(score)]
            out[f'{axis}{cap}_mode']=float(mode)
            out[f'{axis}{cap}_support']=float(weight[abs(a-mode)<.5].sum()/weight.sum())
    return out
