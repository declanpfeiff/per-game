"""Build the 1969 Mustang SportsRoof and export it for Roblox.

Run with Blender's Python module (pip install bpy==5.2.2 numpy):

    python build.py                 # export ../Mustang1969.fbx and ../Mustang1969.glb
    python build.py --render DIR    # also render preview images into DIR

Every part is a separate mesh with a single material, named so the Roblox
paint script (../PaintMustang.lua) can find it after import.
"""

import argparse
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import bpy  # noqa: E402
import addon_utils  # noqa: E402

import body  # noqa: E402
import interior  # noqa: E402
import parts  # noqa: E402
from geom import merge_parts  # noqa: E402

INCHES_PER_STUD = 0.28 / 0.0254   # Roblox's 1 stud = 0.28 m

# name: (base color sRGB 0-255, metallic, roughness, extra)
MATERIALS = {
    "Paint":      ((33, 76, 156), 0.5, 0.3, {"coat": 1.0}),
    "Stripe":     ((236, 236, 230), 0.0, 0.3, {"coat": 1.0}),
    "Chrome":     ((235, 235, 240), 1.0, 0.07, {}),
    "Glass":      ((20, 28, 30), 0.0, 0.03, {"alpha": 0.35}),
    "Black":      ((12, 12, 13), 0.0, 0.45, {}),
    "Gap":        ((6, 8, 14), 0.0, 0.6, {}),
    "Rubber":     ((18, 18, 18), 0.0, 0.85, {}),
    "Letters":    ((225, 225, 220), 0.0, 0.6, {}),
    "Aluminum":   ((170, 172, 176), 1.0, 0.32, {}),
    "Underbody":  ((14, 14, 15), 0.0, 0.9, {}),
    "Interior":   ((16, 16, 17), 0.0, 0.55, {}),
    "Lens":       ((228, 230, 232), 0.25, 0.1, {}),
    "TailLens":   ((150, 8, 8), 0.0, 0.2, {}),
    "Amber":      ((230, 110, 10), 0.0, 0.25, {}),
    "PlateWhite": ((235, 235, 232), 0.0, 0.4, {}),
    "PlateRed":   ((190, 20, 25), 0.0, 0.4, {}),
}

ZONE_PARTS = {
    "paint": ("Body", "Paint"),
    "stripe": ("Stripes", "Stripe"),
    "chrome": ("Trim_Chrome", "Chrome"),
    "chrome_div": ("Trim_Chrome", "Chrome"),
    "glass": ("Glass", "Glass"),
    "black": ("Trim_Black", "Black"),
    "gap": ("PanelGaps", "Gap"),
}


class Car:
    def __init__(self):
        self.parts = {}

    def add(self, name, material, mesh):
        entry = self.parts.setdefault(name, [material, []])
        assert entry[0] == material, (name, material, entry[0])
        entry[1].append(mesh)

    def add_patch(self, patch, lining=None):
        """Add a body patch. lining (inches) also adds a headliner-style inner copy of its
        opaque zones, and a back face for its glass."""
        for key, mesh in patch.build().items():
            name, mat = ZONE_PARTS[key]
            self.add(name, mat, mesh)
            if lining:
                if key == "glass":
                    self.add(name, mat, interior.inner_shell(mesh, 0.12))
                else:
                    self.add("Interior", "Interior", interior.inner_shell(mesh, lining))


def linear(c):
    c = np.asarray(c, float) / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


CULL_BACKFACES = False   # previews: hide back faces the way Roblox does


def make_material(name):
    rgb, metallic, rough, extra = MATERIALS[name]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    if CULL_BACKFACES:
        nt = m.node_tree
        out = nt.nodes["Material Output"]
        geo = nt.nodes.new("ShaderNodeNewGeometry")
        mix = nt.nodes.new("ShaderNodeMixShader")
        clear = nt.nodes.new("ShaderNodeBsdfTransparent")
        nt.links.new(geo.outputs["Backfacing"], mix.inputs[0])
        nt.links.new(bsdf.outputs[0], mix.inputs[1])
        nt.links.new(clear.outputs[0], mix.inputs[2])
        nt.links.new(mix.outputs[0], out.inputs["Surface"])
    col = linear(rgb)
    bsdf.inputs["Base Color"].default_value = (col[0], col[1], col[2], 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = rough
    if "coat" in extra:
        bsdf.inputs["Coat Weight"].default_value = extra["coat"]
        bsdf.inputs["Coat Roughness"].default_value = 0.03
    if "alpha" in extra:
        bsdf.inputs["Alpha"].default_value = extra["alpha"]
        bsdf.inputs["Specular IOR Level"].default_value = 1.0
    return m


def weld(V, T, N):
    key = np.round(V, 4)
    _, first, inv = np.unique(key, axis=0, return_index=True, return_inverse=True)
    return V[first], inv.ravel()[T], N


def make_object(name, material, meshes, scale):
    V, T, N = merge_parts(meshes)
    V, T, N = weld(V, T, N)
    me = bpy.data.meshes.new(name)
    me.from_pydata((V * scale).tolist(), [], T.tolist())
    me.validate(clean_customdata=False)
    me.shade_smooth()
    if len(me.polygons) == len(T):
        me.normals_split_custom_set(N.reshape(-1, 3).tolist())
    me.materials.append(bpy.data.materials.get(material) or make_material(material))
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def build_car(steer=0.0):
    car = Car()
    car.add_patch(body.lower_body())
    car.add_patch(body.greenhouse_top(), lining=0.6)
    car.add_patch(body.greenhouse_side(), lining=0.6)
    car.add_patch(body.fascia())
    car.add_patch(body.tail_panel())
    parts.add_all(car, steer)
    return car


def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    addon_utils.enable("cycles", default_set=True)


def create_objects(car, scale=1.0):
    objs = []
    for name, (mat, meshes) in car.parts.items():
        objs.append(make_object(name, mat, meshes, scale))
    return objs


def tri_report(objs):
    total = 0
    rows = []
    for ob in objs:
        n = sum(len(p.vertices) - 2 for p in ob.data.polygons)
        total += n
        rows.append((n, ob.name))
    for n, name in sorted(rows, reverse=True):
        print(f"  {name:28s} {n:6d}")
    print(f"  {'TOTAL':28s} {total:6d}")
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--render", metavar="DIR")
    ap.add_argument("--views", default="photo,side,front,rear34,top")
    ap.add_argument("--samples", type=int, default=48)
    ap.add_argument("--res", type=int, default=1024)
    ap.add_argument("--no-export", action="store_true")
    ap.add_argument("--steer", type=float, default=0.0, help="front wheel angle for previews (deg, + = left)")
    ap.add_argument("--cull", action="store_true", help="previews: hide back faces like Roblox does")
    args = ap.parse_args()

    global CULL_BACKFACES
    CULL_BACKFACES = args.cull
    reset_scene()
    car = build_car(args.steer if args.render else 0.0)
    if args.render:
        import preview
        objs = create_objects(car)
        tri_report(objs)
        preview.render_views(args.render, args.views.split(","), args.samples, args.res)
    if not args.no_export:
        import export
        if args.render and args.steer:
            car = build_car(0.0)
        reset_scene()
        objs = create_objects(car, 1.0 / INCHES_PER_STUD)
        objs = export.export_all(objs, os.path.dirname(HERE))
        tri_report(objs)


if __name__ == "__main__":
    main()
