"""A compact static companion for the web cottage, from the original Blender rig."""
import sys
from pathlib import Path
import bpy

WEB = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WEB.parent / 'assets/src'))
from motion_v2 import bind, neutral, mood
bpy.ops.wm.open_mainfile(filepath=str(WEB.parent / 'assets/src/moku_character.blend'))
rig = bpy.data.objects['Rig']
plush = bpy.data.objects['Plush']
bind(rig, plush)
neutral()
mood('content')
bpy.context.view_layer.update()
evaluated = plush.evaluated_get(bpy.context.evaluated_depsgraph_get())
mesh = bpy.data.meshes.new_from_object(evaluated)
static = bpy.data.objects.new('Moku', mesh)
bpy.context.collection.objects.link(static)
static.matrix_world = plush.matrix_world.copy()
bpy.ops.object.select_all(action='DESELECT')
static.select_set(True)
bpy.context.view_layer.objects.active = static
out = WEB / 'public/models/companion.glb'
bpy.ops.export_scene.gltf(filepath=str(out), export_format='GLB', use_selection=True,
    export_animations=False, export_skins=False, export_morph=False, export_yup=True,
    export_image_format='WEBP', export_image_quality=85,
    export_draco_mesh_compression_enable=True, export_draco_mesh_compression_level=6)
print('WEB_COMPANION', out.stat().st_size, 'bytes')
