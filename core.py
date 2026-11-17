"""失焦筛选核心算法（零第三方依赖：numpy + Pillow）。

设计要点：不做全图平均，而是先确定「主体区域」，再用相对判据
「主体区锐度 / 画面最锐区锐度」判断焦点是否落在主体上。
主体区域 mask 由外部提供（Vision / 对焦点 / 中心先验），本模块不关心语义类别。
"""
from __future__ import annotations

import numpy as np
from PIL import Image, ImageFilter


def laplacian_variance(tile: np.ndarray) -> float:
    """拉普拉斯响应的方差，衡量该块的高频细节量。"""
    a = tile.astype(np.float32)
    core = a[1:-1, 1:-1]
    lap = -4.0 * core + a[:-2, 1:-1] + a[2:, 1:-1] + a[1:-1, :-2] + a[1:-1, 2:]
    return float(lap.var())


def reblur_ratio(tile: np.ndarray, radius: float = 1.0) -> float:
    """再模糊一次后高频的保留比例。越接近 1 说明原本已经糊了；对噪声更鲁棒。"""
    v0 = laplacian_variance(tile)
    im = Image.fromarray(np.clip(tile, 0, 255).astype(np.uint8))
    v1 = laplacian_variance(np.asarray(im.filter(ImageFilter.GaussianBlur(radius))).astype(np.float32))
    return v1 / max(v0, 1e-6)


def anisotropy(gray: np.ndarray) -> float:
    """方向性。明显大于 1 说明是运动模糊/拖影，不应按失焦处理。"""
    gx = float(np.abs(np.diff(gray, axis=1)).mean())
    gy = float(np.abs(np.diff(gray, axis=0)).mean())
    return max(gx, gy) / max(min(gx, gy), 1e-6)


def evaluate(gray: np.ndarray, subject_mask: np.ndarray, block: int = 32,
             hi_q: float = 90.0) -> dict:
    """返回全图最锐块、主体区锐度、二者比值，以及方向性/重模糊比。"""
    h, w = gray.shape
    cells, subj = [], []
    for y in range(0, h - block + 1, block):
        for x in range(0, w - block + 1, block):
            t = gray[y:y + block, x:x + block]
            item = (laplacian_variance(t), reblur_ratio(t))
            cells.append(item)
            if subject_mask[y:y + block, x:x + block].mean() > 0.5:
                subj.append(item)
    vals = np.array([c[0] for c in cells])
    hi = float(np.percentile(vals, hi_q))
    s = float(np.median([c[0] for c in subj])) if subj else hi
    return {
        "global_hi": hi,
        "subject": s,
        "ratio": s / max(hi, 1e-6),
        "anisotropy": anisotropy(gray),
        "reblur": float(np.median([c[1] for c in subj])) if subj else 0.5,
    }


def verdict(r: dict, hi_min: float, ratio_min: float = 0.5,
            aniso_max: float = 2.0) -> str:
    if r["anisotropy"] > aniso_max:
        return "运动模糊/拖影（非失焦）"
    if r["global_hi"] < hi_min:
        return "疑似全片模糊"
    if r["ratio"] < ratio_min:
        return "疑似主体失焦（焦点跑偏）"
    return "通过"


def make_texture(size: int = 256, seed: int = 7) -> np.ndarray:
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[:size, :size]
    noise = rng.normal(0, 1, (size, size))
    structure = 30 * np.sin(xx / 7) * np.cos(yy / 11)
    return np.clip(128 + 38 * noise + structure, 0, 255).astype(np.uint8)


def make_subject_mask(size: int = 256, cx: int = 128, cy: int = 128,
                      rx: float = 62, ry: float = 72) -> np.ndarray:
    yy, xx = np.ogrid[:size, :size]
    return ((xx - cx) / rx) ** 2 + ((yy - cy) / ry) ** 2 <= 1


def compose(tex: np.ndarray, mask: np.ndarray, subj_blur: float,
            bg_blur: float) -> np.ndarray:
    sharp = Image.fromarray(tex)
    s = np.asarray(sharp.filter(ImageFilter.GaussianBlur(subj_blur))).astype(np.float32) if subj_blur > 0 else tex.astype(np.float32)
    b = np.asarray(sharp.filter(ImageFilter.GaussianBlur(bg_blur))).astype(np.float32) if bg_blur > 0 else tex.astype(np.float32)
    return np.where(mask, s, b).astype(np.uint8)


def motion_blur(tex: np.ndarray, k: int = 9) -> np.ndarray:
    a = tex.astype(np.float32)
    pad = np.pad(a, ((0, 0), (k, k)), mode="edge")
    return np.stack([pad[:, i:i + a.shape[1]] for i in range(k)]).mean(axis=0).astype(np.uint8)


if __name__ == "__main__":
    tex, mask = make_texture(), make_subject_mask()
    cases = {
        "全片清晰": compose(tex, mask, 0, 0),
        "全片失焦": compose(tex, mask, 3.0, 3.0),
        "主体清晰/背景虚化（好片）": compose(tex, mask, 0, 4.0),
        "主体失焦/背景清晰（废片）": compose(tex, mask, 4.0, 0),
        "水平运动模糊": motion_blur(tex, 9),
    }
    results = {name: evaluate(arr.astype(np.float32), mask) for name, arr in cases.items()}
    sharp, blurred = results["全片清晰"], results["全片失焦"]
    hi_min = float(np.sqrt(sharp["global_hi"] * blurred["global_hi"]))

    print(f"标定阈值 hi_min = {hi_min:.1f}（由清晰/失焦样本几何平均得出，非固定经验值）\n")
    print(f"{'场景':<26}{'最锐块P90':>11}{'主体区':>9}{'主体/最锐':>11}{'方向性':>9}{'重模糊比':>10}  判定")
    print("-" * 106)
    for name, r in results.items():
        print(f"{name:<26}{r['global_hi']:>11.1f}{r['subject']:>9.1f}"
              f"{r['ratio']:>11.2f}{r['anisotropy']:>9.2f}{r['reblur']:>10.2f}"
              f"  {verdict(r, hi_min)}")
