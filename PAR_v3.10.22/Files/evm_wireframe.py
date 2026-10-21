#!/usr/bin/env python3
# ============================================================================
# Created and developed by PIA - members: Pogi, LT, Rona
#
# Do not edit the code without informing PIA.
# PIA site: https://eagleviewcloud.sharepoint.com/sites/QualityTeam/SitePages/PIA.aspx
# ============================================================================
"""Generate a top-down roof wireframe image from an .evm file (a renamed MATLAB .mat file).

Usage:
    python roof_wireframe.py job.evm
    python roof_wireframe.py job.evm -o roof.png --no-pitch --dpi 200
    python roof_wireframe.py job.evm -o overlay.png --overlay O_1234_01.jpg
    python roof_wireframe.py job.evm -o north.png --overlay N_1234_01.jpg --view N   # oblique North photo
    python roof_wireframe.py job.evm -v        # extra (debug) logging
    python roof_wireframe.py job.evm -q        # warnings/errors only
    python roof_wireframe.py job.evm --json3d -o job_3d.json   # 3D geometry for the PAR "3D View" tile

Progress is logged to the terminal (stdout) with timestamps.

--json3d writes the 3D geometry (points + typed segments + a pitch label per facet,
Z reversed so the roof sits upright) as JSON instead of a PNG. Unlike the top-down
image it keeps the edges of facets with an infinite pitch (but gives them no label); PAR renders it as a rotatable 3D view.

--overlay draws the wireframe on top of the given top-down photo. The model
units are image pixels (Units == 'pixels', ImageData[0] has a ~identity
transform), so model x/y are used directly as photo pixel coordinates. If the
photo was exported at a different resolution than the tool's working image, use
--scale (e.g. 2 if the photo is twice as large).

Requires: numpy, scipy, matplotlib
"""
import argparse
import json
import logging
import sys
import time

import numpy as np
import scipy.io as sio


def _plt():
    """matplotlib is only imported when a PNG is really drawn (not for --json3d)."""
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    return plt


def _mpl_path(poly):
    from matplotlib.path import Path
    return Path(poly)

log = logging.getLogger("roof_wireframe")

# Edge classification comes from each segment's LegacyUserTypeOverride code
# (same codes as SegmentLabels.Style). Mapping inferred from the file's geometry.
SEG_NAMES = {0: "Unspecified", 19: "Parapet", 18: "Flashing", 17: "StepFlashing", 16: "Rake",
             15: "Eave", 14: "Valley", 13: "Ridge", 12: "Hip", 11: "Other",
             10: "Hidden", 64: "Inside Corner", 65: "Outside Corner",
             66: "Obtuse Inside Corner", 67: "Obtuse Outside Corner", 68: "Top Wall", 69: "Bottom Wall",
             70: "Material Horizontal Boundary", 71: "Material Vertical Boundary",
             72: "Material Oblique Boundary", 73: "Material Top", 74: "Material Bottom",
             75: "Material Inside Corner", 76: "Material Outside Corner",
             77: "Material Obtuse Inside Corner", 78: "Material Obtuse Outside Corner",
             100: "Isoline"}
SEG_COLORS = {0: "#808080", 19: "#7a0fe3", 18: "#c88c28", 17: "#a06000", 16: "#1a991a",
              15: "#000000", 14: "#0000ff", 13: "#ff0000", 12: "#ff00ff",
              11: "#ff99c7", 10: "#ffff00",   # Hidden
              64: "#00ffff", 65: "#a80000",   # Inside Corner / Outside Corner
              66: "#00ff00", 67: "#ff00ff",   # Obtuse Inside Corner / Obtuse Outside Corner
              68: "#0000cc", 69: "#006666",   # Top Wall / Bottom Wall (wall edges)
              70: "#00aaee", 71: "#c55500", 72: "#aa00ee",   # Material Horizontal / Vertical / Oblique Boundary
              73: "#0000cc", 74: "#009944",   # Material Top / Material Bottom
              75: "#00ffff", 76: "#a80000",   # Material Inside Corner / Outside Corner
              77: "#00ff00", 78: "#e200aa",   # Material Obtuse Inside Corner / Obtuse Outside Corner
              100: "#666600"}   # Isoline

# Dashed vs solid per edge type; unspecified gray segments use dotted lines.
DASHED = {"StepFlashing", "Rake", "Valley", "Hip"}

def line_style(code):
    if code == UNSPECIFIED_CODE:
        return ":"
    return "--" if SEG_NAMES[code] in DASHED else "-"
UNSPECIFIED_CODE = 0  # no/unrecognised edge type: drawn dotted gray (kept distinct from "Other", code 11)

# Material shading of facets in the 3D view (Facets[].MaterialID -> colour, drawn at MATERIAL_ALPHAS opacity).
MATERIAL_NAMES = {1: "None", 2: "Siding", 3: "Masonry"}
MATERIAL_COLORS = {2: "#bfbf95", 3: "#70aca2"}   # Material None (1) has no fill
# Opacity per material (opacity = 1 - transparency): both are 75% transparent.
MATERIAL_ALPHAS = {2: 0.25, 3: 0.25}
# Facets with the Roof flag (512) get this tint on top of the material shading:
# green when the facet is planar (Facets[].IsPlanar = 1), red when it is not (IsPlanar = 0).
ROOF_COLOR = "#a8f5a8"
ROOF_NONPLANAR_COLOR = "#ff5a5a"
ROOF_ALPHA = 0.25  # 75% transparent
# Floor facets (flag 2048) get no shading and no pitch label.
FLOOR_FLAG = 2048
WALL_FLAG = 1024
ROOF_FLAG = 512

# Pitch labels shrink to fit their facet, starting at a compact size.
PITCH_FONT_MAX = 5.0
PITCH_FONT_MIN = 1.5
PITCH_FONT_STEP = 0.25
PITCH_FIT_MARGIN_PT = 0.25  # small clearance around the text (points)
PITCH_MAX_CANDIDATES = 30   # centre positions tried per facet
PITCH_MAX_SHOWN = 900       # pitches above this are never labelled

# Overlay look (drawn over the photo).
OVERLAY_LINE_WIDTH = 1.6


def segment_code(s):
    """Edge-type code of a segment (a key of SEG_NAMES; UNSPECIFIED_CODE if unknown)."""
    code = s.LegacyUserTypeOverride
    code = int(code) if np.isscalar(code) and np.isfinite(code) else UNSPECIFIED_CODE
    if code not in SEG_NAMES or code == UNSPECIFIED_CODE:
        # no usable override: corner/wall edges are still recognisable from the segment's own Type
        t = getattr(s, "Type", None)
        if np.isscalar(t) and np.isfinite(t) and int(t) in (64, 65, 66, 67, 68, 69):
            return int(t)
        return UNSPECIFIED_CODE
    return code


def load_image_xform(path):
    """4x4 registration transform (ImageData[].FwdXform, model -> top-down photo) or None.

    Prefers the image with Heading 0 (the top-down one). It carries a small tilt (Rx/Ry) that shifts points by
    an amount that grows with their height z, so raised points (ridge, eaves) land slightly off the flat x/y.
    """
    try:
        with open(path, "rb") as fh:
            mat = sio.loadmat(fh, struct_as_record=False, squeeze_me=True, variable_names=["ImageData"])
        best = None
        for im in np.atleast_1d(mat["ImageData"]):
            x = np.asarray(getattr(im, "FwdXform", []), dtype=float)
            if x.shape != (4, 4) or not np.isfinite(x).all():
                continue
            hd = np.asarray(getattr(im, "Heading", np.nan), dtype=float).ravel()
            if hd.size and hd[0] == 0:
                return x
            if best is None:
                best = x
        return best
    except Exception as e:  # missing ImageData etc.: just draw untilted
        log.warning("No usable image transform (%s); drawing untilted", e)
        return None


VIEW_HEADINGS = {"N": 0, "E": 90, "S": 180, "W": 270}


def classify_image_records(path):
    """Sort the ImageData records into the top-down photo and the N/E/S/W oblique photos.

    Returns {"O": 4x4, "N": 4x4, ...} (only the views the EVM really has data for). Every record is logged with the
    reason it was used or skipped, so a missing overlay can be traced in the terminal.

    - A record is usable only if it has a finite 4x4 FwdXform and (for obliques) a finite Heading.
    - The top-down photo has an almost untilted transform (third row ~ (0, 0, 1)); it is the Heading-0 one among those.
      A steep oblique can also have a large [2][2] value, so that value alone is not used to tell them apart.
    - The oblique photos are assigned to N/E/S/W one-to-one by the best overall match of their Headings to
      0/90/180/270 degrees (each photo used once, at most 60 degrees off), so a photo with an unusual Heading still
      lands on the closest free direction instead of being dropped.
    """
    with open(path, "rb") as fh:
        mat = sio.loadmat(fh, struct_as_record=False, squeeze_me=True, variable_names=["ImageData"])
    recs = []
    for n, im in enumerate(np.atleast_1d(mat["ImageData"])):
        x = np.asarray(getattr(im, "FwdXform", []), dtype=float)
        hd = np.asarray(getattr(im, "Heading", np.nan), dtype=float).ravel()
        hd = float(hd[0]) if hd.size and np.isfinite(hd[0]) else None
        if x.shape != (4, 4):
            log.info("ImageData[%d]: skipped - FwdXform is %s, not 4x4 (heading %s)", n, x.shape, hd)
            continue
        if not np.isfinite(x).all():
            log.info("ImageData[%d]: skipped - FwdXform has non-finite values (heading %s)", n, hd)
            continue
        recs.append((n, x, hd))
    out = {}
    top = [r for r in recs if r[1][2, 2] > 0.9 and abs(r[1][2, 0]) < 0.3 and abs(r[1][2, 1]) < 0.3]
    if top:
        t = next((r for r in top if r[2] == 0), max(top, key=lambda r: r[1][2, 2]))
        out["O"] = t[1]
        log.info("ImageData[%d]: top-down photo (heading %s)", t[0], t[2])
        recs = [r for r in recs if r[0] != t[0]]
    else:
        log.info("No top-down record found in ImageData")
    obl = [r for r in recs if r[2] is not None]
    for r in recs:
        if r[2] is None:
            log.info("ImageData[%d]: skipped - no Heading", r[0])
    views = list(VIEW_HEADINGS)

    def ang(h, v):
        return abs((h - VIEW_HEADINGS[v] + 180.0) % 360.0 - 180.0)
    best, best_cost = None, None
    from itertools import permutations
    k = min(len(obl), len(views))
    for chosen in permutations(range(len(obl)), k):   # which photo goes to N, E, S, W (in order); at most 4 photos
        pairs = list(zip(views, chosen))
        cost = sum(ang(obl[j][2], v) for v, j in pairs)
        if best_cost is None or cost < best_cost:
            best, best_cost = pairs, cost
    for v, j in (best or []):
        n, x, hd = obl[j]
        d = ang(hd, v)
        if d <= 60.0:
            out[v] = x
            log.info("ImageData[%d]: %s photo (heading %.0f, %.0f deg off)", n, v, hd, d)
        else:
            log.info("ImageData[%d]: heading %.0f is %.0f deg from %s - not used for it", n, hd, d, v)
    for r in obl:
        if not any(r[0] == obl[j][0] and ang(r[2], v) <= 60.0 for v, j in (best or [])):
            log.info("ImageData[%d]: heading %.0f not matched to any of N/E/S/W", r[0], r[2])
    return out


def load_view_xform(path, view):
    """4x4 transform (model -> oblique photo pixels) of the N/E/S/W elevation photo, or None.

    The oblique FwdXforms are affine (no perspective divide): photo x = row 0, photo y = row 1 of FwdXform
    applied to the model point (x, y, z, 1). Row 2 is only depth. See classify_image_records().
    """
    return classify_image_records(path).get(view)


def load_view_matrices(path):
    """Projection of every photo, for the 3D JSON: {"O": 3x4, "N": 3x4, "E": ..., "S": ..., "W": ...}.

    Each is the first three rows of the photo's ImageData FwdXform: photo x, photo y and depth of a model point
    (x, y, z) with the model's ORIGINAL z (the 3D JSON has z reversed). The viewer draws the wireframe on the
    photos with them. "O" is the top-down photo; views with no matching ImageData record are left out.
    """
    try:
        found = classify_image_records(path)
    except Exception as e:
        log.warning("No usable ImageData (%s); no photo overlays", e)
        return {}
    return {v: np.round(x[:3], 6).tolist() for v, x in found.items()}


def apply_xform(pts, xform):
    """Apply a 4x4 column-vector transform to Nx3 points (NaN rows stay NaN)."""
    return (xform @ np.c_[pts, np.ones(len(pts))].T).T[:, :3]


def load_geometry(path, omit_infinite=True):
    """Return (points Nx3 array, list of (segment_type, [i, j]) with 0-based indices)."""
    # .evm files are renamed .mat files; open as a file object so the extension doesn't matter
    log.info("Loading %s", path)
    t0 = time.perf_counter()
    with open(path, "rb") as fh:
        mat = sio.loadmat(fh, struct_as_record=False, squeeze_me=True, variable_names=["ThisStructure"])
    if "ThisStructure" not in mat:
        sys.exit("No 'ThisStructure' variable found in the .evm file.")
    ts = mat["ThisStructure"]
    pts = np.array([[p.x, p.y, p.z] for p in np.atleast_1d(ts.Points)], dtype=float)
    segs = []
    for s in np.atleast_1d(ts.Segments):
        idx = np.atleast_1d(s.Contains).astype(int) - 1  # MATLAB is 1-based
        if len(idx) != 2:
            segs.append((UNSPECIFIED_CODE, None))  # placeholder keeps facet segment indices aligned
            continue
        segs.append((segment_code(s), idx))
    facets = []
    facet_types = []  # Facets[].Type bit flags (Roof=512, Wall=1024, Material=16384, ...), parallel to facets
    facet_materials = []  # Facets[].MaterialID (1 None, 2 Siding, 3 Masonry), parallel to facets
    facet_planar = []  # Facets[].IsPlanar (1 planar, 0 not); a facet with no IsPlanar value counts as planar
    for f in np.atleast_1d(ts.Facets):
        seg_ids = np.atleast_1d(f.Contains).astype(int) - 1  # segment indices (1-based in file)
        pitch = f.Pitch if np.isscalar(f.Pitch) else np.nan
        facets.append((seg_ids, float(pitch)))
        ft = np.asarray(getattr(f, "Type", 0)).ravel()
        facet_types.append(int(ft[0]) if ft.size and np.isfinite(ft[0]) else 0)
        fm = np.asarray(getattr(f, "MaterialID", 0)).ravel()
        facet_materials.append(int(fm[0]) if fm.size and np.isfinite(fm[0]) else 0)
        ip = np.asarray(getattr(f, "IsPlanar", 1)).ravel()
        facet_planar.append(int(ip[0]) if ip.size and np.isfinite(ip[0]) else 1)
    if omit_infinite:  # the 3D view keeps infinite-pitch facets
        segs = omit_infinite_pitch_facet_segments(segs, facets)
    n_seg = sum(1 for _, ix in segs if ix is not None)
    log.info("Loaded %d points, %d segments, %d facets in %.2fs",
             len(pts), n_seg, len(facets), time.perf_counter() - t0)
    return pts, segs, facets, facet_types, facet_materials, facet_planar


def omit_infinite_pitch_facet_segments(segs, facets):
    """Hide edges used only by facets whose pitch is infinite, preserving shared edges."""
    infinite_ids = set()
    other_ids = set()
    for seg_ids, pitch in facets:
        target = infinite_ids if np.isinf(pitch) else other_ids
        target.update(int(k) for k in seg_ids if 0 <= int(k) < len(segs))
    omitted_ids = infinite_ids - other_ids
    if omitted_ids:
        segs = [
            (stype, None if i in omitted_ids else ix)
            for i, (stype, ix) in enumerate(segs)
        ]
        log.info("Omitted %d segments belonging only to infinite-pitch facets", len(omitted_ids))
    return segs


def facet_polygon(seg_ids, segs_xy):
    """Chain a facet's segments into an ordered vertex loop (list of point indices)."""
    edges = [tuple(segs_xy[k]) for k in seg_ids if 0 <= k < len(segs_xy) and len(segs_xy[k]) == 2]
    if not edges:
        return []
    loop = list(edges[0])
    remaining = edges[1:]
    while remaining:
        for e in remaining:
            if e[0] == loop[-1]:
                loop.append(e[1]); remaining.remove(e); break
            if e[1] == loop[-1]:
                loop.append(e[0]); remaining.remove(e); break
        else:
            break  # open/broken chain
    if len(loop) > 1 and loop[0] == loop[-1]:
        loop.pop()
    return loop


def _inside(poly, p):
    """Even-odd point-in-polygon for an (G, 2) array of points (vectorised ray casting)."""
    x, y = p[:, 0], p[:, 1]
    inside = np.zeros(len(p), dtype=bool)
    n = len(poly)
    j = n - 1
    for i in range(n):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if yi != yj:
            cross = ((yi > y) != (yj > y)) & (x < (xj - xi) * (y - yi) / (yj - yi) + xi)
            inside ^= cross
        j = i
    return inside


def label_candidates(poly, n=60, max_candidates=PITCH_MAX_CANDIDATES, best_only=False):
    """Points inside the polygon, best (furthest from the edges) first.

    Returns an (k, 2) array. The first row is the point furthest from every edge
    (as far as a coarse grid search finds); the rest are other well-inside points
    so a wide label can slide along an elongated facet. best_only=True returns just that first point.
    """
    lo, hi = poly.min(0), poly.max(0)
    xs = np.linspace(lo[0], hi[0], n)
    ys = np.linspace(lo[1], hi[1], n)
    grid = np.empty((n * n, 2))
    grid[:, 0] = np.tile(xs, n)
    grid[:, 1] = np.repeat(ys, n)
    grid = grid[_inside(poly, grid)]
    if len(grid) == 0:
        return poly.mean(0)[None, :]
    a, b = poly, np.roll(poly, -1, axis=0)
    ab = b - a
    denom = np.maximum((ab ** 2).sum(1), 1e-12)
    # squared distance grid -> every edge, one edge at a time (no (G, E, 2) temporaries)
    d2 = np.full(len(grid), np.inf)
    gx, gy = grid[:, 0], grid[:, 1]
    for k in range(len(a)):
        px, py = gx - a[k, 0], gy - a[k, 1]
        t = np.clip((px * ab[k, 0] + py * ab[k, 1]) / denom[k], 0, 1)
        dx, dy = px - t * ab[k, 0], py - t * ab[k, 1]
        np.minimum(d2, dx * dx + dy * dy, out=d2)
    d = np.sqrt(d2)
    if best_only:
        return grid[int(np.argmax(d))][None, :]
    order = np.argsort(-d)
    order = order[d[order] >= 0.5 * d[order[0]]]
    if len(order) > max_candidates:
        order = order[np.unique(np.r_[0, np.linspace(0, len(order) - 1, max_candidates).astype(int)])]
    return grid[order]


def label_point(poly):
    """A point inside the polygon, as far from its edges as a coarse grid search finds."""
    return label_candidates(poly, best_only=True)[0]


def box_fits(path, poly, cx, cy, hw, hh, samples=10):
    """True if the axis-aligned box centred on (cx, cy) lies fully inside the polygon."""
    xs = np.linspace(cx - hw, cx + hw, samples)
    ys = np.linspace(cy - hh, cy + hh, samples)
    ring = np.r_[np.c_[xs, np.full_like(xs, cy - hh)], np.c_[xs, np.full_like(xs, cy + hh)],
                 np.c_[np.full_like(ys, cx - hw), ys], np.c_[np.full_like(ys, cx + hw), ys]]
    if not path.contains_points(ring).all():
        return False
    # a polygon corner poking into the box means a notch/line would be covered
    poking = (np.abs(poly[:, 0] - cx) < hw) & (np.abs(poly[:, 1] - cy) < hh)
    return not poking.any()


def fit_pitch_label(poly, text, size_units, max_fontsize=PITCH_FONT_MAX):
    """Pick (x, y, fontsize, fitted) for a pitch label.

    Tries the default font size first and only steps down when the label can't be
    placed fully inside the facet. size_units(text, fontsize) -> (width, height)
    of the label (including its background box) in data units.
    """
    path = _mpl_path(poly)
    cands = label_candidates(poly)
    sizes = np.arange(max_fontsize, PITCH_FONT_MIN - 1e-9, -PITCH_FONT_STEP)
    for fs in sizes:
        w, h = size_units(text, float(fs))
        for cx, cy in cands:
            if box_fits(path, poly, cx, cy, w / 2, h / 2):
                return float(cx), float(cy), float(fs), True
    cx, cy = cands[0]
    return float(cx), float(cy), float(sizes[-1]), False


def fmt_pitch(p):
    p = round(float(p), 1)
    return f"{p:g}"


def draw_pitch_labels(fig, ax, pts, segs, facets, max_fontsize=PITCH_FONT_MAX, facet_types=None):
    """Draw each facet's pitch, shrinking only when it won't fit."""
    renderer = fig.canvas.get_renderer()
    p0 = ax.transData.transform((0.0, 0.0))
    p1 = ax.transData.transform((1.0, 0.0))
    pt_per_unit = abs(p1[0] - p0[0]) * 72.0 / fig.dpi  # points per data unit (aspect is equal)
    can_fit = bool(np.isfinite(pt_per_unit) and pt_per_unit > 0)
    if not can_fit:
        log.warning("Could not work out the drawing scale; pitch labels use the default size")

    cache = {}

    def size_units(text, fs):
        key = (text, fs)
        if key not in cache:
            t = ax.text(0, 0, text, fontsize=fs, fontweight="bold", fontfamily="Arial")
            bb = t.get_window_extent(renderer)
            t.remove()
            margin = PITCH_FIT_MARGIN_PT
            cache[key] = ((bb.width * 72.0 / fig.dpi + margin) / pt_per_unit,
                          (bb.height * 72.0 / fig.dpi + margin) / pt_per_unit)
        return cache[key]

    segs_xy = [tuple(ix) if ix is not None else () for _, ix in segs]
    drawn = shrunk = tight = skipped = 0
    for n, (seg_ids, pv) in enumerate(facets, start=1):
        if facet_types is not None and (facet_types[n - 1] & FLOOR_FLAG):  # Floor facets get no pitch label
            skipped += 1
            continue
        if not np.isfinite(pv) or pv > PITCH_MAX_SHOWN:  # nan, inf or absurdly steep pitch: nothing sensible to show
            skipped += 1
            continue
        facet_line_ids = [
            int(k) for k in seg_ids
            if 0 <= int(k) < len(segs) and segs[int(k)][1] is not None
        ]
        if pv == 0 and facet_line_ids and all(segs[k][0] == UNSPECIFIED_CODE for k in facet_line_ids):
            log.debug("Facet %d: zero pitch hidden because all outline lines are gray", n)
            skipped += 1
            continue
        loop = facet_polygon(seg_ids, segs_xy)
        if len(loop) < 3 or np.isnan(pts[loop]).any():
            log.debug("Facet %d: no usable outline, pitch label skipped", n)
            skipped += 1
            continue
        poly = pts[loop][:, :2]
        text = fmt_pitch(pv)
        if can_fit:
            x, y, fs, fitted = fit_pitch_label(poly, text, size_units, max_fontsize)
        else:
            x, y = label_point(poly)
            fs, fitted = max_fontsize, True
        if fs < max_fontsize:
            shrunk += 1
            log.info("Facet %d: pitch %s shrunk %.1f -> %.1f pt to fit", n, text, max_fontsize, fs)
        if not fitted:
            tight += 1
            log.warning("Facet %d: pitch %s still does not fit at %.1f pt (facet is very small)", n, text, fs)
        ax.text(x, y, text, ha="center", va="center", fontsize=fs,
                fontweight="bold", fontfamily="Arial", color="#0a4d8c", zorder=4)
        drawn += 1
    log.info("Pitch labels: %d drawn, %d shrunk, %d too small even at minimum, %d skipped",
             drawn, shrunk, tight, skipped)


def plot_top_down(pts, segs, facets, out_path, pitch=True, dpi=300, match_image=None, facet_types=None):
    plt = _plt()
    ok = ~np.isnan(pts).any(axis=1)
    if match_image:
        import matplotlib.image as mpimg

        h, w = mpimg.imread(match_image).shape[:2]
        k = min(3.0, 4200 / max(w, h))
        pitch_max_fontsize = PITCH_FONT_MAX * max(1.0, min(3.0, max(w * k, h * k) / 1400))
        figsize = (w * k / dpi, h * k / dpi)
    else:
        pitch_max_fontsize = PITCH_FONT_MAX
        figsize = (9, 9)
    fig, ax = plt.subplots(figsize=figsize, dpi=dpi, facecolor="white")
    used = {}

    for stype, ix in segs:
        if ix is None:
            continue
        i, j = ix
        if not (ok[i] and ok[j]):
            continue
        used[stype] = used.get(stype, 0) + 1
        ax.plot([pts[i, 0], pts[j, 0]], [pts[i, 1], pts[j, 1]],
                line_style(stype), color=SEG_COLORS[stype], lw=0.5,
                alpha=0.5 if stype == UNSPECIFIED_CODE else 1.0)
    log.info("Drew %d segments (%s)", sum(used.values()),
             ", ".join(f"{SEG_NAMES[c]}={n}" for c, n in sorted(used.items())) or "none")

    ax.set_aspect("equal")
    ax.invert_yaxis()  # image-style coordinates: y grows downward
    ax.axis("off")  # no axes, ticks, grid or title - just the wireframe
    fig.subplots_adjust(left=0.03, right=0.97, bottom=0.03, top=0.97)  # keeps image square

    if pitch:
        fig.canvas.draw()  # settle limits/aspect so the data -> point scale is known
        draw_pitch_labels(fig, ax, pts, segs, facets, max_fontsize=pitch_max_fontsize, facet_types=facet_types)
    else:
        log.info("Pitch labels hidden (--no-pitch)")

    fig.savefig(out_path, dpi=dpi)
    plt.close(fig)


def export_3d(pts, segs, facets, out_path, facet_types=None, facet_materials=None, views=None, facet_planar=None):
    """Write the 3D geometry as JSON: {"P": [[x, y, z]...], "S": [[i, j, code]...], ...}.

    Only points used by a drawn segment are kept (segments are re-indexed). Z is
    reversed so the model is upright. Segment codes/colours are the same as the
    top-down wireframe, so the 3D view matches it. Infinite-pitch facets keep their edges.
    "F" holds one pitch label per facet: {"p": text, "l": [x, y, z]} with the label
    placed inside the facet, on its plane (facets with no finite pitch - nan or
    infinite - get no label).
    """
    ok = ~np.isnan(pts).any(axis=1)
    ftypes = list(facet_types) if facet_types is not None else [0] * len(facets)
    fmats = list(facet_materials) if facet_materials is not None else [0] * len(facets)
    fplanar = list(facet_planar) if facet_planar is not None else [1] * len(facets)
    seg_ftypes = {}  # segment index -> set of the facet types that use it (the viewer's type toggles)
    for (seg_ids, _), ft in zip(facets, ftypes):
        for k in seg_ids:
            seg_ftypes.setdefault(int(k), set()).add(int(ft))
    kept = [(n, stype, ix) for n, (stype, ix) in enumerate(segs)
            if ix is not None and ok[ix[0]] and ok[ix[1]]]
    used = sorted({int(k) for _, _, ix in kept for k in ix})
    remap = {old: new for new, old in enumerate(used)}
    P = pts[used].copy()
    P[:, 2] *= -1  # reverse Z

    segs_xy = [tuple(ix) if ix is not None else () for _, ix in segs]
    loops = [facet_polygon(seg_ids, segs_xy) for seg_ids, _ in facets]   # each facet chained once (was 3x)
    lp_cache = {}   # facet index -> label point, shared by the pitch labels (F) and the Roof IDs (I)

    def cached_label_point(fi, poly2):
        if fi not in lp_cache:
            lp_cache[fi] = label_point(poly2)
        return lp_cache[fi]
    F = []
    for fi, (seg_ids, pv) in enumerate(facets):
        loop = loops[fi]
        if len(loop) < 3 or np.isnan(pts[loop]).any() or not np.isfinite(pv) or pv > PITCH_MAX_SHOWN or (ftypes[fi] & FLOOR_FLAG):
            continue  # no usable outline, or nan/inf pitch: nothing to label
        poly3 = pts[loop]
        x, y = cached_label_point(fi, poly3[:, :2])
        try:  # z on the facet's own plane (least squares); fall back to the mean height
            a = np.c_[poly3[:, 0], poly3[:, 1], np.ones(len(poly3))]
            cf = np.linalg.lstsq(a, poly3[:, 2], rcond=None)[0]
            z = float(cf[0] * x + cf[1] * y + cf[2])
        except Exception:
            z = float(poly3[:, 2].mean())
        F.append({"p": fmt_pitch(pv), "t": ftypes[fi],
                  "l": [round(float(x), 2), round(float(y), 2), round(-z + 0.0, 2)]})
    I = []  # facet IDs for the viewer's Wall IDs / Roof IDs buttons: {"i": ID number, "t": type, "l": [x, y, z]}
    #         Wall IDs count the Wall facets 1, 2, 3... (file order); Roof IDs are the facet's number in the file (1-based).
    wall_no = 0
    for fi, (seg_ids, _) in enumerate(facets):
        if ftypes[fi] not in (WALL_FLAG, ROOF_FLAG):   # type exactly Wall (1024) or Roof (512)
            continue
        if ftypes[fi] == WALL_FLAG:
            wall_no += 1   # counted even if this wall can't be labelled below, so the numbering matches the walls in the file
        loop = loops[fi]
        if len(loop) < 3 or np.isnan(pts[loop]).any():
            continue
        poly3 = pts[loop]
        try:
            if ftypes[fi] == ROOF_FLAG:  # same spot as the pitch label: top-down label point, z on the facet's plane
                x, y = cached_label_point(fi, poly3[:, :2])
                a_ = np.c_[poly3[:, 0], poly3[:, 1], np.ones(len(poly3))]
                cf = np.linalg.lstsq(a_, poly3[:, 2], rcond=None)[0]
                lp = np.array([x, y, cf[0] * x + cf[1] * y + cf[2]])
            else:  # walls are (near) vertical: pick the point inside the polygon in the facet's own plane
                c0 = poly3.mean(axis=0)
                _, _, vt = np.linalg.svd(poly3 - c0)
                u, v = vt[0], vt[1]
                uv = np.c_[(poly3 - c0) @ u, (poly3 - c0) @ v]
                lu, lv = label_point(uv)
                lp = c0 + lu * u + lv * v
        except Exception:
            lp = poly3.mean(axis=0)
        I.append({"i": wall_no if ftypes[fi] == WALL_FLAG else fi + 1, "t": ftypes[fi],
                  "l": [round(float(lp[0]), 2), round(float(lp[1]), 2), round(-float(lp[2]) + 0.0, 2)]})
    A = []  # shaded facet outlines: [materialID, facetType, [point indices], isPlanar]
    for fi, (seg_ids, _) in enumerate(facets):
        loop = loops[fi]
        if len(loop) < 3 or any(int(k) not in remap for k in loop):
            continue
        A.append([fmats[fi], ftypes[fi], [remap[int(k)] for k in loop], fplanar[fi]])
    data = {
        "A": A,
        "mat": {str(k): v for k, v in MATERIAL_COLORS.items()},
        "matNames": {str(k): v for k, v in MATERIAL_NAMES.items()},
        "matAlphas": {str(k): v for k, v in MATERIAL_ALPHAS.items()},
        "roof": ROOF_COLOR,
        "roofBad": ROOF_NONPLANAR_COLOR,
        "roofAlpha": ROOF_ALPHA,
        "P": (np.round(P, 2) + 0.0).tolist(),  # + 0.0 turns -0.0 into 0.0
        "S": [[remap[int(ix[0])], remap[int(ix[1])], int(stype), sorted(seg_ftypes.get(n, []))]
              for n, stype, ix in kept],
        "F": F,
        "I": I,
        "colors": {str(k): v for k, v in SEG_COLORS.items()},
        "names": {str(k): v for k, v in SEG_NAMES.items()},
        "V": views or {},  # photo projections (see load_view_matrices); the viewer overlays the wireframe on the photos
    }
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, separators=(",", ":"))
    log.info("Wrote 3D geometry: %d points, %d segments, %d facet labels, %d facet IDs -> %s",
             len(P), len(data["S"]), len(F), len(I), out_path)


def wall_floor_only_segments(segs, facets, facet_types):
    """Indices of segments used only by Wall (1024) / Floor (2048) facets (kept if any roof/other facet shares them)."""
    used = {}
    for (seg_ids, _), ft in zip(facets, facet_types):
        for k in seg_ids:
            used.setdefault(int(k), []).append(int(ft))
    return {k for k, fts in used.items() if fts and all(t & (1024 | 2048) for t in fts)}


def plot_overlay(pts, segs, img_path, out_path, scale=1.0, max_px=4200, skip=None):
    """Draw the wireframe on top of the top-down photo (model x/y == photo pixels)."""
    plt = _plt()
    import matplotlib.image as mpimg

    img = mpimg.imread(img_path)
    h, w = img.shape[:2]
    k = min(3.0, max_px / max(w, h))
    log.info("Overlay on %s (%dx%d px, output scale %.2f, model scale %.2f)", img_path, w, h, k, scale)
    dpi = 100
    fig = plt.figure(figsize=(w * k / dpi, h * k / dpi), dpi=dpi, facecolor="black")
    ax = fig.add_axes([0, 0, 1, 1])
    if img.ndim == 2:
        ax.imshow(img, cmap="gray", extent=(0, w, h, 0), interpolation="bilinear")
    else:
        ax.imshow(img, extent=(0, w, h, 0), interpolation="bilinear")

    xy = pts[:, :2] * scale
    ok = ~np.isnan(xy).any(axis=1)
    if ok.any():
        lo, hi = xy[ok].min(0), xy[ok].max(0)
        if hi[0] > w * 1.02 or hi[1] > h * 1.02 or lo.min() < -0.02 * max(w, h):
            log.warning("Wireframe extent x %.0f..%.0f, y %.0f..%.0f does not fit the %dx%d photo - try --scale",
                        lo[0], hi[0], lo[1], hi[1], w, h)

    drawn = 0
    skip = skip or set()  # Wall / Floor segments are not shown on the overlay
    for n, (stype, ix) in enumerate(segs):
        if ix is None or n in skip:
            continue
        i, j = ix
        if not (ok[i] and ok[j]):
            continue
        ax.plot([xy[i, 0], xy[j, 0]], [xy[i, 1], xy[j, 1]], line_style(stype),
                color=SEG_COLORS[stype], lw=OVERLAY_LINE_WIDTH,
                alpha=0.5 if stype == UNSPECIFIED_CODE else 1.0,
                zorder=3)
        drawn += 1
    log.info("Drew %d segments on the photo (line width %.1f)", drawn, OVERLAY_LINE_WIDTH)
    ax.set_xlim(0, w)
    ax.set_ylim(h, 0)
    ax.axis("off")
    fig.savefig(out_path, dpi=dpi)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("evm_file", help="Input .evm file")
    ap.add_argument("-o", "--output", default=None,
                    help="Output PNG (default: <evm_file>_topdown.png)")
    ap.add_argument("--no-pitch", action="store_true", help="Hide per-facet pitch labels")
    ap.add_argument("--dpi", type=int, default=300)
    ap.add_argument("-v", "--verbose", action="store_true", help="Debug-level logging")
    ap.add_argument("-q", "--quiet", action="store_true", help="Only log warnings and errors")
    ap.add_argument("--overlay", default=None, metavar="IMAGE",
                    help="Draw the wireframe on top of this top-down photo instead")
    ap.add_argument("--view", choices=sorted(VIEW_HEADINGS), default=None,
                    help="Overlay only: the --overlay photo is the oblique N/E/S/W elevation photo; project the wireframe "
                         "with that photo's ImageData FwdXform instead of the top-down one")
    ap.add_argument("--no-tilt", action="store_true",
                    help="Overlay only: do not apply the image registration tilt (ImageData FwdXform)")
    ap.add_argument("--scale", type=float, default=1.0,
                    help="Multiply model x/y by this to match the photo's resolution (overlay only)")
    ap.add_argument("--match-image", default=None, metavar="IMAGE",
                    help="Match the plain wireframe canvas dimensions to this image")
    ap.add_argument("--json3d", action="store_true",
                    help="Write the 3D geometry as JSON (for the interactive 3D view) instead of a PNG")
    args = ap.parse_args()

    # Log to stdout (flushed per line) so the lines stay in order with the final
    # "Saved ..." message when a parent process captures the output.
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(asctime)s.%(msecs)03d %(levelname)-7s %(message)s", "%H:%M:%S"))
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.WARNING if args.quiet else logging.INFO,
                        handlers=[handler])

    out = args.output or args.evm_file.rsplit(".", 1)[0] + ("_3d.json" if args.json3d else "_topdown.png")
    mode = "3d" if args.json3d else ("overlay-" + args.view if args.view else "overlay") if args.overlay else "wireframe"
    log.info("Rendering %s for %s -> %s", mode, args.evm_file, out)
    t0 = time.perf_counter()
    try:
        pts, segs, facets, facet_types, facet_materials, facet_planar = load_geometry(args.evm_file, omit_infinite=not args.json3d)
        if args.json3d:
            export_3d(pts, segs, facets, out, facet_types, facet_materials, views=load_view_matrices(args.evm_file), facet_planar=facet_planar)
        elif args.overlay:
            if args.view:
                xf = load_view_xform(args.evm_file, args.view)
                if xf is None:
                    sys.exit(f"No ImageData record for the {args.view} view in {args.evm_file}")
                log.info("Projecting onto the %s oblique photo", args.view)
            else:
                xf = None if args.no_tilt else load_image_xform(args.evm_file)
            if xf is not None:
                tilted = apply_xform(pts, xf)
                shift = np.hypot(*(tilted[:, :2] - pts[:, :2]).T)
                log.info("Applied registration tilt: points move up to %.1f px (mean %.1f px)",
                         np.nanmax(shift), np.nanmean(shift))
                pts = tilted
            plot_overlay(pts, segs, args.overlay, out, scale=args.scale,
                         skip=wall_floor_only_segments(segs, facets, facet_types))
        else:
            plot_top_down(pts, segs, facets, out,
                          pitch=not args.no_pitch, dpi=args.dpi,
                          match_image=args.match_image, facet_types=facet_types)
    except Exception:
        log.exception("Failed to render %s", mode)
        sys.exit(1)
    log.info("Finished %s in %.2fs", mode, time.perf_counter() - t0)
    print(f"Saved {out}", flush=True)


if __name__ == "__main__":
    main()
