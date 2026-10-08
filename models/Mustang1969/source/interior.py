"""A simple black interior: tub, dash, high-back buckets, rear seat, steering wheel.

Roblox draws only the front of each triangle, so the cabin is closed off from the
inside: door panels, floor, package tray and a headliner behind the roof.
"""

import math

import numpy as np

import body
from geom import beam, box, flat, loft_loops, tube, lathe, smooth_mesh, merge_parts, mirror_x

Y_DASH = body.Y_COWL - 11.5
Y_REAR = -66.0
FLOOR_Z = 11.6


def add_all(car):
    tub(car)
    dash(car)
    seats(car)
    steering_wheel(car)


def _fix(mesh, direction):
    V, T, N = mesh
    a, b, c = V[T[:, 0]], V[T[:, 1]], V[T[:, 2]]
    fn = np.cross(b - a, c - a)
    bad = (fn @ np.asarray(direction, float)) < 0
    T = T.copy()
    T[bad] = T[bad][:, [0, 2, 1]]
    return flat(V, T) if len(T) < 64 else smooth_mesh(V, T, 50)


def _side_panel_x(y):
    return body.xs_t(y) - 1.1


TUB_X = 20.8          # inner wall of the rear wheel tubs
TUB_TOP = 29.6


def tub(car):
    yw, r = body.WHEELS["R"], body.ARCH_R["R"]
    y_tub1 = yw + r + 0.5
    ys = np.linspace(y_tub1, body.Y_COWL - 0.5, 30)
    xi = _side_panel_x(ys)
    zb = body.zs_t(ys) - 0.25
    # door trim panels, facing into the cabin
    lo = np.stack([xi, ys, np.full(len(ys), FLOOR_Z)], 1)
    hi = np.stack([xi, ys, zb], 1)
    right = [_fix(loft_loops([lo, hi], closed=False), (-1, 0, 0))]
    # behind the doors the trim steps in over the rear wheel tub
    yq = np.linspace(Y_REAR, y_tub1, 16)
    xq = _side_panel_x(yq)
    zq = body.zs_t(yq) - 0.25
    rows = [np.stack([np.full(len(yq), TUB_X), yq, np.full(len(yq), FLOOR_Z)], 1),
            np.stack([np.full(len(yq), TUB_X), yq, np.full(len(yq), TUB_TOP)], 1)]
    right.append(_fix(loft_loops(rows, closed=False), (-1, 0, 0)))
    shelf = [np.stack([np.full(len(yq), TUB_X), yq, np.full(len(yq), TUB_TOP)], 1),
             np.stack([xq, yq, np.full(len(yq), TUB_TOP)], 1)]
    right.append(_fix(loft_loops(shelf, closed=False), (0, 0, 1)))
    upper = [np.stack([xq, yq, np.full(len(yq), TUB_TOP)], 1), np.stack([xq, yq, zq], 1)]
    right.append(_fix(loft_loops(upper, closed=False), (-1, 0, 0)))
    # front face of the tub, closing the step
    x1 = float(_side_panel_x(y_tub1))
    V = np.array([(TUB_X, y_tub1, FLOOR_Z), (x1, y_tub1, FLOOR_Z), (x1, y_tub1, TUB_TOP), (TUB_X, y_tub1, TUB_TOP)])
    right.append(_fix(flat(V, np.array([(0, 1, 2), (0, 2, 3)])), (0, 1, 0)))
    for m in right:
        car.add("Interior", "Interior", m)
        car.add("Interior", "Interior", mirror_x(m))
    # floor
    fl = np.stack([-xi, ys, np.full(len(ys), FLOOR_Z)], 1)
    fr = np.stack([xi, ys, np.full(len(ys), FLOOR_Z)], 1)
    car.add("Interior", "Interior", _fix(loft_loops([fl, fr], closed=False), (0, 0, 1)))
    # package tray under the rear glass, and the bulkhead below it
    yt = np.linspace(Y_REAR, -50.0, 8)
    zt = body.zs_t(yt) - 0.3
    xt = _side_panel_x(yt)
    tl = np.stack([-xt, yt, zt], 1)
    tr = np.stack([xt, yt, zt], 1)
    car.add("Interior", "Interior", _fix(loft_loops([tl, tr], closed=False), (0, 0, 1)))
    zr = float(body.zs_t(Y_REAR) - 0.3)
    xr = float(_side_panel_x(Y_REAR))
    V = np.array([(-xr, Y_REAR, FLOOR_Z), (xr, Y_REAR, FLOOR_Z), (xr, Y_REAR, zr), (-xr, Y_REAR, zr)])
    car.add("Interior", "Interior", _fix(flat(V, np.array([(0, 1, 2), (0, 2, 3)])), (0, 1, 0)))


def dash(car):
    x = float(_side_panel_x(Y_DASH)) - 0.1
    top = float(body.zc_t(body.Y_COWL - 1.0)) - 0.6
    # dash: top shelf from the windshield back to the face, face down to the footwell
    prof_y = [body.Y_COWL, body.Y_COWL - 5.0, Y_DASH, Y_DASH, Y_DASH + 3.5, body.Y_COWL - 2.0]
    prof_z = [top, top + 0.1, top - 0.6, 24.0, 19.0, FLOOR_Z]
    loops = []
    for xx in np.linspace(-x, x, 3):
        loops.append(np.stack([np.full(6, xx), prof_y, prof_z], 1))
    m = loft_loops([loops[0], loops[-1]], closed=False, angle=40)
    car.add("Interior", "Interior", _fix(m, (0, -1, 0.5)))
    # instrument hood over the gauges in front of the driver
    V, T = box((-15.5, Y_DASH - 0.6, top - 2.2), (16.0, 1.4, 2.8))
    car.add("Trim_Black", "Black", flat(V, T))
    for gx in (-20.5, -15.5, -10.5):
        car.add("Trim_Chrome", "Chrome", tube(np.array([[gx + 1.6 * math.cos(a), Y_DASH - 1.35, top - 2.3 + 1.6 * math.sin(a)]
                                                       for a in np.linspace(0, 2 * math.pi, 17)]), 0.12, 5, cap=False))
    # console
    V, T = box((0.0, 2.0, FLOOR_Z + 3.0), (7.0, 32.0, 6.0))
    car.add("Interior", "Interior", flat(V, T))


def _seat(cx, y_front, y_back, z_seat, back_top, width, high_back=True):
    parts = []
    V, T = box((cx, (y_front + y_back) / 2, z_seat - 2.0), (width, y_front - y_back, 4.0))
    parts.append(flat(V, T))
    V, T = box((cx, (y_front + y_back) / 2, (z_seat - 4.0 + FLOOR_Z) / 2), (width - 4, y_front - y_back - 4, z_seat - 4.0 - FLOOR_Z))
    parts.append(flat(V, T))
    p0 = np.array([cx, y_back + 1.5, z_seat - 1.0])
    p1 = np.array([cx, y_back - 6.0, back_top])
    parts.append(beam(p0, p1, (1, 0, 0), width - 1.0, 4.0))
    if high_back:
        h0 = p1 + np.array([0, 0.6, -2.0])
        h1 = p1 + np.array([0, -0.9, 4.5])
        parts.append(beam(h0, h1, (1, 0, 0), width * 0.6, 3.6))
    return merge_parts(parts)


def seats(car):
    for cx in (-13.0, 13.0):
        car.add("Interior", "Interior", _seat(cx, 3.0, -15.0, 18.5, 37.5, 19.0))
    # small fastback rear seat
    car.add("Interior", "Interior", _seat(0.0, -30.0, -46.0, 17.0, 33.0, 40.0, high_back=False))


def steering_wheel(car):
    c = np.array([-15.5, Y_DASH - 7.0, 30.0])
    tilt = math.radians(28)
    n = np.array([0.0, -math.cos(tilt), math.sin(tilt)])
    u = np.array([1.0, 0.0, 0.0])
    v = np.cross(n, u)
    ring = np.array([c + 7.4 * (math.cos(a) * u + math.sin(a) * v) for a in np.linspace(0, 2 * math.pi, 33)])
    car.add("Trim_Black", "Black", tube(ring, 0.5, 8, cap=False))
    for a in (math.radians(0), math.radians(180), math.radians(270)):
        tip = c + 7.2 * (math.cos(a) * u + math.sin(a) * v)
        car.add("Trim_Chrome", "Chrome", beam(c, tip, n, 1.1, 0.25))
    hub = lathe([(1.6, 0.0), (1.5, 0.6), (0.0, 0.8)], c, n, 16)
    car.add("Trim_Black", "Black", hub)
    col_end = np.array([-15.5, Y_DASH + 1.0, 26.5])
    car.add("Trim_Black", "Black", tube(np.array([c - n * 0.2, col_end]), 1.0, 10))


def inner_shell(mesh, d):
    """Copy of a surface pushed d inward and turned to face the other way."""
    V, T, N = mesh
    acc = np.zeros_like(V)
    for k in range(3):
        np.add.at(acc, T[:, k], N[:, k])
    acc /= np.maximum(np.linalg.norm(acc, axis=1, keepdims=True), 1e-12)
    V2 = V - acc * d
    return V2, T[:, [0, 2, 1]], -N[:, [0, 2, 1]]
