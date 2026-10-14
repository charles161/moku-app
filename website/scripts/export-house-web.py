"""Export the app's existing daily-house pieces without changing native assets.

Blender --background --factory-startup --python scripts/export-house-web.py
"""
import json
from pathlib import Path
import bpy

WEB = Path(__file__).resolve().parents[1]
SOURCE = WEB.parent / 'assets/world/dayhouse'
layout = json.loads((SOURCE / 'layout.json').read_text())['homes']['dayhouse']
piece_names = [item['asset'] for stage in layout['stages'] for item in stage['items']]
site_names = [item['asset'] for item in layout['terrain']]
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)

for name in ['plot', *piece_names, *site_names]:
    before = set(bpy.data.objects)
    bpy.ops.wm.usd_import(filepath=str(SOURCE / (name + '.usdz')))
    imported = set(bpy.data.objects) - before
    meshes = [obj for obj in imported if obj.type == 'MESH']
    bpy.ops.object.select_all(action='DESELECT')
    for obj in meshes:
        matrix = obj.matrix_world.copy()
        obj.parent = None
        obj.matrix_world = matrix
        obj.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1:
        bpy.ops.object.join()
    obj = bpy.context.object
    obj.name = name
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    for empty in imported:
        if empty.name in bpy.data.objects and empty.type == 'EMPTY':
            bpy.data.objects.remove(empty, do_unlink=True)

# Reuse identical flat materials across pieces; the native house carries no textures.
canonical = {}
for obj in bpy.context.scene.objects:
    if obj.type != 'MESH':
        continue
    for slot in obj.material_slots:
        material = slot.material
        if not material:
            continue
        base = material.name.split('.')[0]
        if base in canonical:
            slot.material = canonical[base]
        else:
            canonical[base] = material

out = WEB / 'public/models/daily-house.glb'
out.parent.mkdir(parents=True, exist_ok=True)
bpy.ops.export_scene.gltf(filepath=str(out), export_format='GLB', export_animations=False,
    export_cameras=False, export_lights=False, export_yup=True, export_texcoords=False,
    export_draco_mesh_compression_enable=True, export_draco_mesh_compression_level=6)
(out.parent / 'daily-house.json').write_text(json.dumps({'pieces': piece_names, 'sites': site_names}))
print('WEB_HOUSE', out.stat().st_size, 'bytes')
