"""Moku for the web: the same character and clips as the app, as one GLB for the landing page (three.js).

Each clip is baked frame by frame exactly as animate.py bakes the app's USDZ clips (motion_v2.pose at 24 fps,
bones and face), pushed to an NLA track of the same name on the rig and on the face, and exported with
NLA_TRACKS so each clip becomes one glTF animation. Morph targets are exported sparse (most shapes move only
the face or the ears), the rest pose wears the content mood.

Run in Blender 5.2:
  Blender --background --factory-startup --python-exit-code 1 --python assets/src/web_export.py -- <out.glb>
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import *
from motion_v2 import *

out = Path(sys.argv[sys.argv.index('--') + 1])
bpy.ops.wm.open_mainfile(filepath=str(ROOT / 'src/moku_character.blend'))
rig = bpy.data.objects['Rig']; mesh = bpy.data.objects['Plush']
bind(rig, mesh)
scene = bpy.context.scene; scene.render.fps = 24

# The clips the page plays: at rest, meeting you, being patted, the drift and the return, the drink, sleep.
CLIPS = [('idle_breathe', 4), ('look_around', 3.5), ('hello_wave', 3), ('wave', 2.2), ('nod', 1.3), ('cheer', 2.2),
         ('celebrate', 1.8), ('pat_reaction', 1.5), ('sit_up_tall', 1.2), ('settle_down', 1.2), ('hop_cycle', 13 / 24),
         ('disappointed_hold', 4), ('annoyed_hold', 4), ('drink_water', DRINK_SECONDS), ('yawn', 3), ('stretch', 3.2),
         ('sleep_loop', 5)]

def bake(name, seconds):
    # A fresh action per clip; the clips already baked stay on their NLA tracks.
    for owner in (rig, mesh.data.shape_keys):
        if owner.animation_data: owner.animation_data.action = None
    neutral()
    frames = round(seconds * 24)
    for f in range(frames + 1):
        scene.frame_set(f + 1); pose(name, f / 24, frames / 24)
        for b in rig.pose.bones:
            for prop in ['location', 'rotation_euler', 'scale']: b.keyframe_insert(data_path=prop, frame=f + 1, group=b.name)
        for k in list(mesh.data.shape_keys.key_blocks)[1:]: k.keyframe_insert(data_path='value', frame=f + 1)
    for owner in (rig, mesh.data.shape_keys):
        data = owner.animation_data; action = data.action; action.name = f'{name}__{"face" if owner != rig else "body"}'
        track = data.nla_tracks.new(); track.name = name
        track.strips.new(name, 1, action); data.action = None

# The drink's cup, skinned to hand_R so the browser's skinning carries it exactly as Blender poses it. It's built
# where the app holds it (the paws up, just before the first sip) and moved into the rest pose, so the same
# pose brings it back to the lips. The page shows it only while drink_water plays.
import world
from mathutils import Matrix
world.materials()
neutral(); pose('drink_water', 2.4, DRINK_SECONDS); bpy.context.view_layer.update()
hand_pose = rig.pose.bones['hand_R'].matrix.copy(); hand_rest = rig.data.bones['hand_R'].matrix_local.copy()
parts = world.cup()
for o in parts: o.location += Vector((0, -.31, .355))
bpy.ops.object.select_all(action='DESELECT')
for o in parts: o.select_set(True)
bpy.context.view_layer.objects.active = parts[0]; bpy.ops.object.join()
cup = bpy.context.view_layer.objects.active; cup.name = 'WaterCup'
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
to_rest = rig.matrix_world @ hand_rest @ hand_pose.inverted() @ rig.matrix_world.inverted()
cup.data.transform(to_rest)
group = cup.vertex_groups.new(name='hand_R'); group.add(list(range(len(cup.data.vertices))), 1.0, 'REPLACE')
cup.parent = rig; cup.modifiers.new('Armature', 'ARMATURE').object = rig
neutral()

for name, seconds in CLIPS: bake(name, seconds)
neutral(); mood('content'); scene.frame_set(1)
bpy.ops.object.select_all(action='DESELECT'); rig.select_set(True); mesh.select_set(True); cup.select_set(True); bpy.context.view_layer.objects.active = rig
out.parent.mkdir(parents=True, exist_ok=True)
bpy.ops.export_scene.gltf(filepath=str(out), export_format='GLB', use_selection=True, export_apply=False,
    export_animations=True, export_animation_mode='NLA_TRACKS', export_skins=True, export_morph=True,
    export_morph_normal=False, export_morph_animation=True, export_try_sparse_sk=True, export_try_omit_sparse_sk=True,
    export_optimize_animation_size=True, export_image_format='WEBP', export_image_quality=88, export_yup=True)
print('WEB_EXPORT', out, round(out.stat().st_size / 1e6, 2), 'MB')
