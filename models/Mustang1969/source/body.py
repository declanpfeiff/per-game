"""Body shell of the 1969 Mustang SportsRoof.

Units are inches. +Y is forward, +X is the car's right (passenger side),
+Z is up and Z = 0 is the ground. The axles sit at Y = +54 and Y = -54
(108 in wheelbase). The body runs from the tail panel at Y = -93.6 to the
hood's leading edge at Y = +91.6, and the bumpers add the rest of the
187.4 in overall length.

The shell is made of five surfaces:
  lower body   hood, fenders, doors and quarters (lofted cross-sections)
  green side   side glass, pillars and sail panels (ruled, belt -> roof edge)
  green top    windshield, roof, backlight and deck lid
  fascia       the front face around the grille and headlights
  tail         the rear panel
"""

import math

import numpy as np

from geom import Patch, Table, pchip_rows, smoothstep, lerp, rounded_rect, circle, offset_poly

# --------------------------------------------------------------------------
# Key dimensions
# --------------------------------------------------------------------------

Y_TAIL = -93.6          # rear panel
Y_NOSE_N = 89.0         # nominal end of the lofted lower body
Y_HOOD = 93.0           # hood leading edge (after the nose blend)
NOSE_BLEND = 70.5       # the lower body bends toward the front face from here
Y_COWL = 28.5           # windshield base
Y_HEADER = 7.8          # windshield top
Y_DOOR = 27.0           # door front edge (the rear edge is at -16.6)
WHEELS = {"F": 54.0, "R": -54.0}
WHEEL_Z = 13.0
TRACK = 58.5
ARCH_R = {"F": 15.4, "R": 15.5}

# Le Mans stripes: two 9 in white stripes 3.6 in apart, each edged with a thin pinstripe
STRIPES = [(1.0, 1.35), (1.8, 10.8), (11.25, 11.6)]

# --------------------------------------------------------------------------
# Lower body cross-section
# --------------------------------------------------------------------------

xs_t = Table([(-93.6, 33.5), (-85, 34.3), (-70, 34.8), (-54, 35.0), (-35, 34.8), (-17, 34.65),
              (0, 34.6), (20, 34.6), (28.5, 34.6), (54, 34.4), (75, 34.0), (89, 33.4)])
zs_t = Table([(-93.6, 36.5), (-80, 36.25), (-54, 35.7), (-35, 35.2), (-17, 34.8), (0, 34.5),
              (20, 34.3), (28.5, 34.2), (54, 33.25), (75, 32.0), (89, 30.8)])
zc_t = Table([(-93.6, 31.0), (8, 31.5), (19.5, 34.2), (23.5, 35.5), (28.5, 35.9), (40, 35.55), (54, 34.7),
              (70, 33.4), (89, 31.4)])
xh_t = Table([(-93.6, 28.5), (23.5, 29.0), (28.5, 29.0), (54, 28.4), (89, 27.0)])
crown_t = Table([(-93.6, 1.0), (28.5, 1.25), (89, 0.9)])
xm_t = Table([(-93.6, 35.1), (-80, 35.6), (-54, 35.65), (0, 35.55), (54, 35.65), (80, 35.45), (89, 35.0)])
zm_t = Table([(-93.6, 22.0), (-70, 21.0), (70, 21.0), (89, 22.0)])
xr_t = Table([(-93.6, 33.9), (-54, 34.3), (0, 34.2), (54, 34.3), (89, 33.5)])
zr_t = Table([(-93.6, 12.2), (-75, 11.2), (-54, 9.6), (-38, 8.9), (0, 8.7), (38, 8.9), (54, 9.6),
              (75, 10.8), (89, 11.2)])

N_CTRL = 13
ZU = 28.6                # height of the body-side character line
CREASES = (4, 6, 10)     # shoulder crease, body-side character line, rocker corner


def lb_ctrl(y):
    y = np.atleast_1d(np.asarray(y, float))
    zc, xh, cr = zc_t(y), xh_t(y), crown_t(y)
    xs, zs = xs_t(y), zs_t(y)
    xm, zm = xm_t(y), zm_t(y)
    xr, zr = xr_t(y), zr_t(y)
    zf = np.maximum(zc - cr, zs) + 0.12
    X = np.stack([0 * y, 0.5 * xh, xh, xh + 0.55 * (xs - xh), xs, xs + 0.55, xm, xm - 0.3, xm - 1.0,
                  xr, xr - 0.5, xr - 3.0, 20 + 0 * y], 1)
    Z = np.stack([zc, zc - 0.28 * cr, zc - cr, zf, zs, zs - 1.4, ZU + 0 * y, zm, 15.5 + 0 * y,
                  zr + 1.4, zr, zr - 0.3, zr - 0.4], 1)
    return X, Z


def _knots():
    X, Z = lb_ctrl([60.0])
    d = np.hypot(np.diff(X[0]), np.diff(Z[0]))
    k = np.concatenate([[0], np.cumsum(d)])
    return k / k[-1], k[-1]


SK, W_LB = _knots()
PIECES = list(zip((0,) + CREASES, CREASES + (N_CTRL - 1,)))
S4 = SK[CREASES[0]]
S2 = SK[2]


def lb_profile(y, s):
    """x, z of the lower body section at stations y and parameters s (0..1)."""
    y = np.atleast_1d(np.asarray(y, float))
    s = np.broadcast_to(np.asarray(s, float), y.shape).copy()
    X, Z = lb_ctrl(y)
    x = np.zeros_like(y)
    z = np.zeros_like(y)
    for i, (k0, k1) in enumerate(PIECES):
        m = (s >= SK[k0]) & (s <= SK[k1]) if i == 0 else (s > SK[k0]) & (s <= SK[k1])
        if i == 0:
            m |= s < 0
        if i == len(PIECES) - 1:
            m |= s > 1
        if not m.any():
            continue
        kn = SK[k0:k1 + 1]
        q = np.clip(s[m], kn[0], kn[-1])
        x[m] = pchip_rows(kn, X[m][:, k0:k1 + 1], q)
        z[m] = pchip_rows(kn, Z[m][:, k0:k1 + 1], q)
    return x, z


def nose_y(x, z):
    """The front face: leans back toward the bottom, sweeps back around the outer headlights,
    and the valance below the bumper tucks in."""
    x = np.abs(np.asarray(x, float))
    z = np.asarray(z, float)
    return (Y_HOOD - 0.14 * (31.4 - z) - 0.0018 * x * x - 0.05 * np.maximum(0, x - 23) ** 2
            - 0.45 * np.maximum(0, 18.5 - z))


def lb_map(uv):
    uv = np.atleast_2d(uv)
    yn, s = uv[:, 0], uv[:, 1] / W_LB
    x, z = lb_profile(yn, s)
    blend = np.clip((yn - NOSE_BLEND) / (Y_NOSE_N - NOSE_BLEND), 0, 1) ** 2
    y = yn + (nose_y(x, z) - Y_NOSE_N) * blend
    return np.stack([x, y, z], 1)


def _invert(y, target, comp, s_lo, s_hi, n=600):
    """s in [s_lo, s_hi] where the section's x (comp 0) or z (comp 1) hits target."""
    y = np.atleast_1d(np.asarray(y, float))
    target = np.broadcast_to(np.asarray(target, float), y.shape)
    ss = np.linspace(s_lo, s_hi, n)
    Y = np.repeat(y, n)
    S = np.tile(ss, len(y))
    x, z = lb_profile(Y, S)
    vals = (x if comp == 0 else z).reshape(len(y), n)
    out = np.empty(len(y))
    for i in range(len(y)):
        v = vals[i]
        if v[-1] < v[0]:
            out[i] = np.interp(target[i], v[::-1], ss[::-1])
        else:
            out[i] = np.interp(target[i], v, ss)
    return out


def s_of_x(y, x):
    return _invert(y, x, 0, 0.0, S4)


def s_of_z(y, z):
    return _invert(y, z, 1, S4, SK[CREASES[-1]])


def body_x_at(y, z):
    """Outer surface x of the body side at (y, z)."""
    s = s_of_z(y, z)
    x, _ = lb_profile(np.atleast_1d(y), s)
    return x


def arch_outline(key, n=48):
    """Wheel opening in the side view, as (y, z) points over the top, open at the bottom."""
    yw, r = WHEELS[key], ARCH_R[key]
    a = np.linspace(0, math.pi, n)
    return np.stack([yw + r * np.cos(a), WHEEL_Z + r * np.sin(a)], 1)


def strip(line, hw):
    """Closed polygon around an open polyline, hw to each side."""
    line = np.asarray(line, float)
    d = np.gradient(line, axis=0)
    d /= np.maximum(np.linalg.norm(d, axis=1, keepdims=True), 1e-12)
    n = np.stack([-d[:, 1], d[:, 0]], 1)
    return np.concatenate([line + n * hw, (line - n * hw)[::-1]])


def lower_body(step=2.6):
    W = W_LB
    w4 = S4 * W
    w2 = S2 * W
    zones = []
    # cabin: everything inboard of the shoulder behind the cowl is under the greenhouse
    zones.append(([(-120, -5), (-120, w4), (Y_COWL - 5, w4), (Y_COWL - 5, -5)], None))
    zones.append(([(Y_COWL - 5.1, w2), (Y_COWL - 5.1, w4), (Y_COWL, w4), (Y_COWL, w2)], None))
    # wheel openings, and the chrome lip around them
    for key in ("F", "R"):
        ol = arch_outline(key)
        sw = s_of_z(ol[:, 0], ol[:, 1]) * W
        hole = np.concatenate([[[ol[0, 0], W + 6]], np.stack([ol[:, 0], sw], 1), [[ol[-1, 0], W + 6]]])
        zones.append((hole[::-1], None))
        zones.append((arch_lip_poly(key, 0.6), "chrome"))
    # cowl under the windshield
    zones.append(([(Y_COWL - 5.1, -5), (Y_COWL - 5.1, w2), (Y_COWL + 0.2, w2), (Y_COWL + 0.2, -5)], "black"))
    # hood gaps
    ys = np.arange(Y_COWL, Y_NOSE_N + 1.0, 1.0)
    zones.append((strip(np.stack([ys, s_of_x(ys, xh_t(ys)) * W], 1), 0.11), "gap"))
    # doors: front edge, rear edge, bottom
    yd = np.arange(-16.6, Y_DOOR + 0.01, 1.0)
    w_bot = s_of_z(yd, 10.9) * W
    zones.append((strip(np.stack([yd, w_bot], 1), 0.1), "gap"))
    for yy in (Y_DOOR, -16.6):
        wb = s_of_z([yy], 10.9)[0] * W
        zones.append(([(yy - 0.1, w4 - 0.3), (yy + 0.1, w4 - 0.3), (yy + 0.1, wb), (yy - 0.1, wb)], "gap"))
    # rocker molding between the wheel openings
    yr = np.arange(-40.0, 40.1, 1.0)
    top = s_of_z(yr, 10.2) * W
    bot = s_of_z(yr, 9.15) * W
    zones.append((np.concatenate([np.stack([yr, top], 1), np.stack([yr, bot], 1)[::-1]]), "chrome"))
    # stripes on the hood
    ys = np.arange(Y_COWL, Y_NOSE_N + 0.01, 1.0)
    for x0, x1 in STRIPES:
        lo = s_of_x(ys, x0) * W
        hi = s_of_x(ys, x1) * W
        zones.append((np.concatenate([np.stack([ys, lo], 1), np.stack([ys, hi], 1)[::-1]]), "stripe"))

    boundary = [(Y_TAIL, 0), (Y_NOSE_N, 0), (Y_NOSE_N, W), (Y_TAIL, W)]
    gu = np.concatenate([np.arange(Y_TAIL, NOSE_BLEND, step), np.arange(NOSE_BLEND, Y_NOSE_N + 0.01, step * 0.6)])
    gv = np.unique(np.concatenate([np.arange(0, w2, 3.0), np.linspace(w2, w4, 4),
                                   np.arange(w4, SK[CREASES[-1]] * W, 1.9), [SK[CREASES[1]] * W],
                                   np.linspace(SK[CREASES[-1]] * W, W, 7)]))
    return Patch(lb_map, boundary, "paint", step=step, zones=zones, grid=(gu, gv), edge_step=1.2, flip=True)


def arch_lip_poly(key, width):
    """Band (in the lower-body domain) just outside the wheel opening."""
    W = W_LB
    yw, r = WHEELS[key], ARCH_R[key]
    a = np.linspace(-0.02, math.pi + 0.02, 60)
    inner = np.stack([yw + r * np.cos(a), WHEEL_Z + r * np.sin(a)], 1)
    outer = np.stack([yw + (r + width) * np.cos(a), WHEEL_Z + (r + width) * np.sin(a)], 1)
    wi = s_of_z(inner[:, 0], inner[:, 1]) * W
    wo = s_of_z(outer[:, 0], outer[:, 1]) * W
    pin = np.stack([inner[:, 0], wi], 1)
    pout = np.stack([outer[:, 0], wo], 1)
    # run the band down to the rocker on both sides of the opening
    tail_in = [(yw + r, W + 6)]
    tail_out = [(yw + r + width, W + 6)]
    head_in = [(yw - r, W + 6)]
    head_out = [(yw - r - width, W + 6)]
    poly = np.concatenate([tail_out, pout, head_out, head_in, pin[::-1], tail_in])
    return poly


# --------------------------------------------------------------------------
# Greenhouse
# --------------------------------------------------------------------------

xR_t = Table([(-93.6, 31.2), (-80, 29.9), (-66, 28.7), (-50, 27.4), (-35, 26.3), (-20, 25.3),
              (-6, 24.8), (7.8, 24.4), (28.5, 24.0)])
zR_t = Table([(-93.6, 38.5), (-80, 40.1), (-66, 42.0), (-50, 44.3), (-35, 46.6), (-24, 48.2),
              (-16, 49.1), (-8, 49.35), (0, 48.95), (7.8, 48.4), (28.5, 47.7)])
zct_t = Table([(-93.6, 39.2), (-92.4, 39.65), (-88, 39.7), (-80, 40.85), (-66, 43.0), (-50, 45.6),
               (-35, 47.9), (-22, 49.7), (-14, 50.3), (-6, 50.45), (0, 50.05), (7.8, 49.1), (18.15, 42.75),
               (28.5, 36.4)])
W_SIDE = 16.0


def side_bulge(y):
    return 0.7 * smoothstep(-93.6, -60, y)


def a_pillar_t(y):
    """Fraction up the side ruling where the A-pillar line crosses (1 behind the header)."""
    y = np.asarray(y, float)
    za = lerp(zR_t(Y_HEADER), zs_t(Y_COWL), np.clip((y - Y_HEADER) / (Y_COWL - Y_HEADER), 0, 1))
    t = (za - zs_t(y)) / (zR_t(y) - zs_t(y))
    return np.where(y <= Y_HEADER, 1.0, np.clip(t, 0, 1))


def side_point(y, t):
    y = np.asarray(y, float)
    t = np.asarray(t, float)
    xb, zb = xs_t(y), zs_t(y)
    xr, zr = xR_t(y), zR_t(y)
    x = xb + (xr - xb) * t + side_bulge(y) * np.sin(math.pi * t)
    z = zb + (zr - zb) * t
    return x, z


def side_map(uv):
    uv = np.atleast_2d(uv)
    y, t = uv[:, 0], uv[:, 1] / W_SIDE
    x, z = side_point(y, t)
    return np.stack([x, y, z], 1)


def top_edge(y):
    return side_point(y, a_pillar_t(y))


def top_map(uv):
    uv = np.atleast_2d(uv)
    y, x = uv[:, 0], uv[:, 1]
    ex, ez = top_edge(y)
    zc = zct_t(y)
    t = np.clip(x / ex, 0, 1.2)
    z = zc - (zc - ez) * (0.55 * t ** 2 + 0.45 * t ** 4)
    return np.stack([x, y, z], 1)


def windshield_glass_poly():
    y0, y1 = Y_COWL - 0.7, Y_HEADER + 0.8
    ys = np.linspace(y0, y1, 30)
    ex, _ = top_edge(ys)
    pw = lerp(2.3, 5.6, (ys - y1) / (y0 - y1))
    g = ex - pw
    return np.concatenate([[(y0, -2)], np.stack([ys, g], 1), [(y1, -2)]])


def backlight_glass_poly():
    ys = np.linspace(-22.8, -66.5, 30)
    ex, _ = top_edge(ys)
    pb = lerp(3.1, 6.3, (ys + 22.8) / (-66.5 + 22.8))
    g = ex - pb
    return np.concatenate([[(-22.8, -2)], np.stack([ys, g], 1), [(-66.5, -2)]])


def greenhouse_top(step=2.8):
    ws = windshield_glass_poly()
    bl = backlight_glass_poly()
    zones = [
        (ws, "glass"),
        (offset_poly(ws[::-1], 0.75)[::-1], "chrome"),
        (bl, "glass"),
        (offset_poly(bl[::-1], 0.75)[::-1], "chrome"),
        ([(-68.1, -2), (-68.1, 24.7), (-67.9, 24.7), (-67.9, -2)], "gap"),
        ([(-95, 24.5), (-95, 24.7), (-67.9, 24.7), (-67.9, 24.5)], "gap"),
    ]
    zones += [([(-95, x0), (-95, x1), (Y_COWL + 0.5, x1), (Y_COWL + 0.5, x0)], "stripe") for x0, x1 in STRIPES]
    ys = np.linspace(Y_TAIL, Y_COWL, 140)
    ex, _ = top_edge(ys)
    boundary = np.concatenate([np.stack([ys, 0 * ys], 1), np.stack([ys, ex], 1)[::-1]])
    return Patch(top_map, boundary, "paint", step=step, zones=zones, edge_step=1.3, flip=True)


def dlo_poly():
    """Side glass outline in the side-surface domain (y, w)."""
    ys = np.linspace(Y_COWL - 2.0, Y_HEADER + 0.6, 24)
    wa = a_pillar_t(ys) * W_SIDE - 0.9
    front = np.stack([ys, np.maximum(wa, 0.35)], 1)
    top = [(Y_HEADER + 0.6, W_SIDE - 0.9), (-31.5, W_SIDE - 0.9)]
    rear = [(-27.6, 0.35)]
    return np.concatenate([front, top, rear, [(Y_COWL - 2.0, 0.35)]])


def greenhouse_side(step=2.4):
    g = dlo_poly()
    zones = [
        ([(-16.35, -1), (-16.35, W_SIDE + 1), (-15.95, W_SIDE + 1), (-15.95, -1)], "chrome_div"),
        (g, "glass"),
        (offset_poly(g[::-1], 0.65)[::-1], "chrome"),
    ]
    ys = np.linspace(Y_TAIL, Y_COWL, 140)
    wa = a_pillar_t(ys) * W_SIDE
    boundary = np.concatenate([np.stack([ys, 0 * ys], 1), np.stack([ys, wa], 1)[::-1]])
    p = Patch(side_map, boundary, "paint", step=step, zones=zones, edge_step=1.0)
    return p


# --------------------------------------------------------------------------
# Front face and rear panel
# --------------------------------------------------------------------------

GRILLE = dict(x=23.4, z0=21.6, z1=29.5, r=3.6)
HEADLIGHT_OUT = (29.6, 26.0)
HEADLIGHT_IN = (18.4, 25.5)
HEADLIGHT_HOLE_R = 3.55


def front_outline(n=120):
    s = np.linspace(0, 1, n)
    x, z = lb_profile(np.full(n, Y_NOSE_N), s)
    return np.stack([x, z], 1)


def fascia_map(uv):
    uv = np.atleast_2d(uv)
    x, z = uv[:, 0], uv[:, 1]
    return np.stack([x, nose_y(x, z), z], 1)


def fascia():
    ol = front_outline()
    boundary = np.concatenate([ol, [(0.0, ol[-1, 1])]])
    g = rounded_rect(-GRILLE["x"], GRILLE["z0"], GRILLE["x"], GRILLE["z1"], GRILLE["r"], 8)
    hl = circle(*HEADLIGHT_OUT, HEADLIGHT_HOLE_R, 36)
    zones = [
        (g, None),
        (hl, None),
    ]
    zones += [([(x0, GRILLE["z1"] - 1), (x1, GRILLE["z1"] - 1), (x1, 40), (x0, 40)], "stripe") for x0, x1 in STRIPES]
    return Patch(fascia_map, boundary, "paint", step=1.7, zones=zones, edge_step=0.8, flip=True)


def tail_outline():
    """Outline of the rear panel in (x, z), from the deck centerline around to the bottom."""
    pts = []
    ex, ez = top_edge(np.array([Y_TAIL]))
    xs = np.linspace(0, ex[0], 20)
    tm = top_map(np.stack([np.full(20, Y_TAIL), xs], 1))
    pts += [(p[0], p[2]) for p in tm]
    ts = np.linspace(1, 0, 8)[1:]
    sx, sz = side_point(np.full(len(ts), Y_TAIL), ts)
    pts += list(zip(sx, sz))
    s = np.linspace(S4, 1, 40)[1:]
    x, z = lb_profile(np.full(len(s), Y_TAIL), s)
    pts += list(zip(x, z))
    pts.append((0.0, z[-1]))
    return np.array(pts)


def tail_map(uv):
    uv = np.atleast_2d(uv)
    x, z = uv[:, 0], uv[:, 1]
    return np.stack([x, np.full(len(x), Y_TAIL), z], 1)


def tail_panel():
    return Patch(tail_map, tail_outline(), "paint", step=2.6, edge_step=1.2)
