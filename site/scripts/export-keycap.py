"""Bake the Wave 5 procedural keycap material to textures and export a web GLB.

The Wave 4/5 material is fully procedural (object-space noise -> bump/roughness/
albedo) so it cannot export to glTF directly. This script:

  1. opens Lyklabord-Keycap-Wave5.blend
  2. Smart-UV-projects the keycap mesh (it has no UVs)
  3. Cycles-bakes albedo / roughness / tangent normal to textures
  4. rebuilds a Principled material from the baked maps
  5. keeps the legend as REAL GEOMETRY (the conformed dye-sub decal + 24%
     diffusion fringe) with simple charcoal materials -- crispest possible
     legend, resolution independent; shrinkwrap offsets are raised slightly
     (~0.04 mm) so WebGL depth precision never z-fights
  6. exports keycap + legend + fringe to GLB (Y-up, modifiers applied)

Run:
    blender --background --python site/scripts/export-keycap.py

Scene scale: 1 Blender unit ~= 8.887 mm (17.77458 mm AEK II footprint = 2.0 u).
Output: site/scripts/out/keycap-raw.glb  (+ baked PNGs for inspection)
"""

import os
import sys

import bpy

BLEND = os.path.expanduser("~/Downloads/lyklabord_3d/Lyklabord-Keycap-Wave5.blend")
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
os.makedirs(OUT_DIR, exist_ok=True)
GLB = os.path.join(OUT_DIR, "keycap-raw.glb")

BAKE_SIZE = 2048
KEYCAP = "Apple_AEKII_QWERTY_Keycap"
DECAL = "Printed_D_Eth_Legend_RENDER_CONFORMED"
FRINGE = "Printed_D_Eth_DYE_DIFFUSION_FRINGE"


def srgb_channel_to_linear(value):
    value /= 255.0
    if value <= 0.04045:
        return value / 12.92
    return ((value + 0.055) / 1.055) ** 2.4


def hex_color(value):
    value = value.lstrip("#")
    return tuple(
        srgb_channel_to_linear(int(value[i : i + 2], 16)) for i in (0, 2, 4)
    ) + (1.0,)


bpy.ops.wm.open_mainfile(filepath=BLEND)

keycap = bpy.data.objects[KEYCAP]
decal = bpy.data.objects[DECAL]
fringe = bpy.data.objects[FRINGE]

# ---------------------------------------------------------------------------
# 1. Raise the decal offsets from ~7.5um to ~40um so WebGL never z-fights.
# ---------------------------------------------------------------------------
for obj, offset in ((decal, 0.0048), (fringe, 0.0040)):
    for modifier in obj.modifiers:
        if modifier.type == "SHRINKWRAP":
            modifier.offset = offset

# ---------------------------------------------------------------------------
# 2. Smart UV project the keycap (mesh was built with from_pydata, no UVs).
# ---------------------------------------------------------------------------
bpy.ops.object.select_all(action="DESELECT")
keycap.select_set(True)
bpy.context.view_layer.objects.active = keycap
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.uv.smart_project(angle_limit=1.15192, island_margin=0.004)  # 66 degrees
bpy.ops.object.mode_set(mode="OBJECT")

# ---------------------------------------------------------------------------
# 3. Cycles bake: albedo (diffuse color), roughness, tangent-space normal.
#    All three passes are deterministic (no lighting) -> few samples needed.
# ---------------------------------------------------------------------------
scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.device = "CPU"
scene.cycles.samples = 16
scene.render.bake.margin = 8
scene.render.bake.use_selected_to_active = False
scene.render.bake.use_clear = True

material = keycap.data.materials[0]
nodes = material.node_tree.nodes

bake_specs = (
    ("albedo", "DIFFUSE", "sRGB", {"COLOR"}),
    ("roughness", "ROUGHNESS", "Non-Color", None),
    ("normal", "NORMAL", "Non-Color", None),
)

baked_paths = {}
for name, bake_type, colorspace, pass_filter in bake_specs:
    image = bpy.data.images.new(
        f"bake_{name}", BAKE_SIZE, BAKE_SIZE, alpha=False, float_buffer=False
    )
    image.colorspace_settings.name = colorspace
    node = nodes.new("ShaderNodeTexImage")
    node.name = f"BAKE_{name}"
    node.image = image
    nodes.active = node
    node.select = True

    kwargs = {"type": bake_type}
    if pass_filter:
        kwargs["pass_filter"] = pass_filter
    print(f"Baking {name} ({bake_type}) at {BAKE_SIZE}...")
    result = bpy.ops.object.bake(**kwargs)
    if result != {"FINISHED"}:
        print(f"BAKE FAILED: {name} -> {result}")
        sys.exit(1)

    path = os.path.join(OUT_DIR, f"keycap_{name}.png")
    image.filepath_raw = path
    image.file_format = "PNG"
    image.save()
    baked_paths[name] = path
    print(f"  saved {path}")

# ---------------------------------------------------------------------------
# 4. Replace the procedural material with a baked Principled setup.
# ---------------------------------------------------------------------------
export_material = bpy.data.materials.new("Keycap_PBT_Baked")
export_material.use_nodes = True
tree = export_material.node_tree
tree.nodes.clear()

bsdf = tree.nodes.new("ShaderNodeBsdfPrincipled")
output = tree.nodes.new("ShaderNodeOutputMaterial")
tree.links.new(bsdf.outputs["BSDF"], output.inputs["Surface"])
bsdf.inputs["IOR"].default_value = 1.46

albedo_node = tree.nodes.new("ShaderNodeTexImage")
albedo_node.image = bpy.data.images.load(baked_paths["albedo"])
albedo_node.image.colorspace_settings.name = "sRGB"
tree.links.new(albedo_node.outputs["Color"], bsdf.inputs["Base Color"])

rough_node = tree.nodes.new("ShaderNodeTexImage")
rough_node.image = bpy.data.images.load(baked_paths["roughness"])
rough_node.image.colorspace_settings.name = "Non-Color"
tree.links.new(rough_node.outputs["Color"], bsdf.inputs["Roughness"])

normal_tex = tree.nodes.new("ShaderNodeTexImage")
normal_tex.image = bpy.data.images.load(baked_paths["normal"])
normal_tex.image.colorspace_settings.name = "Non-Color"
normal_map = tree.nodes.new("ShaderNodeNormalMap")
tree.links.new(normal_tex.outputs["Color"], normal_map.inputs["Color"])
tree.links.new(normal_map.outputs["Normal"], bsdf.inputs["Normal"])

keycap.data.materials.clear()
keycap.data.materials.append(export_material)

# ---------------------------------------------------------------------------
# 5. Simple charcoal materials for the legend geometry.
#    Dye core: #1C1B1A, satin (Wave 5 measured roughness 0.54-0.60).
# ---------------------------------------------------------------------------
def charcoal(name, alpha=1.0):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    b = mat.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = hex_color("#1C1B1A")
    b.inputs["Roughness"].default_value = 0.57
    b.inputs["IOR"].default_value = 1.46
    b.inputs["Alpha"].default_value = alpha
    if alpha < 1.0:
        if hasattr(mat, "surface_render_method"):
            mat.surface_render_method = "BLENDED"
        if hasattr(mat, "blend_method"):
            mat.blend_method = "BLEND"
    return mat


decal.data.materials.clear()
decal.data.materials.append(charcoal("Legend_Dye_Core"))
fringe.data.materials.clear()
fringe.data.materials.append(charcoal("Legend_Dye_Fringe", alpha=0.24))

# ---------------------------------------------------------------------------
# 6. Export GLB: keycap + decal + fringe only, modifiers applied, Y-up.
# ---------------------------------------------------------------------------
bpy.ops.object.select_all(action="DESELECT")
for obj in (keycap, decal, fringe):
    obj.hide_set(False)
    obj.hide_render = False
    obj.select_set(True)
bpy.context.view_layer.objects.active = keycap

bpy.ops.export_scene.gltf(
    filepath=GLB,
    export_format="GLB",
    use_selection=True,
    export_apply=True,
    export_yup=True,
    export_image_format="AUTO",
)
print(f"Exported: {GLB} ({os.path.getsize(GLB)} bytes)")
