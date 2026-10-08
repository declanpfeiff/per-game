"""Everything that isn't body shell: wheels, lights, grille, bumpers, trim, interior.

Parts are built for the right side (+X) and mirrored where the car is symmetric.
"""

import math

import numpy as np

import body
import interior
import text
from geom import (Patch, smooth_mesh, transform, mat_trs, mirror_x, flip, loft_loops, tube, swept,
                  beam, disc, lathe, ring_frame, rounded_rect, circle, resample, flat, box, smoothstep)


def both(car, name, mat, mesh):
    car.add(name, mat, mesh)
    car.add(name, mat, mirror_x(mesh))


def add_all(car, steer=0.0):
    front_end(car)
    hood_scoop(car)
    side_details(car)
    wheel_wells(car)
    wheels(car, steer)
    rear_end(car)
    underbody(car)
    interior.add_all(car)


# --------------------------------------------------------------------------
# Front end
# --------------------------------------------------------------------------

G = body.GRILLE
GRILLE_DEPTH = 3.4


def face_point(x, z, back=0.0):
    x = np.asarray(x, float)
    z = np.asarray(z, float)
    return np.stack([x, body.nose_y(x, z) - back, z], -1)


def grille_outline(inset=0.0, seg=10):
    return rounded_rect(-G["x"] + inset, G["z0"] + inset, G["x"] - inset, G["z1"] - inset, G["r"] - inset, seg)


def front_end(car):
    ol = resample(grille_outline(), 0.8)
    front = face_point(ol[:, 0], ol[:, 1], -0.05)
    back = face_point(ol[:, 0], ol[:, 1], GRILLE_DEPTH)
    # cavity walls face into the opening
    car.add("Grille", "Black", flip(loft_loops([front, back], True)))
    # back plate
    V = np.concatenate([back, [back.mean(0)]])
    n = len(back)
    T = np.array([(n, (i + 1) % n, i) for i in range(n)])
    car.add("PanelGaps", "Gap", flat(V, T))

    # egg-crate: thin bars just in front of the back plate
    bars = []
    xs = np.arange(-G["x"] + 1.2, G["x"] - 0.5, 1.75)
    for x in xs:
        z0, z1 = _grille_span_z(x, 0.2)
        if z1 - z0 < 0.5:
            continue
        p0 = face_point(x, z0, GRILLE_DEPTH - 0.6)
        p1 = face_point(x, z1, GRILLE_DEPTH - 0.6)
        bars.append(beam(p0, p1, (1, 0, 0), 0.16, 1.1))
    for z in np.arange(G["z0"] + 1.15, G["z1"] - 0.4, 1.2):
        x0, x1 = _grille_span_x(z, 0.2)
        p0 = face_point(x0, z, GRILLE_DEPTH - 0.6)
        p1 = face_point(x1, z, GRILLE_DEPTH - 0.6)
        bars.append(beam(p0, p1, (0, 0, 1), 0.2, 1.1))
    for b in bars:
        car.add("Grille", "Black", b)

    # chrome surround: a rounded molding on the face around the opening
    path = face_point(*resample(grille_outline(-0.35), 0.6).T, -0.15)
    car.add("Trim_Chrome", "Chrome", tube(np.concatenate([path, path[:1]]), 0.42, 8, closed=False,
                                         up=(0, 1, 0.14), cap=False, squash=0.65))

    headlights(car)
    bumper_front(car)
    plate_front(car)
    valance_lamps(car)
    fender_markers(car)


def _grille_span_z(x, inset):
    poly = grille_outline(inset, 16)
    zs = []
    for i in range(len(poly)):
        a, b = poly[i], poly[(i + 1) % len(poly)]
        if (a[0] - x) * (b[0] - x) <= 0 and a[0] != b[0]:
            t = (x - a[0]) / (b[0] - a[0])
            zs.append(a[1] + t * (b[1] - a[1]))
    return (min(zs), max(zs)) if zs else (0, 0)


def _grille_span_x(z, inset):
    poly = grille_outline(inset, 16)
    xs = []
    for i in range(len(poly)):
        a, b = poly[i], poly[(i + 1) % len(poly)]
        if (a[1] - z) * (b[1] - z) <= 0 and a[1] != b[1]:
            t = (z - a[1]) / (b[1] - a[1])
            xs.append(a[0] + t * (b[0] - a[0]))
    return (min(xs), max(xs)) if xs else (0, 0)


def headlamp(car, center, axis, lens_r=2.85):
    """Lens with a chrome retaining ring, facing along axis."""
    axis = np.asarray(axis, float) / np.linalg.norm(axis)
    c = np.asarray(center, float)
    # slightly domed lens
    prof = [(0.0, 0.35), (1.2, 0.3), (2.2, 0.17), (lens_r, 0.0)]
    m = lathe(prof[::-1], c, axis, 28)
    car.add("Headlights", "Lens", m)
    ring = [(lens_r + 0.4, -0.15), (lens_r + 0.3, 0.1), (lens_r + 0.05, 0.12), (lens_r - 0.15, -0.1)]
    car.add("Trim_Chrome", "Chrome", lathe(ring, c, axis, 28))


def headlights(car):
    # outer lamps sit in body-coloured buckets in the fenders, turned 15 degrees outward
    cx, cz = body.HEADLIGHT_OUT
    a = math.radians(15)
    axis = np.array([math.sin(a), math.cos(a), 0.0])
    u, v, n = ring_frame(None, axis)
    ang = np.linspace(0, 2 * math.pi, 40, endpoint=False)
    hole = np.stack([cx + body.HEADLIGHT_HOLE_R * np.cos(ang), cz + body.HEADLIGHT_HOLE_R * np.sin(ang)], 1)
    rim = face_point(hole[:, 0], hole[:, 1], 0.0)
    center_face = face_point(cx, cz)
    lens_c = center_face - axis * 1.9
    # v runs outboard (+X) and u up, matching the hole's (x, z) parametrization
    back = lens_c - axis * 0.3 + 3.35 * (np.cos(ang)[:, None] * v + np.sin(ang)[:, None] * u)
    mid = lens_c + axis * 0.9 + 3.45 * (np.cos(ang)[:, None] * v + np.sin(ang)[:, None] * u)
    bucket = flip(loft_loops([rim, mid, back], True))
    both(car, "Body", "Paint", bucket)
    m = HeadSink()
    headlamp(m, lens_c, axis)
    for name, (mat, meshes) in m.parts.items():
        for mesh in meshes:
            both(car, name, mat, mesh)

    # inner lamps sit in the grille in black bezels
    ix, iz = body.HEADLIGHT_IN
    face = face_point(ix, iz)
    axis = np.array([0.0, 1.0, 0.0])
    lens_c = face - axis * 1.5
    bez = [(3.75, -GRILLE_DEPTH + 1.4), (3.75, -0.05), (3.55, 0.12), (3.15, 0.1), (3.0, -0.1)]
    m = HeadSink()
    m.add("Grille", "Black", lathe(bez, lens_c + axis * 0.0, axis, 32))
    headlamp(m, lens_c, axis, 2.75)
    for name, (mat, meshes) in m.parts.items():
        for mesh in meshes:
            both(car, name, mat, mesh)


class HeadSink:
    def __init__(self):
        self.parts = {}

    def add(self, name, mat, mesh):
        self.parts.setdefault(name, [mat, []])[1].append(mesh)


def bumper_y(x):
    x = np.abs(np.asarray(x, float))
    return 94.4 - 0.0018 * x * x - 0.05 * np.maximum(0, x - 23) ** 2 - 0.035 * (np.sqrt(x * x + 4) - 2)


def bumper_front(car):
    xs = np.linspace(-33.2, 33.2, 67)
    pts = [(x, bumper_y(x)) for x in xs]
    # wrap around the corners and run back along the fenders
    def wrap(sign):
        x0, y0 = 33.2, float(bumper_y(33.2))
        out = []
        for t in np.linspace(0.15, 1, 7):
            ang = t * math.radians(70)
            out.append((sign * (x0 + 2.2 * math.sin(ang)), y0 - 2.4 * (1 - math.cos(ang)) - 2.5 * t * t))
        x1, y1 = out[-1]
        out.append((sign * (abs(x1) + 0.1), y1 - 2.0))
        return out
    left = wrap(-1)[::-1]
    right = wrap(1)
    plan = np.array(left + pts + right)
    path = np.stack([plan[:, 0], plan[:, 1], np.zeros(len(plan))], 1)
    # profile in (n, b): n along the in-plane normal, b up. Swept with up = z, the path frame
    # N is world z, B = T x N points forward/outward for a left-to-right path.
    prof = [(21.6, -2.6), (21.7, -0.5), (21.6, 0.2), (21.2, 0.75), (20.2, 0.95), (19.0, 0.9),
            (18.3, 0.6), (17.95, 0.1), (17.9, -0.6), (17.95, -2.6)]
    prof = [(z, -b) for z, b in prof][::-1]
    m = swept(path, prof, up=(0, 0, 1), closed_profile=True, cap=True, angle=35)
    car.add("Bumpers", "Chrome", m)


def plate_front(car):
    z = 14.4
    plate(car, center=(-2.5, float(body.nose_y(2.5, z)) + 0.55, z), facing=1)


def plate(car, center, facing):
    """Danish plate: 520 x 110 mm, white with a red border and black letters."""
    cx, cy, cz = center
    w, h, t = 20.47, 4.33, 0.12
    V, T = box((cx, cy, cz), (w, t, h))
    car.add("Plates", "PlateWhite", flat(V, T))
    fy = cy + facing * (t / 2 + 0.03)
    bw = 0.2
    for (x0, x1, z0, z1) in [(-w / 2 + 0.15, w / 2 - 0.15, h / 2 - 0.15 - bw, h / 2 - 0.15),
                             (-w / 2 + 0.15, w / 2 - 0.15, -h / 2 + 0.15, -h / 2 + 0.15 + bw),
                             (-w / 2 + 0.15, -w / 2 + 0.15 + bw, -h / 2 + 0.15, h / 2 - 0.15),
                             (w / 2 - 0.15 - bw, w / 2 - 0.15, -h / 2 + 0.15, h / 2 - 0.15)]:
        V, T = box((cx + (x0 + x1) / 2, fy, cz + (z0 + z1) / 2), (x1 - x0, 0.04, z1 - z0))
        car.add("PlateBorders", "PlateRed", flat(V, T))
    letters = text.text_mesh("DT 67375", size=3.55, depth=0.05)
    letters = text.place_on_plane(letters, center=(cx, fy + facing * 0.02, cz - 0.05), facing=facing,
                                  width=w - 2.2, height=3.0)
    car.add("Trim_Black", "Black", letters)


def valance_lamps(car):
    for x0 in (14.5,):
        z = 14.6
        y = float(body.nose_y(x0 + 3, z)) + 0.1
        V, T = box((x0 + 3.0, y, z), (6.0, 0.5, 1.6))
        both(car, "Headlights", "Lens", flat(V, T))


def fender_markers(car):
    # front amber side marker ahead of the front wheel
    y, z = 77.0, 24.8
    x = float(body.body_x_at([y], [z])[0])
    V, T = box((x + 0.05, y, z), (0.3, 2.6, 1.0))
    both(car, "Lamps_Amber", "Amber", flat(V, T))


# --------------------------------------------------------------------------
# Hood scoop (Mach 1 style, painted white with the stripes)
# --------------------------------------------------------------------------

SCOOP = dict(y0=42.5, y1=61.5, half=8.6, h=2.4)


def hood_z(x, y):
    y = np.atleast_1d(np.asarray(y, float))
    x = np.broadcast_to(np.asarray(x, float), y.shape)
    s = body.s_of_x(y, x)
    _, z = body.lb_profile(y, s)
    return z


def _scoop_height(x, y):
    sc = SCOOP
    t = np.clip((y - sc["y0"]) / (sc["y1"] - sc["y0"]), 0, 1)
    half = sc["half"] - 2.2 * (1 - t)
    across = 1 - smoothstep(half - 2.2, half, np.abs(x))
    return sc["h"] * (t ** 1.4) * across


def hood_scoop(car):
    sc = SCOOP
    # top skin over the hood, sampled on a grid
    ys = np.linspace(sc["y0"], sc["y1"], 26)
    xs = np.linspace(-sc["half"], sc["half"], 35)
    Y, X = np.meshgrid(ys, xs, indexing="ij")
    Z = np.empty_like(X)
    for i, y in enumerate(ys):
        Z[i] = hood_z(xs, np.full(len(xs), y)) + _scoop_height(xs, y) + 0.1
    loops = [np.stack([X[i], Y[i], Z[i]], 1) for i in range(len(ys))]
    top = loft_loops(loops, closed=False, angle=70)
    car.add("Stripes", "Stripe", fix_out(top, (0, 0, 1)))
    # front face: white lip around a black opening
    y1 = sc["y1"]
    zb = hood_z(xs, np.full(len(xs), y1)) + 0.1
    zt = zb + _scoop_height(xs, y1)
    face_lo = np.stack([xs, np.full(len(xs), y1), zb], 1)
    face_hi = np.stack([xs, np.full(len(xs), y1), zt], 1)
    car.add("Stripes", "Stripe", fix_out(loft_loops([face_hi, face_lo], closed=False), (0, 1, 0)))
    inner = np.abs(xs) < sc["half"] - 2.0
    xi = xs[inner]
    zi_lo = zb[inner] + 0.3
    zi_hi = zt[inner] - 0.3
    lo = np.stack([xi, np.full(len(xi), y1 + 0.02), zi_lo], 1)
    hi = np.stack([xi, np.full(len(xi), y1 + 0.02), zi_hi], 1)
    car.add("Trim_Black", "Black", fix_out(loft_loops([hi, lo], closed=False), (0, 1, 0)))


# --------------------------------------------------------------------------
# Wheels: 14 in slotted aluminum wheels on raised-white-letter radials
# --------------------------------------------------------------------------

TIRE_R = 13.0
RIM_R = 7.5


def tire_mesh():
    # (r, w) with w toward the outer face; walk so the outside is on the right
    prof = [(7.75, -3.75), (8.2, -4.3), (9.2, -4.5), (10.8, -4.55), (12.1, -4.4), (12.75, -4.05),
            (12.97, -3.5), (13.0, -2.0), (13.0, 2.0), (12.97, 3.5), (12.75, 4.05), (12.1, 4.4),
            (10.8, 4.55), (9.2, 4.5), (8.2, 4.3), (7.75, 3.75)]
    return lathe(prof, (0, 0, 0), (1, 0, 0), 48, up=(0, 0, 1), angle=40)


def tire_letters(side):
    """'PERFORMANCE' over the top and 'STREET RADIAL' under the bottom, raised white letters."""
    out = []
    r = 10.45
    for word, ang in (("PERFORMANCE", math.pi / 2), ("STREET RADIAL", -math.pi / 2)):
        m = text.text_mesh(word, size=1.0, depth=0.08, resolution=2)
        out.append(text.wrap_on_circle(m, r, ang, 4.78 * side, side, height=0.95))
    from geom import merge_parts
    return merge_parts(out)


def rim_face(side):
    """Dished aluminum face with five slots, in the wheel's own frame (axis +X = outward)."""
    def depth(r):
        # outer lip at the face, dish falling to the mounting face, hub boss in the middle
        return np.interp(r, [0, 1.9, 2.6, 3.2, 6.5, 7.1, 7.5], [1.55, 1.55, 0.95, 0.55, 0.15, 0.6, 1.3])

    def fn(uv):
        uv = np.atleast_2d(uv)
        rr = np.hypot(uv[:, 0], uv[:, 1])
        return np.stack([depth(rr) * side, uv[:, 0], uv[:, 1]], 1)

    slots = []
    for k in range(5):
        a0 = math.radians(90 + 72 * k)
        # a slot between two arcs
        outer = [(5.5 * math.cos(a0 + math.radians(t)), 5.5 * math.sin(a0 + math.radians(t)))
                 for t in np.linspace(-16, 16, 12)]
        inner = [(3.7 * math.cos(a0 + math.radians(t)), 3.7 * math.sin(a0 + math.radians(t)))
                 for t in np.linspace(16, -16, 12)]
        slots.append((np.array(outer + inner), None))
    boundary = circle(0, 0, RIM_R, 64)
    p = Patch(fn, boundary, "face", step=0.8, zones=slots, mirror=False, edge_step=0.5, flip=side < 0)
    return p.build()["face"]


def wheel_parts(side):
    """All meshes of one wheel at the origin, axis along X, outer face toward side*X."""
    parts = {}
    parts["Tire"] = ("Rubber", [tire_mesh()])
    parts["TireLetters"] = ("Letters", [tire_letters(side)])
    face = rim_face(side)
    face = transform(face, mat_trs((side * 1.9, 0, 0)))
    # barrel and polished lip
    lip = [(7.05, 3.25), (7.55, 3.35), (8.2, 3.3), (8.3, 3.05), (7.8, 2.75), (7.55, 2.0)]
    barrel = [(7.55, 2.0), (7.5, -3.4), (7.1, -3.4)]
    if side < 0:
        lip = [(r, -w) for r, w in lip][::-1]
        barrel = [(r, -w) for r, w in barrel][::-1]
    parts["Rim"] = ("Aluminum", [face, lathe(barrel, (0, 0, 0), (1, 0, 0), 48)])
    chrome = [lathe(lip, (0, 0, 0), (1, 0, 0), 48)]
    # centre cap and five lug nuts
    cap = [(1.55, 0.0), (1.5, 0.45), (1.1, 1.0), (0.45, 1.3), (0.0, 1.35)]
    cap = [(r, w * side + side * 3.45) for r, w in cap]
    if side < 0:
        cap = cap[::-1]
    chrome.append(lathe(cap, (0, 0, 0), (1, 0, 0), 24))
    for k in range(5):
        a = math.radians(90 + 36 + 72 * k)
        c = np.array([side * 3.35, 2.45 * math.cos(a), 2.45 * math.sin(a)])
        nut = [(0.42, -0.1), (0.42, 0.5), (0.3, 0.68), (0.0, 0.7)]
        nut = [(r, w * side) for r, w in nut]
        if side < 0:
            nut = nut[::-1]
        chrome.append(lathe(nut, c, (1, 0, 0), 6, angle=30))
    parts["RimChrome"] = ("Chrome", chrome)
    # dark brake/backing disc seen through the slots
    parts["Tire"][1].append(disc((side * 0.6, 0, 0), (side, 0, 0), 7.1, 32))
    return parts


def wheels(car, steer=0.0):
    for side in (-1, 1):
        wp = wheel_parts(side)
        for key, y in body.WHEELS.items():
            name = ("L" if side < 0 else "R") + key
            rz = math.radians(steer) if key == "F" else 0.0
            M = mat_trs((side * body.TRACK / 2, y, body.WHEEL_Z)) @ mat_trs(rz=rz)
            for part, (mat, meshes) in wp.items():
                for m in meshes:
                    car.add(f"{part}_{name}", mat, transform(m, M))


# --------------------------------------------------------------------------
# Body side: mirrors, door handles, quarter scoops, badges, markers, wipers
# --------------------------------------------------------------------------

def side_details(car):
    mirrors(car)
    door_handles(car)
    quarter_scoops(car)
    badges(car)
    wipers(car)
    rear_markers(car)


def mirrors(car):
    """Color-keyed bullet racing mirrors on both doors."""
    base_y = body.Y_COWL - 4.0
    base_z = float(body.zs_t(base_y))
    base_x = float(body.xs_t(base_y))
    head_c = np.array([base_x + 3.0, base_y - 1.2, base_z + 2.9])
    # stem
    stem = tube(np.array([[base_x - 0.3, base_y, base_z + 0.1], [base_x + 1.4, base_y - 0.5, base_z + 1.6],
                          head_c + [-0.4, 0.6, -0.9]]), 0.42, 8, up=(0, 1, 0))
    both(car, "Mirrors", "Paint", stem)
    foot = lathe([(1.0, 0.0), (0.9, 0.25), (0.5, 0.4), (0.0, 0.42)], (base_x - 0.1, base_y, base_z - 0.1), (0, 0, 1), 16)
    both(car, "Mirrors", "Paint", foot)
    # bullet head pointing forward, glass at the back
    prof = [(1.85, -2.0), (1.95, -1.4), (1.8, 0.0), (1.35, 1.2), (0.7, 1.9), (0.0, 2.15)]
    head = lathe(prof, head_c, (0, 1, 0), 24)
    both(car, "Mirrors", "Paint", head)
    both(car, "Trim_Chrome", "Chrome", disc(head_c + [0, -2.02, 0], (0, -1, 0), 1.75, 24))


def door_handles(car):
    y0, y1, z = -13.6, -8.9, 32.7
    ys = np.linspace(y0, y1, 6)
    xs = body.body_x_at(ys, np.full(len(ys), z))
    path = np.stack([xs + 0.12, ys, np.full(len(ys), z)], 1)
    prof = [(0.45, 0.0), (0.4, 0.28), (0.0, 0.36), (-0.4, 0.28), (-0.45, 0.0)]
    # path runs +Y, up = +X gives N = +X (out of the body), B = T x N = -Z... use explicit loops
    loops = [p + np.array([[b, 0, a] for a, b in prof]) for p in path]
    m = loft_loops(loops, closed=False, cap_start=True, cap_end=True, angle=60)
    car.add("Trim_Chrome", "Chrome", fix_out(m, (1, 0, 0)))
    car.add("Trim_Chrome", "Chrome", fix_out(mirror_x(m), (-1, 0, 0)))


def fix_out(mesh, direction):
    """Flip triangles whose normal points against direction (for small convex trims)."""
    V, T, N = mesh
    a, b, c = V[T[:, 0]], V[T[:, 1]], V[T[:, 2]]
    fn = np.cross(b - a, c - a)
    bad = (fn @ np.asarray(direction, float)) < -1e-9
    T = T.copy()
    N = N.copy()
    T[bad] = T[bad][:, [0, 2, 1]]
    N[bad] = -N[bad][:, [0, 2, 1]]
    return V, T, N


def quarter_scoops(car):
    """The dummy side scoop on each rear quarter, opening forward."""
    y_front, y_back = -18.4, -29.0
    z0, z1 = 29.4, 34.0
    ys = np.linspace(y_front, y_back, 14)
    zs = np.linspace(z0, z1, 9)
    loops = []
    for y in ys:
        t = (y - y_back) / (y_front - y_back)
        bx = body.body_x_at(np.full(len(zs), y), zs)
        across = np.sin(np.linspace(0, math.pi, len(zs))) ** 0.5
        h = 1.05 * t ** 0.8 * across + 0.02
        loops.append(np.stack([bx + h, np.full(len(zs), y), zs], 1))
    skin = loft_loops(loops, closed=False, angle=70)
    skin = fix_out(skin, (1, 0, 0))
    both(car, "Body", "Paint", skin)
    # opening: a black face across the front of the blister, inset from its edges
    front = loops[0]
    bx = body.body_x_at(np.full(len(zs), y_front), zs)
    inner = np.stack([bx + 0.1, np.full(len(zs), y_front + 0.01), zs], 1)
    lip = front.copy()
    lip[:, 0] = bx + (front[:, 0] - bx) * 0.25
    lip[:, 1] += 0.01
    face = loft_loops([front, lip], closed=False)
    face = fix_out(face, (0, 1, 0))
    both(car, "Body", "Paint", face)
    hole = loft_loops([lip, inner], closed=False)
    both(car, "Trim_Black", "Black", fix_out(hole, (0, 1, 0)))


def badges(car):
    """'Mustang' script on each front fender, behind the wheel."""
    y, z = 33.6, 27.0
    m = text.text_mesh("Mustang", size=1.0, depth=0.12, resolution=2, italic=True)
    V, T, N = m
    lo, hi = V.min(0), V.max(0)
    sc = 5.2 / (hi[0] - lo[0])
    P = (V - (lo + hi) / 2) * sc
    # seen from the right the text runs toward the front (+Y); from the left, toward the back
    x = float(body.body_x_at([y], [z])[0])
    world = np.stack([x + 0.08 + P[:, 2], y + P[:, 0], z + P[:, 1]], 1)
    mm = fix_out(flat(world, T), (1, 0, 0))
    car.add("Trim_Chrome", "Chrome", mm)
    worldL = np.stack([-(x + 0.08 + P[:, 2]), y - P[:, 0], z + P[:, 1]], 1)
    car.add("Trim_Chrome", "Chrome", fix_out(flat(worldL, T), (-1, 0, 0)))


def rear_markers(car):
    y, z = -80.0, 24.6
    x = float(body.body_x_at([y], [z])[0])
    V, T = box((x + 0.05, y, z), (0.3, 2.6, 1.0))
    both(car, "Lamps_Red", "TailLens", flat(V, T))


def wipers(car):
    """Two wipers parked along the bottom of the windshield."""
    for x0, x1 in ((-25.0, -8.5), (-5.0, 13.5)):
        xs = np.linspace(x0, x1, 8)
        ys = np.full(len(xs), body.Y_COWL - 1.5)
        pts = body.top_map(np.stack([ys, np.abs(xs)], 1))
        pts[:, 0] = xs
        pts[:, 2] += 0.35
        car.add("Trim_Black", "Black", tube(pts, 0.17, 6, up=(0, 0, 1), squash=1.0))
        # arm back to the cowl pivot
        mid = pts[len(pts) // 2]
        pivot = np.array([mid[0] + 3.0, body.Y_COWL + 0.6, float(body.zc_t(body.Y_COWL + 0.6)) + 0.4])
        car.add("Trim_Black", "Black", tube(np.array([pivot, mid + [0, 0, 0.25]]), 0.2, 6))


# --------------------------------------------------------------------------
# Wheel wells and underbody
# --------------------------------------------------------------------------

def wheel_wells(car):
    """Black tubs behind each wheel opening, so the arches don't show the inside of the shell."""
    for key in ("F", "R"):
        yw, r = body.WHEELS[key], body.ARCH_R[key]
        a = np.linspace(-0.05, math.pi + 0.05, 40)
        ys = yw + (r + 0.05) * np.cos(a)
        zs = body.WHEEL_Z + (r + 0.05) * np.sin(a)
        zr = float(body.zr_t(yw)) - 0.4
        # straight down to the floor at both ends of the arch
        ys = np.concatenate([[ys[0]], ys, [ys[-1]]])
        zs = np.concatenate([[zr], zs, [zr]])
        outer_x = body.body_x_at(ys, np.maximum(zs, body.zr_t(ys) + 0.2)) - 0.15
        inner_x = np.full(len(ys), 21.0)
        outer = np.stack([outer_x, ys, zs], 1)
        inner = np.stack([inner_x, ys, zs], 1)
        tub = loft_loops([outer, inner], closed=False, angle=60)
        center = np.array([28.0, yw, body.WHEEL_Z])
        V, T, N = tub
        cen = V[T].mean(1)
        a_, b_, c_ = V[T[:, 0]], V[T[:, 1]], V[T[:, 2]]
        fn = np.cross(b_ - a_, c_ - a_)
        to_c = center - cen
        to_c[:, 0] = 0
        bad = (fn * to_c).sum(1) < 0
        T = T.copy()
        T[bad] = T[bad][:, [0, 2, 1]]
        tub = smooth_mesh(V, T, 60)
        both(car, "Underbody", "Underbody", tub)
        # inner wall closing the tub toward the engine bay / cabin
        wall = np.stack([np.full(len(ys), 21.0), ys, zs], 1)
        Vw = np.concatenate([wall, [[21.0, yw, zr]]])
        Tw = np.array([(len(wall), i, i + 1) for i in range(len(wall) - 1)])
        both(car, "Underbody", "Underbody", fix_out(flat(Vw, Tw), (1, 0, 0)))


def underbody(car):
    ys = np.linspace(body.Y_TAIL, 87.0, 60)
    zr = body.zr_t(ys) - 0.4
    left = np.stack([np.full(len(ys), -20.0), ys, zr], 1)
    right = np.stack([np.full(len(ys), 20.0), ys, zr], 1)
    m = loft_loops([left, right], closed=False)
    car.add("Underbody", "Underbody", fix_out(m, (0, 0, -1)))


# --------------------------------------------------------------------------
# Rear end
# --------------------------------------------------------------------------

TAIL_Z = (27.6, 33.6)
TAIL_X = (13.4, 24.6)


def rear_end(car):
    y = body.Y_TAIL
    # chrome bezel around each group of three lamps, standing 0.5 in proud of the panel
    x0, x1 = TAIL_X
    z0, z1 = TAIL_Z
    outline = rounded_rect(x0, z0, x1, z1, 0.6, 3)
    front = np.stack([outline[:, 0], np.full(len(outline), y - 0.55), outline[:, 1]], 1)
    back = np.stack([outline[:, 0], np.full(len(outline), y + 0.05), outline[:, 1]], 1)
    rim = fix_out_radial(loft_loops([back, front], True, angle=50), np.array([(x0 + x1) / 2, y, (z0 + z1) / 2]))
    both(car, "Trim_Chrome", "Chrome", rim)
    # bezel face with three lamp openings, plus the lenses set slightly back
    w = (x1 - x0 - 0.8 - 2 * 0.45) / 3
    lamps = []
    for i in range(3):
        lx0 = x0 + 0.4 + i * (w + 0.45)
        lamps.append(rounded_rect(lx0, z0 + 0.45, lx0 + w, z1 - 0.45, 0.35, 3))
    fn = lambda uv: np.stack([np.atleast_2d(uv)[:, 0], np.full(len(np.atleast_2d(uv)), y - 0.55), np.atleast_2d(uv)[:, 1]], 1)
    face = Patch(fn, outline, "chrome", step=1.0, zones=[(l, None) for l in lamps], mirror=True, edge_step=0.5)
    for k, m in face.build().items():
        car.add("Trim_Chrome", "Chrome", m)
    for l in lamps:
        lv = np.stack([l[:, 0], np.full(len(l), y - 0.35), l[:, 1]], 1)
        V = np.concatenate([lv, [lv.mean(0)]])
        n = len(lv)
        T = np.array([(n, i, (i + 1) % n) for i in range(n)])
        both(car, "Lamps_Red", "TailLens", fix_out(flat(V, T), (0, -1, 0)))
        # inner walls of the lamp cell
        lb = lv.copy()
        lb[:, 1] = y - 0.56
        both(car, "Lamps_Red", "TailLens", fix_out_radial(loft_loops([lv, lb], True), lv.mean(0), inward=True))
    # pop-open gas cap in the middle of the panel
    cap = [(2.45, 0.0), (2.45, 0.25), (2.2, 0.45), (1.6, 0.55), (0.0, 0.6)]
    car.add("Trim_Chrome", "Chrome", lathe(cap, (0, y, 30.6), (0, -1, 0), 32))
    bumper_rear(car)
    plate(car, center=(0.0, y - 0.6, 16.6), facing=-1)
    # exhaust tips through the valance
    for sx in (-1, 1):
        c = np.array([sx * 17.5, y + 2.0, 12.9])
        tip = [(1.3, 0.0), (1.3, 4.2), (1.12, 4.25), (1.08, 3.0)]
        car.add("Trim_Chrome", "Chrome", lathe(tip, c, (0, -1, 0), 20))
        car.add("Underbody", "Underbody", disc(c + [0, -3.2, 0], (0, -1, 0), 1.1, 20))


def fix_out_radial(mesh, center, inward=False):
    V, T, N = mesh
    a, b, c = V[T[:, 0]], V[T[:, 1]], V[T[:, 2]]
    fn = np.cross(b - a, c - a)
    d = (a + b + c) / 3 - center
    bad = (fn * d).sum(1) < 0
    if inward:
        bad = ~bad
    T = T.copy()
    T[bad] = T[bad][:, [0, 2, 1]]
    return smooth_mesh(V, T, 50)


def bumper_rear(car):
    def by(x):
        x = np.abs(np.asarray(x, float))
        return body.Y_TAIL - 2.2 + 0.0012 * x * x + 0.02 * np.maximum(0, x - 25) ** 2
    xs = np.linspace(-32.5, 32.5, 53)
    pts = [(x, float(by(x))) for x in xs]

    def wrap(sign):
        x0, y0 = 32.5, float(by(32.5))
        out = []
        for t in np.linspace(0.15, 1, 7):
            ang = t * math.radians(75)
            out.append((sign * (x0 + 2.6 * math.sin(ang)), y0 + 2.6 * (1 - math.cos(ang)) + 3.0 * t * t))
        x1, y1 = out[-1]
        out.append((sign * (abs(x1) + 0.05), y1 + 2.0))
        return out
    plan = np.array(wrap(-1)[::-1] + pts + wrap(1))
    path = np.stack([plan[:, 0], plan[:, 1], np.zeros(len(plan))], 1)
    # path runs -X to +X along the back; B = T x Z = -Y... for this path T = +X so B = -Y = outward
    prof = [(23.7, -2.4), (23.8, -0.4), (23.6, 0.3), (23.1, 0.75), (22.0, 0.9), (20.8, 0.85),
            (20.1, 0.5), (19.8, 0.0), (19.8, -2.4)]
    m = swept(path, [(z, b) for z, b in prof], up=(0, 0, 1), closed_profile=True, cap=True, angle=35)
    car.add("Bumpers", "Chrome", m)
