"""Preview renders (Cycles, CPU) used to check the model against the photo."""

import math
import os

import bpy
from mathutils import Vector

# Camera fitted to the reference photo: position, target, roll (deg), lens (mm, 36 mm sensor).
# The photo shows the front and the passenger (right, +X) side.
PHOTO_CAM = dict(loc=(68.2, 144.6, 42.66), target=(1.28, 45.73, 30.64), lens=37.62, roll=3.46)

VIEWS = {
    "photo": PHOTO_CAM,
    "side": dict(loc=(-900, 0, 26), target=(0, 0, 26), ortho=205),
    "front": dict(loc=(0, 900, 26), target=(0, 0, 26), ortho=80),
    "rear": dict(loc=(0, -900, 26), target=(0, 0, 26), ortho=80),
    "top": dict(loc=(0, 0, 900), target=(0, 0, 0), ortho=205, up=(0, 1, 0)),
    "rear34": dict(loc=(130, -210, 80), target=(0, -15, 24), lens=40),
    "front34": dict(loc=(150, 190, 60), target=(0, 20, 22), lens=40),
    "hood": dict(loc=(-60, 150, 75), target=(0, 40, 34), lens=35),
    "wheel": dict(loc=(-110, 95, 20), target=(-33, 54, 13), lens=50),
    "nose": dict(loc=(-40, 160, 30), target=(0, 88, 24), lens=40),
    "headlight": dict(loc=(75, 130, 33), target=(26, 86, 25), lens=50),
    "scoop": dict(loc=(0, 52, 140), target=(0, 52, 35), ortho=30, up=(0, 1, 0)),
    "rwheel": dict(loc=(-110, -15, 20), target=(-33, -54, 13), lens=50),
    "rear_low": dict(loc=(-70, -180, 30), target=(0, -80, 24), lens=35),
    "cabin": dict(loc=(80, 10, 52), target=(0, -5, 30), lens=35),
    "left34": dict(loc=(-150, 170, 55), target=(0, 10, 22), lens=40),
}


def setup_world():
    sc = bpy.context.scene
    world = bpy.data.worlds.new("World")
    sc.world = world
    world.use_nodes = True
    nt = world.node_tree
    bg = nt.nodes["Background"]
    sky = nt.nodes.new("ShaderNodeTexGradient")
    # simple overcast sky: brighter overhead, darker toward the horizon
    coord = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.0
    ramp.color_ramp.elements[0].color = (0.30, 0.32, 0.30, 1)
    ramp.color_ramp.elements[1].position = 0.6
    ramp.color_ramp.elements[1].color = (0.95, 0.97, 1.0, 1)
    nt.links.new(coord.outputs["Generated"], sep.inputs[0])
    nt.links.new(sep.outputs["Z"], ramp.inputs[0])
    nt.links.new(ramp.outputs["Color"], bg.inputs["Color"])
    nt.nodes.remove(sky)
    bg.inputs["Strength"].default_value = 1.1

    sun = bpy.data.lights.new("Sun", "SUN")
    sun.energy = 1.6
    sun.angle = math.radians(25)
    ob = bpy.data.objects.new("Sun", sun)
    ob.rotation_euler = (math.radians(40), 0, math.radians(-150))
    sc.collection.objects.link(ob)

    me = bpy.data.meshes.new("Ground")
    s = 4000
    me.from_pydata([(-s, -s, 0), (s, -s, 0), (s, s, 0), (-s, s, 0)], [], [(0, 1, 2, 3)])
    g = bpy.data.objects.new("Ground", me)
    m = bpy.data.materials.new("GroundMat")
    m.use_nodes = True
    m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.045, 0.085, 0.025, 1)
    m.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.95
    me.materials.append(m)
    sc.collection.objects.link(g)


def camera(view):
    sc = bpy.context.scene
    cam = sc.camera
    if cam is None:
        cam = bpy.data.objects.new("Camera", bpy.data.cameras.new("Camera"))
        sc.collection.objects.link(cam)
        sc.camera = cam
    loc = Vector(view["loc"])
    tgt = Vector(view["target"])
    cam.location = loc
    d = tgt - loc
    up = Vector(view.get("up", (0, 0, 1)))
    rot = d.to_track_quat("-Z", "Y")
    if "up" in view:
        z = -d.normalized()
        x = up.cross(z).normalized()
        y = z.cross(x)
        from mathutils import Matrix
        rot = Matrix((x, y, z)).transposed().to_quaternion()
    cam.rotation_euler = rot.to_euler()
    if "roll" in view:
        cam.rotation_euler.rotate_axis("Z", math.radians(view["roll"]))
    c = cam.data
    c.clip_start = 1
    c.clip_end = 20000
    c.sensor_width = 36
    if "ortho" in view:
        c.type = "ORTHO"
        c.ortho_scale = view["ortho"]
    else:
        c.type = "PERSP"
        c.lens = view.get("lens", 35)
    c.shift_x, c.shift_y = view.get("shift", (0.0, 0.0))
    return cam


def render_views(out_dir, views, samples=48, res=1024):
    os.makedirs(out_dir, exist_ok=True)
    sc = bpy.context.scene
    setup_world()
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = samples
    sc.cycles.use_denoising = False
    sc.cycles.max_bounces = 6
    sc.cycles.transparent_max_bounces = 8
    sc.render.resolution_x = res
    sc.render.resolution_y = res * 3 // 4
    sc.render.film_transparent = False
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    for v in views:
        camera(VIEWS[v])
        sc.render.filepath = os.path.join(os.path.abspath(out_dir), f"{v}.png")
        bpy.ops.render.render(write_still=True)
