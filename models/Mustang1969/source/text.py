"""Text as triangle meshes (plate letters, tire lettering, badges), via Blender's built-in font."""

import bpy
import numpy as np

from geom import flat


def text_mesh(s, size=1.0, depth=0.05, resolution=3, italic=False):
    """Extruded text in the XY plane, centered on X, baseline at Y=0, extruded +-depth/2 on Z."""
    cu = bpy.data.curves.new("txt", "FONT")
    cu.body = s
    cu.size = size
    cu.extrude = depth / 2
    cu.resolution_u = resolution
    cu.align_x = "CENTER"
    cu.fill_mode = "BOTH"
    if italic:
        cu.shear = 0.25
    ob = bpy.data.objects.new("txt", cu)
    bpy.context.scene.collection.objects.link(ob)
    dg = bpy.context.evaluated_depsgraph_get()
    ev = ob.evaluated_get(dg)
    me = ev.to_mesh()
    me.calc_loop_triangles()
    V = np.array([v.co[:] for v in me.vertices], float)
    T = np.array([t.vertices[:] for t in me.loop_triangles], int)
    ev.to_mesh_clear()
    bpy.data.objects.remove(ob)
    bpy.data.curves.remove(cu)
    return flat(V, T)


def place_on_plane(mesh, center, facing, width=None, height=None):
    """Stand text upright on a plane facing +Y (facing=1) or -Y (facing=-1), centered."""
    V, T, N = mesh
    lo, hi = V.min(0), V.max(0)
    sc = 1.0
    if width:
        sc = min(sc, width / (hi[0] - lo[0]))
    if height:
        sc = min(sc, height / (hi[1] - lo[1]))
    c = (lo + hi) / 2
    P = (V - c) * sc
    if facing > 0:
        R = np.array([[-1, 0, 0], [0, 0, 1], [0, 1, 0]], float)
    else:
        R = np.array([[1, 0, 0], [0, 0, -1], [0, 1, 0]], float)
    V2 = P @ R.T + np.asarray(center, float)
    N2 = (N.reshape(-1, 3) @ R.T).reshape(N.shape)
    return V2, T, N2


def wrap_on_circle(mesh, radius, angle_center, axis_x, side, height=None):
    """Bend flat text around a circle in the YZ plane (a tire sidewall seen from +X).

    Letters keep their tops pointing away from the center. angle_center is where the text's
    middle sits (radians, 0 = +Y, pi/2 = +Z). side=+1 puts the text on the +X face.
    """
    V, T, N = mesh
    lo, hi = V.min(0), V.max(0)
    P = V - [(lo[0] + hi[0]) / 2, lo[1], 0]
    if height:
        P = P * (height / (hi[1] - lo[1]))
    # arc length -> angle; reading direction runs clockwise when seen from the outside
    ang = angle_center - side * P[:, 0] / radius
    r = radius + P[:, 1]
    x = axis_x + side * P[:, 2]
    out = np.stack([x, r * np.cos(ang), r * np.sin(ang)], 1)
    # rebuild faceted normals and keep the winding outward
    m = flat(out, T)
    a, b, c = out[T[:, 0]], out[T[:, 1]], out[T[:, 2]]
    fn = np.cross(b - a, c - a)
    # extruded front faces should face +side X; flip the whole mesh if most face the other way
    if (fn[:, 0] * side).sum() < 0:
        m = (m[0], m[1][:, [0, 2, 1]], -m[2][:, [0, 2, 1]])
    return m
