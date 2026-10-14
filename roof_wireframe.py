#!/usr/bin/env python3
"""Generate a top-down roof wireframe image from an .evm file (a renamed MATLAB .mat file).

Usage:
    python roof_wireframe.py job.evm
    python roof_wireframe.py job.evm -o roof.png --no-pitch --dpi 200
    python roof_wireframe.py job.evm -o overlay.png --overlay O_1234_01.jpg
    python roof_wireframe.py job.evm -v        # extra (debug) logging
    python roof_wireframe.py job.evm -q        # warnings/errors only

Progress is logged to the terminal (stdout) with timestamps.

--overlay draws the wireframe on top of the given top-down photo. The model
units are image pixels (Units == 'pixels', ImageData[0] has a ~identity
transform), so model x/y are used directly as photo pixel coordinates. If the
photo was exported at a different resolution than the tool's working image, use
--scale (e.g. 2 if the photo is twice as large).

Requires: numpy, scipy, matplotlib
"""
import argparse
import logging
import sys
import time

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import scipy.io as sio
from matplotlib.path import Path

log = logging.getLogger("roof_wireframe")

# Edge classification comes from each segment's LegacyUserTypeOverride code
# (same codes as SegmentLabels.Style). Mapping inferred from the file's geometry.
SEG_NAMES = {0: "Unspecified", 19: "Parapet", 18: "Flashing", 17: "StepFlashing", 16: "Rake",
             15: "Eave", 14: "Valley", 13: "Ridge", 12: "Hip", 11: "Other",
             10: "Hidden"}
SEG_COLORS = {0: "#808080", 19: "#7a0fe3", 18: "#c88c28", 17: "#a06000", 16: "#1a991a",
              15: "#000000", 14: "#0000ff", 13: "#ff0000", 12: "#ff00ff",
              11: "#ff99c7", 10: "#ffff00"}

# Dashed vs solid, per edge type
DASHED = {"StepFlashing", "Rake", "Valley", "Hip"}

def line_style(code):
    return "--" if SEG_NAMES[code] in DASHED else "-"
UNSPECIFIED_CODE = 0  # no/unrecognised edge type: drawn solid gray (kept distinct from "Other", code 11)

# Pitch labels on the plain wireframe: 9 pt is the normal size. A label is only
# made smaller when it does not fit inside its facet at that size.
PITCH_FONT_MAX = 9.0        # default size
PITCH_FONT_MIN = 3.5        # never shrink below this
PITCH_FONT_STEP = 0.5
PITCH_BBOX_PAD = 0.15       # boxstyle pad, as a fraction of the font size
PITCH_FIT_MARGIN_PT = 1.0   # extra breathing room around the label (points)
PITCH_MAX_CANDIDATES = 30   # centre positions tried per facet

# Overlay look (drawn over the photo). Thin lines so the photo stays readable.
OVERLAY_LINE_WIDTH = 0.8
OVERLAY_HALO_WIDTH = 2.0
OVERLAY_POINT_SIZE = 4
OVERLAY_POINT_EDGE = 0.3


def load_geometry(path):
    """Return (points Nx3 array, list of (segment_type, [i, j]) with 0-based indices)."""
    # .evm files are renamed .mat files; open as a file object so the extension doesn't matter
    log.info("Loading %s", path)
    t0 = time.perf_counter()
    with open(path, "rb") as fh:
        mat = sio.loadmat(fh, struct_as_record=False, squeeze_me=True)
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
        code = s.LegacyUserTypeOverride
        code = int(code) if np.isscalar(code) and np.isfinite(code) else UNSPECIFIED_CODE
        segs.append((code if code in SEG_NAMES else UNSPECIFIED_CODE, idx))
    facets = []
    for f in np.atleast_1d(ts.Facets):
        seg_ids = np.atleast_1d(f.Contains).astype(int) - 1  # segment indices (1-based in file)
        pitch = f.Pitch if np.isscalar(f.Pitch) else np.nan
        facets.append((seg_ids, float(pitch)))
    n_seg = sum(1 for _, ix in segs if ix is not None)
    log.info("Loaded %d points, %d segments, %d facets in %.2fs",
             len(pts), n_seg, len(facets), time.perf_counter() - t0)
    return pts, segs, facets


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


def label_candidates(poly, n=60, max_candidates=PITCH_MAX_CANDIDATES):
    """Points inside the polygon, best (furthest from the edges) first.

    Returns an (k, 2) array. The first row is the point furthest from every edge
    (as far as a coarse grid search finds); the rest are other well-inside points
    so a wide label can slide along an elongated facet.
    """
    path = Path(poly)
    lo, hi = poly.min(0), poly.max(0)
    gx, gy = np.meshgrid(np.linspace(lo[0], hi[0], n), np.linspace(lo[1], hi[1], n))
    grid = np.c_[gx.ravel(), gy.ravel()]
    grid = grid[path.contains_points(grid)]
    if len(grid) == 0:
        return poly.mean(0)[None, :]
    a, b = poly, np.roll(poly, -1, axis=0)
    ab = b - a
    denom = np.maximum((ab ** 2).sum(1), 1e-12)
    ap = grid[:, None, :] - a[None, :, :]                       # (G, E, 2)
    t = np.clip((ap * ab[None]).sum(2) / denom[None], 0, 1)     # (G, E)
    nearest = a[None] + t[..., None] * ab[None]
    d = np.linalg.norm(grid[:, None, :] - nearest, axis=2).min(1)
    order = np.argsort(-d)
    order = order[d[order] >= 0.5 * d[order[0]]]
    if len(order) > max_candidates:
        order = order[np.unique(np.r_[0, np.linspace(0, len(order) - 1, max_candidates).astype(int)])]
    return grid[order]


def label_point(poly):
    """A point inside the polygon, as far from its edges as a coarse grid search finds."""
    return label_candidates(poly)[0]


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


def fit_pitch_label(poly, text, size_units):
    """Pick (x, y, fontsize, fitted) for a pitch label.

    Tries the default font size first and only steps down when the label can't be
    placed fully inside the facet. size_units(text, fontsize) -> (width, height)
    of the label (including its background box) in data units.
    """
    path = Path(poly)
    cands = label_candidates(poly)
    sizes = np.arange(PITCH_FONT_MAX, PITCH_FONT_MIN - 1e-9, -PITCH_FONT_STEP)
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


def draw_pitch_labels(fig, ax, pts, segs, facets):
    """Draw each facet's pitch at the default size, shrinking only when it won't fit."""
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
            t = ax.text(0, 0, text, fontsize=fs, fontweight="bold")
            bb = t.get_window_extent(renderer)
            t.remove()
            pad = 2 * PITCH_BBOX_PAD * fs + PITCH_FIT_MARGIN_PT
            cache[key] = ((bb.width * 72.0 / fig.dpi + pad) / pt_per_unit,
                          (bb.height * 72.0 / fig.dpi + pad) / pt_per_unit)
        return cache[key]

    segs_xy = [tuple(ix) if ix is not None else () for _, ix in segs]
    drawn = shrunk = tight = skipped = 0
    for n, (seg_ids, pv) in enumerate(facets, start=1):
        if not np.isfinite(pv):  # nan or +/-inf pitch: nothing sensible to show
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
            x, y, fs, fitted = fit_pitch_label(poly, text, size_units)
        else:
            x, y = label_point(poly)
            fs, fitted = PITCH_FONT_MAX, True
        if fs < PITCH_FONT_MAX:
            shrunk += 1
            log.info("Facet %d: pitch %s shrunk %.1f -> %.1f pt to fit", n, text, PITCH_FONT_MAX, fs)
        if not fitted:
            tight += 1
            log.warning("Facet %d: pitch %s still does not fit at %.1f pt (facet is very small)", n, text, fs)
        ax.text(x, y, text, ha="center", va="center", fontsize=fs,
                fontweight="bold", color="#0a4d8c", zorder=4,
                bbox=dict(boxstyle=f"round,pad={PITCH_BBOX_PAD}", fc="white", ec="none", alpha=0.8))
        drawn += 1
    log.info("Pitch labels: %d drawn, %d shrunk, %d too small even at minimum, %d skipped",
             drawn, shrunk, tight, skipped)


def plot_top_down(pts, segs, facets, out_path, pitch=True, dpi=150):
    ok = ~np.isnan(pts).any(axis=1)
    fig, ax = plt.subplots(figsize=(9, 9), facecolor="white")
    used = {}

    for stype, ix in segs:
        if ix is None:
            continue
        i, j = ix
        if not (ok[i] and ok[j]):
            continue
        used[stype] = used.get(stype, 0) + 1
        ax.plot([pts[i, 0], pts[j, 0]], [pts[i, 1], pts[j, 1]],
                line_style(stype), color=SEG_COLORS[stype], lw=1.2)
    log.info("Drew %d segments (%s)", sum(used.values()),
             ", ".join(f"{SEG_NAMES[c]}={n}" for c, n in sorted(used.items())) or "none")

    ax.scatter(pts[ok, 0], pts[ok, 1], s=10, c="black", zorder=3)

    ax.set_aspect("equal")
    ax.invert_yaxis()  # image-style coordinates: y grows downward
    ax.axis("off")  # no axes, ticks, grid or title - just the wireframe
    fig.subplots_adjust(left=0.03, right=0.97, bottom=0.03, top=0.97)  # keeps image square

    if pitch:
        fig.canvas.draw()  # settle limits/aspect so the data -> point scale is known
        draw_pitch_labels(fig, ax, pts, segs, facets)
    else:
        log.info("Pitch labels hidden (--no-pitch)")

    fig.savefig(out_path, dpi=dpi)
    plt.close(fig)


def plot_overlay(pts, segs, img_path, out_path, scale=1.0, max_px=1400):
    """Draw the wireframe on top of the top-down photo (model x/y == photo pixels)."""
    import matplotlib.image as mpimg
    import matplotlib.patheffects as pe

    img = mpimg.imread(img_path)
    h, w = img.shape[:2]
    k = min(1.0, max_px / max(w, h))
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

    halo = [pe.Stroke(linewidth=OVERLAY_HALO_WIDTH, foreground="white", alpha=0.85), pe.Normal()]
    drawn = 0
    for stype, ix in segs:
        if ix is None:
            continue
        i, j = ix
        if not (ok[i] and ok[j]):
            continue
        ax.plot([xy[i, 0], xy[j, 0]], [xy[i, 1], xy[j, 1]], line_style(stype),
                color=SEG_COLORS[stype], lw=OVERLAY_LINE_WIDTH, path_effects=halo)
        drawn += 1
    ax.scatter(xy[ok, 0], xy[ok, 1], s=OVERLAY_POINT_SIZE, c="black", edgecolors="white",
               linewidths=OVERLAY_POINT_EDGE, zorder=3)
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
    ap.add_argument("--dpi", type=int, default=150)
    ap.add_argument("-v", "--verbose", action="store_true", help="Debug-level logging")
    ap.add_argument("-q", "--quiet", action="store_true", help="Only log warnings and errors")
    ap.add_argument("--overlay", default=None, metavar="IMAGE",
                    help="Draw the wireframe on top of this top-down photo instead")
    ap.add_argument("--scale", type=float, default=1.0,
                    help="Multiply model x/y by this to match the photo's resolution (overlay only)")
    args = ap.parse_args()

    # Log to stdout (flushed per line) so the lines stay in order with the final
    # "Saved ..." message when a parent process captures the output.
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(asctime)s.%(msecs)03d %(levelname)-7s %(message)s", "%H:%M:%S"))
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.WARNING if args.quiet else logging.INFO,
                        handlers=[handler])

    out = args.output or args.evm_file.rsplit(".", 1)[0] + "_topdown.png"
    mode = "overlay" if args.overlay else "wireframe"
    log.info("Rendering %s for %s -> %s", mode, args.evm_file, out)
    t0 = time.perf_counter()
    try:
        pts, segs, facets = load_geometry(args.evm_file)
        if args.overlay:
            plot_overlay(pts, segs, args.overlay, out, scale=args.scale)
        else:
            plot_top_down(pts, segs, facets, out,
                          pitch=not args.no_pitch, dpi=args.dpi)
    except Exception:
        log.exception("Failed to render %s", mode)
        sys.exit(1)
    log.info("Finished %s in %.2fs", mode, time.perf_counter() - t0)
    print(f"Saved {out}", flush=True)


if __name__ == "__main__":
    main()
