#!/usr/bin/env python3
"""
build_scene.py — Stage B of the v2 screenshot pipeline (blender-product-render
methodology: deterministic procedural scene, headless, evidence-scaled).

Builds a procedural iPhone-16-Pro-class device (the phone is a supporting
actor; fidelity budget goes to the titanium rail highlight and the screen
glass) with the Stage-A simulator capture as an emissive screen texture, poses
it in a per-shot "frozen" tilt, and renders a film-transparent RGBA layer at
2x the final 1260x2736 size. compose.py puts the brand gradient + caption
typography underneath/over it.

Evidence base:
  - Dimensions: iPhone 16 Pro Max body 163.0 x 77.6 x 8.25 mm (Apple spec),
    display active area ~69.8 x 151.65 mm (matches the 1320x2868 capture
    aspect 0.4603), flat rail with tight edge blend (~2.2 mm).
  - Material language: continuity with the brand's AEK II keycap renders
    (Lyklabord-Keycap-Wave6.blend): satin platinum PBT world — one large
    softbox + small frontal fill, restrained roughness ~0.4.

Usage:
  blender --background --python build_scene.py -- \
      --shot 2 --capture captures/02-raw.png --out blender/render-02.png \
      [--preview] [--save-blend blender/phone.blend]
"""

import argparse
import math
import os
import sys

import bpy
import bmesh
from mathutils import Vector

# ----------------------------------------------------------------- params ----
MM = 0.001
BODY_W = 77.6 * MM
BODY_H = 163.0 * MM
BODY_T = 8.25 * MM
BODY_R = 14.0 * MM          # plan-view corner radius
EDGE_BLEND = 2.2 * MM       # rail-to-face blend radius
SCREEN_W = 69.8 * MM
SCREEN_H = 151.65 * MM
SCREEN_R = 11.5 * MM        # display corner radius

FINAL_W, FINAL_H = 1260, 2736
SUPER = 2                   # 2x supersample; compose.py downscales

# Per-shot frozen pose: (rot_x tilt-away deg, rot_y side-lean deg,
#                        rot_z in-frame lean deg, frame_shift_x m,
#                        frame_bottom_frac, width_frac phone-width/frame-width,
#                        fade_start, fade_end)
# width_frac > 1 makes the phone's top edges crop out of the frame — the
# keyboard (bottom half of the screen) fills the stage. The strong rot_x
# foreshortens the upper body ("frozen mid-motion") and, combined with the
# screen fade (uv.y fade_start..fade_end fades the emissive UI into the dark
# stage), no empty screen or status bar ever shows.
# NOTE width_frac stays <= ~1.0: the LITERAL layout (…p ð / …l æ ö / …m þ,
# Venda) must be fully on frame — that is the point of the product. The
# empty upper screen is handled by the in-material screen fade, and the
# device sits on a physical neutral backdrop (keycap-brand tabletop
# language, dark studio key) rather than a void gradient.
POSES = {
    # fade START stays just above the suggestion bar + text field (the story
    # — must not dissolve); the END is extended for a long, smooth tail so
    # the screen melts into the graded backdrop instead of hard-cutting to a
    # black rectangle. The gradient backdrop gives the upper region life.
    1: (-18.0,  5.0, -4.0,  0.000, 0.080, 0.95, 0.445, 0.520),
    2: (-20.0, -6.0,  5.0,  0.000, 0.075, 0.96, 0.445, 0.520),
    3: (-20.0,  6.0, -5.0,  0.000, 0.075, 0.96, 0.445, 0.520),
    4: (-20.0, -6.0,  5.0,  0.000, 0.075, 0.96, 0.445, 0.520),
    # App screen (Orðasafn): sits LOWER + smaller so its white top clears
    # the caption band (fixes the shot-5 caption/screen collision); a gentle
    # top fade dissolves the empty area above the list into the backdrop.
    5: (-15.0,  4.0, -4.0,  0.000, 0.045, 0.80, 0.86, 0.97),
    6: (-24.0,  8.0,  7.0,  0.000, 0.070, 0.98, 0.445, 0.520),
}


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--shot", type=int, required=True)
    p.add_argument("--capture", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--preview", action="store_true",
                   help="fast half-res, low-sample render")
    p.add_argument("--save-blend", default=None)
    return p.parse_args(argv)


# ------------------------------------------------------------- geometry ------
def rounded_rect_points(w, h, r, seg=16):
    """CCW outline of a w x h rectangle with corner radius r, centered."""
    cx, cy = w / 2 - r, h / 2 - r
    pts = []
    corners = [  # (center, start angle)
        ((cx, cy), 0.0), ((-cx, cy), 0.5 * math.pi),
        ((-cx, -cy), math.pi), ((cx, -cy), 1.5 * math.pi),
    ]
    for (ccx, ccy), a0 in corners:
        for i in range(seg + 1):
            a = a0 + (0.5 * math.pi) * i / seg
            pts.append((ccx + r * math.cos(a), ccy + r * math.sin(a)))
    return pts


def make_body():
    """Manufacturing order: slab -> plan-view corner radius -> rail edge
    blend (weighted bevel). Side faces = titanium rail, caps = glass."""
    mesh = bpy.data.meshes.new("PhoneBodyMesh")
    bm = bmesh.new()
    outline = rounded_rect_points(BODY_W, BODY_H, BODY_R)
    bot = [bm.verts.new((x, y, 0.0)) for x, y in outline]
    top = [bm.verts.new((x, y, BODY_T)) for x, y in outline]
    n = len(outline)
    side_faces = []
    for i in range(n):
        f = bm.faces.new((bot[i], bot[(i + 1) % n],
                          top[(i + 1) % n], top[i]))
        side_faces.append(f)
    f_top = bm.faces.new(reversed(top))
    f_bot = bm.faces.new(bot)
    bm.normal_update()
    if f_top.normal.z < 0:
        f_top.normal_flip()
    if f_bot.normal.z > 0:
        f_bot.normal_flip()
    # Bevel weight on the two horizontal rings only (vertical edges already
    # rounded by the profile — beveling them would double-round the corners).
    bw = bm.edges.layers.float.new("bevel_weight_edge")
    for e in bm.edges:
        zs = {round(v.co.z, 6) for v in e.verts}
        if len(zs) == 1:  # horizontal ring edge
            e[bw] = 1.0
    # material slots: 0 rail, 1 glass front, 2 back
    for f in side_faces:
        f.material_index = 0
    f_top.material_index = 1
    f_bot.material_index = 2
    bm.to_mesh(mesh)
    bm.free()

    obj = bpy.data.objects.new("PhoneBody", mesh)
    bpy.context.collection.objects.link(obj)
    bev = obj.modifiers.new("EdgeBlend", "BEVEL")
    bev.limit_method = "WEIGHT"
    bev.width = EDGE_BLEND
    bev.segments = 8
    bev.profile = 0.72          # slightly squared blend, 15/16-Pro-like
    obj.data.shade_smooth()
    for prop, val in (("source", "Apple spec 163.0x77.6x8.25mm"),
                      ("scale", "1 BU = 1 m"),
                      ("edge_blend_mm", 2.2)):
        obj[prop] = val
    return obj


def make_screen(capture_path, fade_start=0.62, fade_end=0.76):
    mesh = bpy.data.meshes.new("ScreenMesh")
    bm = bmesh.new()
    pts = rounded_rect_points(SCREEN_W, SCREEN_H, SCREEN_R)
    verts = [bm.verts.new((x, y, BODY_T + 0.00015)) for x, y in pts]
    face = bm.faces.new(verts)
    face.normal_update()
    if face.normal.z < 0:
        face.normal_flip()
    uv = bm.loops.layers.uv.new("UVMap")
    for loop in face.loops:
        x, y, _ = loop.vert.co
        loop[uv].uv = (x / SCREEN_W + 0.5, y / SCREEN_H + 0.5)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new("Screen", mesh)
    bpy.context.collection.objects.link(obj)

    mat = bpy.data.materials.new("Screen emissive UI + glass sheen")
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    mix = nt.nodes.new("ShaderNodeMixShader")
    emit = nt.nodes.new("ShaderNodeEmission")
    gloss = nt.nodes.new("ShaderNodeBsdfGlossy")
    lw = nt.nodes.new("ShaderNodeLayerWeight")
    tex = nt.nodes.new("ShaderNodeTexImage")
    img = bpy.data.images.load(os.path.abspath(capture_path))
    img.colorspace_settings.name = "sRGB"
    tex.image = img
    tex.extension = "CLIP"
    gloss.inputs["Roughness"].default_value = 0.12
    lw.inputs["Blend"].default_value = 0.04   # whisper of sheen; UI must read
    emit.inputs["Strength"].default_value = 1.0
    # Texture lookup in OBJECT space (per-pixel exact) — the rounded-rect
    # n-gon's vertex-interpolated UVs distort badly across the interior.
    coord = nt.nodes.new("ShaderNodeTexCoord")
    mapping = nt.nodes.new("ShaderNodeMapping")
    mapping.inputs["Location"].default_value = (0.5, 0.5, 0.0)
    mapping.inputs["Scale"].default_value = (1.0 / SCREEN_W, 1.0 / SCREEN_H, 1.0)
    nt.links.new(coord.outputs["Object"], mapping.inputs["Vector"])
    nt.links.new(mapping.outputs["Vector"], tex.inputs["Vector"])
    # Fade the UI into the dark stage above the text field (screen-y ramp):
    # the empty upper screen / status bar must never show ("bottom half only").
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    ramp = nt.nodes.new("ShaderNodeMapRange")
    ramp.inputs["From Min"].default_value = fade_start
    ramp.inputs["From Max"].default_value = fade_end
    ramp.clamp = True
    mixc = nt.nodes.new("ShaderNodeMix")
    mixc.data_type = "RGBA"
    mixc.inputs["B"].default_value = (0.0128, 0.0121, 0.0116, 1.0)  # ink dark
    nt.links.new(mapping.outputs["Vector"], sep.inputs["Vector"])
    nt.links.new(sep.outputs["Y"], ramp.inputs["Value"])
    nt.links.new(ramp.outputs["Result"], mixc.inputs["Factor"])
    nt.links.new(tex.outputs["Color"], mixc.inputs["A"])
    nt.links.new(mixc.outputs["Result"], emit.inputs["Color"])
    nt.links.new(emit.outputs["Emission"], mix.inputs[1])
    nt.links.new(gloss.outputs["BSDF"], mix.inputs[2])
    nt.links.new(lw.outputs["Fresnel"], mix.inputs["Fac"])
    nt.links.new(mix.outputs["Shader"], out.inputs["Surface"])
    obj.data.materials.append(mat)
    return obj


def make_materials(body):
    rail = bpy.data.materials.new("Natural titanium rail - brushed satin")
    rail.use_nodes = True
    bsdf = rail.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (0.62, 0.585, 0.545, 1.0)
    bsdf.inputs["Metallic"].default_value = 1.0
    bsdf.inputs["Roughness"].default_value = 0.32
    bsdf.inputs["Anisotropic"].default_value = 0.55

    glass = bpy.data.materials.new("Front glass bezel - near black gloss")
    glass.use_nodes = True
    b2 = glass.node_tree.nodes["Principled BSDF"]
    b2.inputs["Base Color"].default_value = (0.008, 0.008, 0.009, 1.0)
    b2.inputs["Metallic"].default_value = 0.0
    b2.inputs["Roughness"].default_value = 0.08
    b2.inputs["IOR"].default_value = 1.5

    back = bpy.data.materials.new("Back glass - satin dark")
    back.use_nodes = True
    b3 = back.node_tree.nodes["Principled BSDF"]
    b3.inputs["Base Color"].default_value = (0.05, 0.048, 0.045, 1.0)
    b3.inputs["Roughness"].default_value = 0.4

    body.data.materials.append(rail)
    body.data.materials.append(glass)
    body.data.materials.append(back)


def make_backdrop():
    """Physical neutral stage (keycap-brand tabletop language, dark key):
    a large matte surface ~2.2 cm below the floating device. The softbox
    pools light around the device and falls off toward the frame top, so
    captions land on near-black while the phone sits in a lit scene and
    casts a REAL soft contact shadow."""
    mesh = bpy.data.meshes.new("BackdropMesh")
    bm = bmesh.new()
    s = 1.2
    verts = [bm.verts.new(v) for v in
             [(-s, -s, 0), (s, -s, 0), (s, s, 0), (-s, s, 0)]]
    bm.faces.new(verts)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new("Neutral studio surface", mesh)
    obj.location = (0.0, 0.0, -0.022)
    bpy.context.collection.objects.link(obj)
    mat = bpy.data.materials.new("Studio surface - graded dark")
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.82
    # Graded backdrop: a large soft radial pool that lifts and cools toward
    # the device and sinks to near-black at the frame edges (where captions
    # sit) — "neutral but with a little life", not flat 3D grey. Two tones:
    # a deep cool slate in the pool, a warm charcoal at the falloff, so the
    # stage reads as a designed studio sweep rather than a default surface.
    tex_coord = nt.nodes.new("ShaderNodeTexCoord")
    grad = nt.nodes.new("ShaderNodeTexGradient")
    grad.gradient_type = "QUADRATIC_SPHERE"          # radial pool
    mapping = nt.nodes.new("ShaderNodeMapping")
    mapping.inputs["Location"].default_value = (0.5, 0.62, 0.0)  # pool sits under/behind device
    mapping.inputs["Scale"].default_value = (0.85, 0.85, 1.0)
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    cr = ramp.color_ramp
    # BRAND-ALIGNED warm platinum studio (the AEK II keycap world: warm PBT
    # plastic in shadow, NOT cool grey). Tones drawn from the site's own dark
    # tokens (#1c1b1a / #242220 — warm near-black) lifted toward the platinum
    # keycap in the lit pool. Stays dark enough for cream captions to read.
    cr.elements[0].position = 0.0
    cr.elements[0].color = (0.033, 0.027, 0.020, 1.0)   # warm platinum-lifted pool
    cr.elements[1].position = 1.0
    cr.elements[1].color = (0.0042, 0.0037, 0.0031, 1.0)  # warm near-black — edges/top
    mid = cr.elements.new(0.34)
    mid.color = (0.014, 0.0122, 0.0100, 1.0)            # warm charcoal (#242220 family)
    nt.links.new(tex_coord.outputs["Generated"], mapping.inputs["Vector"])
    nt.links.new(mapping.outputs["Vector"], grad.inputs["Vector"])
    nt.links.new(grad.outputs["Color"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    obj.data.materials.append(mat)
    return obj


def make_lights():
    def area(name, loc, rot, size, size_y, energy, color=(1, 1, 1)):
        data = bpy.data.lights.new(name, "AREA")
        data.shape = "RECTANGLE"
        data.size = size
        data.size_y = size_y
        data.energy = energy
        data.color = color
        ob = bpy.data.objects.new(name, data)
        ob.location = loc
        ob.rotation_euler = [math.radians(a) for a in rot]
        bpy.context.collection.objects.link(ob)
        return ob

    # Dark-stage studio: one large softbox pooled on the device (falls off
    # toward the frame top so captions land on near-black backdrop), two
    # narrow raking strips that draw the titanium rail as a light line, and
    # a whisper of frontal fill so the black bezel separates from the
    # backdrop. Continuity: same softbox+fill grammar as the keycap scene.
    # Energies are calibrated against the screen's emission strength 1.0
    # (UI white = 1.0): backdrop pool ~0.03 linear, rail highlights driven
    # by source radiance, not wattage.
    # Softbox tinted warm platinum (echoes the keycap plastic) so the pool
    # glows warm like the brand rather than clinical white.
    area("Large pooled softbox", (-0.26, -0.08, 0.34), (24, -22, 0),
         0.8, 0.8, 4.0, color=(1.0, 0.965, 0.915))
    area("Rail rake strip right", (0.30, -0.15, 0.12), (60, 62, 0),
         0.04, 0.8, 3.0)
    area("Rail rake strip left", (-0.30, -0.18, 0.10), (62, -60, 0),
         0.04, 0.8, 2.0)
    area("Tiny frontal fill", (0.0, -0.05, 0.5), (0, 0, 0), 0.4, 0.4, 0.5)


def make_camera(shot):
    pose = POSES[shot]
    cam_data = bpy.data.cameras.new("ShotCam")
    cam_data.lens = 85
    cam_data.sensor_fit = "VERTICAL"
    cam_data.sensor_height = 36.0
    cam = bpy.data.objects.new("ShotCam", cam_data)
    bpy.context.collection.objects.link(cam)
    bpy.context.scene.camera = cam
    # Camera looks straight down -Z from above; frame "up" is +Y.
    cam.location = (0.0, 0.0, 0.62)
    cam.rotation_euler = (0.0, 0.0, 0.0)
    return cam, pose


def pose_phone(objs, cam, pose):
    """Tilt the device, then place it so its (posed) bounding box sits with
    its bottom edge at `bottom_frac` of frame height, top cropping out."""
    rot_x, rot_y, rot_z, shift_x, bottom_frac, width_frac = pose[:6]
    import mathutils
    eul = mathutils.Euler((math.radians(rot_x), math.radians(rot_y),
                           math.radians(rot_z)), "XYZ")
    for ob in objs:
        ob.rotation_euler = eul

    bpy.context.view_layer.update()
    # Visible frame extents at the phone's depth (z≈0):
    scene = bpy.context.scene
    dist = cam.location.z
    frame_h = dist * 36.0 / 85.0          # sensor fit vertical
    frame_w = frame_h * (FINAL_W / FINAL_H)
    # Posed bounding box of the body (world space, after rotation):
    body = objs[0]
    corners = [eul.to_matrix() @ Vector(c) for c in
               [(-BODY_W / 2, -BODY_H / 2, 0), (BODY_W / 2, -BODY_H / 2, 0),
                (-BODY_W / 2, BODY_H / 2, 0), (BODY_W / 2, BODY_H / 2, 0),
                (-BODY_W / 2, -BODY_H / 2, BODY_T),
                (BODY_W / 2, -BODY_H / 2, BODY_T),
                (-BODY_W / 2, BODY_H / 2, BODY_T),
                (BODY_W / 2, BODY_H / 2, BODY_T)]]
    min_y = min(c.y for c in corners)
    # Set camera distance so the posed phone's projected width spans
    # width_frac of the frame width (width_frac > 1 crops top edges out).
    proj_w = max(c.x for c in corners) - min(c.x for c in corners)
    dist = dist * (proj_w / (width_frac * frame_w))
    cam.location.z = dist
    frame_h = dist * 36.0 / 85.0
    # Place bottom of phone at bottom_frac of frame height above frame bottom.
    target_y = -frame_h / 2 + bottom_frac * frame_h - min_y
    for ob in objs:
        ob.location = (shift_x, target_y, 0.0)
    bpy.context.view_layer.update()


# ------------------------------------------------------------------ main -----
def main():
    args = parse_args()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.name = "LyklabordShot"

    body = make_body()
    make_materials(body)
    make_backdrop()
    screen = make_screen(args.capture, POSES[args.shot][6],
                         POSES[args.shot][7])
    make_lights()
    cam, pose = make_camera(args.shot)
    pose_phone([body, screen], cam, pose)

    # World: very dark neutral so the glass sheen has something soft to see.
    world = bpy.data.worlds.new("Studio dark")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = \
        (0.02, 0.02, 0.022, 1.0)
    scene.world = world

    scene.render.engine = "CYCLES"
    scene.cycles.samples = 24 if args.preview else 160
    scene.cycles.use_denoising = True
    try:
        scene.cycles.device = "GPU"
        prefs = bpy.context.preferences.addons["cycles"].preferences
        prefs.compute_device_type = "METAL"
        prefs.get_devices()
        for d in prefs.devices:
            d.use = True
    except Exception:
        scene.cycles.device = "CPU"
    scene.render.film_transparent = False  # physical backdrop fills frame
    scale = 1 if args.preview else SUPER
    scene.render.resolution_x = FINAL_W * scale
    scene.render.resolution_y = FINAL_H * scale
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    # Standard transform: the screen texture must reproduce the capture's
    # sRGB values exactly (AgX/Filmic would tone-map the UI).
    scene.view_settings.view_transform = "Standard"
    scene.render.filepath = os.path.abspath(args.out)

    scene["shot"] = args.shot
    scene["capture"] = os.path.abspath(args.capture)
    scene["construction"] = ("procedural rounded-rect slab, weighted-edge "
                             "rail blend, emissive UI plane; mm-scaled")

    if args.save_blend:
        bpy.ops.file.pack_all()
        bpy.ops.wm.save_as_mainfile(
            filepath=os.path.abspath(args.save_blend))

    bpy.ops.render.render(write_still=True)
    print(f"RENDER_OK shot={args.shot} -> {args.out}")


main()
