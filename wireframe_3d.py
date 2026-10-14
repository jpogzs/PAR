"""3D wireframe viewer for a .mat structure file.

Usage:  python wireframe_3d.py [path/to/file.mat] [--save out.png]
Requires: scipy, numpy, matplotlib
"""
import sys
import numpy as np
import scipy.io as sio
import matplotlib.pyplot as plt


def scalar(v):
    a = np.asarray(v).ravel()
    return float(a[0]) if a.size else np.nan


def load_wireframe(path):
    m = sio.loadmat(path, squeeze_me=True, struct_as_record=False)
    T = m["ThisStructure"]

    pts = np.array([[scalar(p.x), scalar(p.y), scalar(p.z)] for p in T.Points])
    pts[:, 2] *= -1   # reverse Z so the model isn't upside down

    segs = []
    for s in T.Segments:
        idx = np.atleast_1d(s.Contains).astype(int) - 1   # MATLAB 1-based -> 0-based
        if len(idx) == 2:
            segs.append((idx[0], idx[1], int(scalar(s.Type))))
    return pts, segs


def plot(pts, segs, save=None):
    fig = plt.figure(figsize=(10, 8))
    ax = fig.add_subplot(111, projection="3d")

    used = set()
    for a, b, t in segs:
        if np.isnan(pts[[a, b]]).any():
            continue
        p, q = pts[a], pts[b]
        ax.plot([p[0], q[0]], [p[1], q[1]], [p[2], q[2]], color="#1f4e79", lw=1.6)
        used.update([a, b])

    u = sorted(used)
    ax.scatter(pts[u, 0], pts[u, 1], pts[u, 2], color="#d62728", s=14, depthshade=False)

    # Equal aspect so the geometry isn't distorted
    v = pts[u]
    mid = (v.max(0) + v.min(0)) / 2
    r = (v.max(0) - v.min(0)).max() / 2
    ax.set_xlim(mid[0] - r, mid[0] + r)
    ax.set_ylim(mid[1] - r, mid[1] + r)
    ax.set_zlim(mid[2] - r, mid[2] + r)
    ax.set_box_aspect((1, 1, 1))

    ax.set_xlabel("X (px)")
    ax.set_ylabel("Y (px)")
    ax.set_zlabel("Z (px)")
    ax.set_title(f"3D Wireframe  |  {len(u)} points, {len(segs)} segments")
    ax.view_init(elev=28, azim=-60)

    if save:
        fig.savefig(save, dpi=160, bbox_inches="tight")
        print("saved", save)
    else:
        plt.show()


if __name__ == "__main__":
    args = sys.argv[1:]
    save = None
    if "--save" in args:
        i = args.index("--save")
        save = args[i + 1]
        del args[i:i + 2]
    path = args[0] if args else "test1.mat"
    pts, segs = load_wireframe(path)
    plot(pts, segs, save)
