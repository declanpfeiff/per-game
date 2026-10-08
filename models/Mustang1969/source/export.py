"""FBX and glTF export, with parts split to stay under Roblox's per-mesh triangle limit."""

import json
import os

import bpy
import numpy as np

MAX_TRIS = 9000      # Roblox accepts up to ~20k per MeshPart; stay well clear


def split_large(objs):
    """Split any object over MAX_TRIS into front-to-back chunks named Name_1, Name_2, ..."""
    out = []
    for ob in objs:
        me = ob.data
        n = len(me.polygons)
        if n <= MAX_TRIS:
            out.append(ob)
            continue
        k = -(-n // MAX_TRIS)
        cy = np.array([p.center.y for p in me.polygons])
        edges = np.quantile(cy, np.linspace(0, 1, k + 1)[1:-1])
        bins = np.searchsorted(edges, cy)
        name = ob.name
        for i in range(k):
            dup = ob.copy()
            dup.data = me.copy()
            bpy.context.scene.collection.objects.link(dup)
            dme = dup.data
            import bmesh
            bm = bmesh.new()
            bm.from_mesh(dme)
            bm.faces.ensure_lookup_table()
            kill = [f for f in bm.faces if bins[f.index] != i]
            bmesh.ops.delete(bm, geom=kill, context="FACES")
            bm.to_mesh(dme)
            bm.free()
            dup.name = f"{name}_{i + 1}"
            dme.name = dup.name
            out.append(dup)
        bpy.data.objects.remove(ob)
    return out


def export_all(objs, out_dir):
    objs = split_large(objs)
    for ob in bpy.context.scene.objects:
        ob.select_set(False)
    for ob in objs:
        ob.select_set(True)
    fbx = os.path.join(out_dir, "Mustang1969.fbx")
    bpy.ops.export_scene.fbx(filepath=fbx, use_selection=True, object_types={"MESH"},
                             mesh_smooth_type="OFF", use_mesh_modifiers=False,
                             axis_forward="-Z", axis_up="Y", apply_unit_scale=True,
                             bake_space_transform=True, add_leaf_bones=False, path_mode="STRIP")
    glb = os.path.join(out_dir, "Mustang1969.glb")
    bpy.ops.export_scene.gltf(filepath=glb, export_format="GLB", use_selection=True,
                              export_normals=True, export_apply=False, export_yup=True,
                              export_materials="EXPORT")
    write_manifest(objs, os.path.join(out_dir, "Mustang1969.parts.json"))
    print("wrote", fbx, glb)
    return objs


def write_manifest(objs, path):
    """Part list with each mesh's bounding box in Roblox space (studs, Y up, front toward -Z)."""
    rows = []
    for ob in sorted(objs, key=lambda o: o.name):
        V = np.array([v.co[:] for v in ob.data.vertices])
        lo, hi = V.min(0), V.max(0)
        c, sz = (lo + hi) / 2, hi - lo
        rows.append({
            "name": ob.name,
            "material": ob.data.materials[0].name,
            "triangles": sum(len(p.vertices) - 2 for p in ob.data.polygons),
            "center": [round(c[0], 4), round(c[2], 4), round(-c[1], 4)],
            "size": [round(sz[0], 4), round(sz[2], 4), round(sz[1], 4)],
        })
    with open(path, "w") as f:
        f.write("[\n" + ",\n".join("  " + json.dumps(r) for r in rows) + "\n]\n")
