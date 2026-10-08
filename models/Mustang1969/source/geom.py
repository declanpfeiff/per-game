"""Geometry helpers for the Mustang generator.

Surfaces are built as maps from a 2D parameter domain to 3D. Each patch is
triangulated in its domain with a constrained Delaunay triangulation, so
stripe, glass, trim and panel-gap boundaries come out as exact edges rather
than as stair steps along a grid. Normals are taken from the surface itself,
which keeps shading smooth however the triangles fall.
"""

import math

import numpy as np
from mathutils import Vector
from mathutils.geometry import delaunay_2d_cdt


# --------------------------------------------------------------------------
# Interpolation
# --------------------------------------------------------------------------

def _pchip_slopes(h, d):
    """Fritsch-Carlson slopes. h: (K-1,) knot gaps, d: (N, K-1) secants."""
    n, k1 = d.shape
    m = np.zeros((n, k1 + 1))
    if k1 == 1:
        m[:, 0] = d[:, 0]
        m[:, 1] = d[:, 0]
        return m
    w1 = 2 * h[1:] + h[:-1]
    w2 = h[1:] + 2 * h[:-1]
    dl, dr = d[:, :-1], d[:, 1:]
    same = (dl * dr) > 0
    with np.errstate(divide="ignore", invalid="ignore"):
        inner = (w1 + w2) / (w1 / dl + w2 / dr)
    m[:, 1:-1] = np.where(same, inner, 0.0)

    def end(h0, h1, d0, d1):
        s = ((2 * h0 + h1) * d0 - h0 * d1) / (h0 + h1)
        s = np.where(np.sign(s) != np.sign(d0), 0.0, s)
        s = np.where((np.sign(d0) != np.sign(d1)) & (np.abs(s) > np.abs(3 * d0)), 3 * d0, s)
        return s

    m[:, 0] = end(h[0], h[1], d[:, 0], d[:, 1])
    m[:, -1] = end(h[-1], h[-2], d[:, -1], d[:, -2])
    return m


def pchip_rows(knots, values, q):
    """Evaluate a monotone cubic per row.

    knots: (K,) shared knot positions; values: (N, K) per-row values;
    q: (N,) query per row. Returns (N,).
    """
    knots = np.asarray(knots, float)
    values = np.atleast_2d(np.asarray(values, float))
    q = np.asarray(q, float)
    h = np.diff(knots)
    d = np.diff(values, axis=1) / h
    m = _pchip_slopes(h, d)
    i = np.clip(np.searchsorted(knots, q, side="right") - 1, 0, len(knots) - 2)
    rows = np.arange(len(q))
    x0 = knots[i]
    hh = h[i]
    t = (q - x0) / hh
    y0 = values[rows, i]
    y1 = values[rows, i + 1]
    m0 = m[rows, i] * hh
    m1 = m[rows, i + 1] * hh
    t2, t3 = t * t, t * t * t
    return (2 * t3 - 3 * t2 + 1) * y0 + (t3 - 2 * t2 + t) * m0 + (-2 * t3 + 3 * t2) * y1 + (t3 - t2) * m1


class Table:
    """A smooth function of one variable through (x, y) key points."""

    def __init__(self, pts):
        pts = sorted(pts)
        self.x = np.array([p[0] for p in pts], float)
        self.y = np.array([p[1] for p in pts], float)

    def __call__(self, q):
        q = np.asarray(q, float)
        flat = np.atleast_1d(q).ravel()
        c = np.clip(flat, self.x[0], self.x[-1])
        out = pchip_rows(self.x, np.broadcast_to(self.y, (len(c), len(self.y))), c)
        return out.reshape(np.shape(q)) if np.ndim(q) else float(out[0])


def smoothstep(e0, e1, x):
    t = np.clip((np.asarray(x, float) - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def lerp(a, b, t):
    return a + (b - a) * t


# --------------------------------------------------------------------------
# 2D polygon tools (domain space)
# --------------------------------------------------------------------------

def points_in_poly(pts, poly):
    """Even-odd test. pts: (N, 2), poly: (M, 2) closed implicitly."""
    pts = np.asarray(pts, float)
    poly = np.asarray(poly, float)
    x, y = pts[:, 0][:, None], pts[:, 1][:, None]
    x0, y0 = poly[:, 0][None, :], poly[:, 1][None, :]
    x1, y1 = np.roll(poly[:, 0], -1)[None, :], np.roll(poly[:, 1], -1)[None, :]
    cond = (y0 > y) != (y1 > y)
    with np.errstate(divide="ignore", invalid="ignore"):
        xi = x0 + (y - y0) * (x1 - x0) / (y1 - y0)
    hit = cond & (x < xi)
    return (np.count_nonzero(hit, axis=1) % 2) == 1


def seg_dist(pts, a, b):
    """Distance from each point to the nearest of the segments a[i]-b[i]."""
    pts = np.asarray(pts, float)
    best = np.full(len(pts), np.inf)
    ab = b - a
    ll = np.maximum((ab * ab).sum(1), 1e-12)
    for c0 in range(0, len(a), 256):
        aa, bb, l2 = a[c0:c0 + 256], ab[c0:c0 + 256], ll[c0:c0 + 256]
        ap = pts[:, None, :] - aa[None, :, :]
        t = np.clip((ap * bb[None]).sum(2) / l2[None], 0, 1)
        dd = ap - t[..., None] * bb[None]
        best = np.minimum(best, np.sqrt((dd * dd).sum(2)).min(1))
    return best


def resample(poly, step, closed=True):
    """Insert points so no edge is longer than step."""
    poly = [np.asarray(p, float) for p in poly]
    out = []
    n = len(poly)
    last = n if closed else n - 1
    for i in range(last):
        a, b = poly[i], poly[(i + 1) % n]
        k = max(1, int(math.ceil(np.linalg.norm(b - a) / step)))
        for j in range(k):
            out.append(a + (b - a) * (j / k))
    if not closed:
        out.append(poly[-1])
    return np.array(out)


def rounded_rect(x0, y0, x1, y1, r, seg=6):
    pts = []
    corners = [(x1 - r, y1 - r, 0), (x0 + r, y1 - r, 90), (x0 + r, y0 + r, 180), (x1 - r, y0 + r, 270)]
    for cx, cy, a0 in corners:
        for j in range(seg + 1):
            a = math.radians(a0 + 90 * j / seg)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return np.array(pts)


def circle(cx, cy, r, seg=24, a0=0.0):
    a = a0 + np.linspace(0, 2 * math.pi, seg, endpoint=False)
    return np.stack([cx + r * np.cos(a), cy + r * np.sin(a)], 1)


def offset_poly(poly, d):
    """Offset a closed CCW polygon outward by d (miter, clamped)."""
    poly = np.asarray(poly, float)
    prev = np.roll(poly, 1, 0)
    nxt = np.roll(poly, -1, 0)
    e0 = poly - prev
    e1 = nxt - poly
    def nrm(e):
        l = np.linalg.norm(e, axis=1, keepdims=True)
        e = e / np.maximum(l, 1e-12)
        return np.stack([e[:, 1], -e[:, 0]], 1)
    n0, n1 = nrm(e0), nrm(e1)
    m = n0 + n1
    m /= np.maximum(np.linalg.norm(m, axis=1, keepdims=True), 1e-12)
    cosv = np.clip((m * n1).sum(1), 0.35, 1)
    return poly + m * (d / cosv)[:, None]


def poly_area(poly):
    p = np.asarray(poly)
    return 0.5 * np.sum(p[:, 0] * np.roll(p[:, 1], -1) - np.roll(p[:, 0], -1) * p[:, 1])


def ccw(poly):
    return poly if poly_area(poly) > 0 else poly[::-1]


# --------------------------------------------------------------------------
# Triangulated patches
# --------------------------------------------------------------------------

class Patch:
    """A parametric surface patch with material zones.

    fn(u, v) -> (N, 3) maps domain points to 3D. boundary is the domain
    outline. zones is a priority-ordered list of (polygon, key); key None cuts
    a hole. lines are extra constraint polylines (open) that only add edges.
    """

    def __init__(self, fn, boundary, default, step=1.5, zones=(), lines=(), mirror=True,
                 flip=False, grid=None, edge_step=None):
        self.fn = fn
        self.boundary = ccw(np.asarray(boundary, float))
        self.default = default
        self.step = step
        self.edge_step = edge_step or step * 0.5
        self.zones = [(np.asarray(p, float), k) for p, k in zones]
        self.lines = [np.asarray(l, float) for l in lines]
        self.mirror = mirror
        self.flip = flip
        self.grid = grid

    def triangulate(self):
        pts = []
        edges = []
        index = {}

        def add_pt(p):
            key = (round(p[0], 5), round(p[1], 5))
            if key in index:
                return index[key]
            index[key] = len(pts)
            pts.append((float(p[0]), float(p[1])))
            return index[key]

        segs_a, segs_b = [], []

        def add_poly(poly, closed):
            poly = resample(poly, self.edge_step, closed)
            ids = [add_pt(p) for p in poly]
            n = len(ids)
            for i in range(n if closed else n - 1):
                a, b = ids[i], ids[(i + 1) % n]
                if a != b:
                    edges.append((a, b))
                    segs_a.append(pts[a])
                    segs_b.append(pts[b])

        add_poly(self.boundary, True)
        for poly, _ in self.zones:
            add_poly(poly, True)
        for line in self.lines:
            add_poly(line, False)

        if self.grid is not None:
            gu, gv = self.grid
        else:
            lo = self.boundary.min(0)
            hi = self.boundary.max(0)
            gu = np.arange(lo[0], hi[0] + self.step, self.step)
            gv = np.arange(lo[1], hi[1] + self.step, self.step)
        g = np.array([(u, v) for u in gu for v in gv], float)
        g = g[points_in_poly(g, self.boundary)]
        if len(segs_a):
            dist = seg_dist(g, np.array(segs_a), np.array(segs_b))
            g = g[dist > self.edge_step * 0.45]
        for p in g:
            add_pt(p)

        out = delaunay_2d_cdt([Vector(p) for p in pts], edges, [], 0, 1e-7, False)
        verts = np.array([(v.x, v.y) for v in out[0]], float)
        tris = [f for f in out[2] if len(f) == 3]
        tris = np.array(tris, int)
        cent = verts[tris].mean(1)
        inside = points_in_poly(cent, self.boundary)
        keys = np.full(len(tris), None, dtype=object)
        assigned = np.zeros(len(tris), bool)
        for poly, key in self.zones:
            hit = (~assigned) & points_in_poly(cent, poly)
            keys[hit] = key
            assigned |= hit
        keys[~assigned] = self.default
        keep = inside & np.array([k is not None for k in keys])
        return verts, tris[keep], keys[keep]

    def normals(self, uv):
        e = 1e-3
        du = (self.fn(uv + [e, 0]) - self.fn(uv - [e, 0]))
        dv = (self.fn(uv + [0, e]) - self.fn(uv - [0, e]))
        n = np.cross(du, dv)
        n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-12)
        return -n if self.flip else n

    def build(self):
        """Returns {key: (verts3d, tris, corner_normals)}."""
        verts, tris, keys = self.triangulate()
        p3 = self.fn(verts)
        out = {}
        for key in dict.fromkeys(keys):
            sel = tris[keys == key]
            # corner normals, sampled just inside each triangle so creases stay crisp
            cent = verts[sel].mean(1)
            corner_uv = verts[sel] + 0.03 * (cent[:, None, :] - verts[sel])
            cn = self.normals(corner_uv.reshape(-1, 2)).reshape(-1, 3, 3)
            # winding must agree with the surface normal
            a, b, c = p3[sel[:, 0]], p3[sel[:, 1]], p3[sel[:, 2]]
            gn = np.cross(b - a, c - a)
            bad = (gn * cn.mean(1)).sum(1) < 0
            sel = sel.copy()
            sel[bad] = sel[bad][:, [0, 2, 1]]
            cn[bad] = cn[bad][:, [0, 2, 1]]
            used, inv = np.unique(sel.ravel(), return_inverse=True)
            v = p3[used]
            t = inv.reshape(-1, 3)
            parts = [(v, t, cn)]
            if self.mirror:
                vm = v * [-1, 1, 1]
                tm = t[:, [0, 2, 1]]
                cm = cn[:, [0, 2, 1]] * [-1, 1, 1]
                parts.append((vm, tm, cm))
            out[key] = merge_parts(parts)
        return out


def merge_parts(parts):
    vs, ts, ns = [], [], []
    off = 0
    for v, t, n in parts:
        vs.append(v)
        ts.append(t + off)
        ns.append(n)
        off += len(v)
    return np.concatenate(vs), np.concatenate(ts), np.concatenate(ns)


# --------------------------------------------------------------------------
# Simple solids
# --------------------------------------------------------------------------

def smooth_mesh(V, tris, angle=40.0):
    """Corner normals: smooth across edges flatter than angle, sharp otherwise."""
    V = np.asarray(V, float)
    tris = np.asarray(tris, int)
    a, b, c = V[tris[:, 0]], V[tris[:, 1]], V[tris[:, 2]]
    fn = np.cross(b - a, c - a)
    area = np.linalg.norm(fn, axis=1, keepdims=True)
    fnu = fn / np.maximum(area, 1e-12)
    cosl = math.cos(math.radians(angle))
    vert_faces = [[] for _ in range(len(V))]
    for fi, t in enumerate(tris):
        for k in t:
            vert_faces[k].append(fi)
    cn = np.zeros((len(tris), 3, 3))
    for fi, t in enumerate(tris):
        for ci, k in enumerate(t):
            acc = np.zeros(3)
            for fj in vert_faces[k]:
                if np.dot(fnu[fi], fnu[fj]) >= cosl:
                    acc += fn[fj]
            l = np.linalg.norm(acc)
            cn[fi, ci] = acc / l if l > 1e-12 else fnu[fi]
    return V, tris, cn


def box(c, s):
    cx, cy, cz = c
    sx, sy, sz = (np.asarray(s) / 2)
    V = np.array([(cx + x * sx, cy + y * sy, cz + z * sz) for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)])
    # index = xi*4 + yi*2 + zi
    quads = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
    tris = []
    for a, b, cc, d in quads:
        tris += [(a, b, cc), (a, cc, d)]
    return V, np.array(tris, int)


def flat(V, tris):
    """Corner normals for a faceted mesh."""
    V = np.asarray(V, float)
    tris = np.asarray(tris, int)
    a, b, c = V[tris[:, 0]], V[tris[:, 1]], V[tris[:, 2]]
    fn = np.cross(b - a, c - a)
    fn /= np.maximum(np.linalg.norm(fn, axis=1, keepdims=True), 1e-12)
    return V, tris, np.repeat(fn[:, None, :], 3, 1)


def transform(mesh, M):
    """Apply a 4x4 matrix (numpy) to a (V, T, N) mesh."""
    V, T, N = mesh
    M = np.asarray(M, float)
    V2 = V @ M[:3, :3].T + M[:3, 3]
    R = np.linalg.inv(M[:3, :3]).T
    N2 = N.reshape(-1, 3) @ R.T
    N2 /= np.maximum(np.linalg.norm(N2, axis=1, keepdims=True), 1e-12)
    T2 = T
    if np.linalg.det(M[:3, :3]) < 0:
        T2 = T[:, [0, 2, 1]]
        N2 = N2.reshape(-1, 3, 3)[:, [0, 2, 1]].reshape(-1, 3)
    return V2, T2, N2.reshape(-1, 3, 3)


def mirror_x(mesh):
    return transform(mesh, np.diag([-1.0, 1, 1, 1]))


def flip(mesh):
    V, T, N = mesh
    return V, T[:, [0, 2, 1]], -N[:, [0, 2, 1]]


def mat_trs(t=(0, 0, 0), rz=0.0, rx=0.0, ry=0.0, s=1.0):
    def R(axis, a):
        c, s_ = math.cos(a), math.sin(a)
        if axis == "x":
            return np.array([[1, 0, 0], [0, c, -s_], [0, s_, c]])
        if axis == "y":
            return np.array([[c, 0, s_], [0, 1, 0], [-s_, 0, c]])
        return np.array([[c, -s_, 0], [s_, c, 0], [0, 0, 1]])
    M = np.eye(4)
    S = np.diag(np.broadcast_to(np.asarray(s, float), (3,)))
    M[:3, :3] = R("z", rz) @ R("y", ry) @ R("x", rx) @ S
    M[:3, 3] = t
    return M


# --------------------------------------------------------------------------
# Lofts, tubes, beams
# --------------------------------------------------------------------------

def loft_loops(loops, closed=True, cap_start=False, cap_end=False, angle=50.0):
    """Skin a list of 3D loops that all have the same point count."""
    loops = [np.asarray(l, float) for l in loops]
    P = len(loops[0])
    V = np.concatenate(loops)
    tris = []
    pr = P if closed else P - 1
    for i in range(len(loops) - 1):
        for j in range(pr):
            a = i * P + j
            b = i * P + (j + 1) % P
            c = (i + 1) * P + (j + 1) % P
            d = (i + 1) * P + j
            tris += [(a, b, c), (a, c, d)]
    extra = []
    if cap_start:
        c0 = len(V) + len(extra)
        extra.append(loops[0].mean(0))
        tris += [(c0, (j + 1) % P, j) for j in range(P)]
    if cap_end:
        c1 = len(V) + len(extra)
        extra.append(loops[-1].mean(0))
        base = (len(loops) - 1) * P
        tris += [(c1, base + j, base + (j + 1) % P) for j in range(P)]
    if extra:
        V = np.concatenate([V, np.array(extra)])
    return smooth_mesh(V, np.array(tris, int), angle)


def path_frames(path, up=(0, 0, 1), closed=False):
    """Tangent-aligned frames (T, N, B) along a 3D polyline. N is perpendicular to T,
    as close to `up` as possible."""
    path = np.asarray(path, float)
    if closed:
        T = np.roll(path, -1, 0) - np.roll(path, 1, 0)
    else:
        T = np.gradient(path, axis=0)
    T /= np.maximum(np.linalg.norm(T, axis=1, keepdims=True), 1e-12)
    up = np.broadcast_to(np.asarray(up, float), path.shape)
    N = up - (up * T).sum(1, keepdims=True) * T
    N /= np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-12)
    B = np.cross(T, N)
    return T, N, B


def tube(path, radius, sides=8, closed=False, up=(0, 0, 1), cap=True, squash=1.0, angle=60.0):
    """Round (or squashed) tube along a polyline. Cross-section a in N, b in B."""
    path = np.asarray(path, float)
    T, N, B = path_frames(path, up, closed)
    a = np.linspace(0, 2 * math.pi, sides, endpoint=False)
    loops = [p + radius * (np.cos(a)[:, None] * n * squash + np.sin(a)[:, None] * b)
             for p, n, b in zip(path, N, B)]
    if closed:
        loops.append(loops[0])
    return loft_loops(loops, True, cap and not closed, cap and not closed, angle)


def swept(path, profile, up=(0, 0, 1), closed_profile=True, cap=True, angle=40.0):
    """Sweep a 2D profile [(n, b), ...] along a path. n runs along N (toward `up`
    projected), b along B = T x N."""
    path = np.asarray(path, float)
    T, N, B = path_frames(path, up)
    profile = np.asarray(profile, float)
    loops = [p + profile[:, :1] * n + profile[:, 1:2] * b for p, n, b in zip(path, N, B)]
    return loft_loops(loops, closed_profile, cap, cap, angle)


def beam(p0, p1, side, w, d):
    """Box from p0 to p1, w wide along `side` and d deep along side x axis."""
    p0, p1 = np.asarray(p0, float), np.asarray(p1, float)
    ax = p1 - p0
    ax /= np.linalg.norm(ax)
    s = np.asarray(side, float)
    s = s - np.dot(s, ax) * ax
    s /= np.linalg.norm(s)
    n = np.cross(ax, s)
    corners = []
    for p in (p0, p1):
        for i, j in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            corners.append(p + s * (i * w / 2) + n * (j * d / 2))
    V = np.array(corners)
    q = [(0, 1, 2, 3), (4, 7, 6, 5), (0, 4, 5, 1), (1, 5, 6, 2), (2, 6, 7, 3), (3, 7, 4, 0)]
    tris = []
    for a, b, c, dd in q:
        tris += [(a, c, b), (a, dd, c)]
    return flat(V, np.array(tris, int))


def disc(center, normal, r, seg=24, up=(0, 0, 1)):
    c = np.asarray(center, float)
    n = np.asarray(normal, float)
    n /= np.linalg.norm(n)
    u = np.asarray(up, float)
    u = u - np.dot(u, n) * n
    if np.linalg.norm(u) < 1e-6:
        u = np.array([1.0, 0, 0]) - n[0] * n
    u /= np.linalg.norm(u)
    v = np.cross(n, u)
    a = np.linspace(0, 2 * math.pi, seg, endpoint=False)
    ring = c + r * (np.cos(a)[:, None] * u + np.sin(a)[:, None] * v)
    V = np.concatenate([ring, [c]])
    tris = np.array([(seg, i, (i + 1) % seg) for i in range(seg)], int)
    m = flat(V, tris)
    if np.dot(m[2][0, 0], n) < 0:
        m = (m[0], m[1][:, [0, 2, 1]], -m[2])
    return m


def ring_frame(center, axis, up=(0, 0, 1)):
    """Orthonormal (u, v) spanning the plane perpendicular to axis."""
    n = np.asarray(axis, float)
    n = n / np.linalg.norm(n)
    u = np.asarray(up, float) - np.dot(up, n) * n
    if np.linalg.norm(u) < 1e-6:
        u = np.array([1.0, 0, 0]) - n[0] * n
    u /= np.linalg.norm(u)
    return u, np.cross(n, u), n


def lathe(profile, center, axis, seg=32, up=(0, 0, 1), angle=45.0):
    """Revolve [(r, h), ...] about an arbitrary axis through center (h along axis)."""
    u, v, n = ring_frame(center, axis, up)
    a = np.linspace(0, 2 * math.pi, seg, endpoint=False)
    loops = []
    for r, h in profile:
        loops.append(np.asarray(center) + n * h + r * (np.cos(a)[:, None] * u + np.sin(a)[:, None] * v))
    return loft_loops(loops, True, False, False, angle)
