"""Front and recipe gaze authoring views; output only, no changes to asset baseline."""
from pathlib import Path
import sys,math
sys.path.insert(0,str(Path(__file__).resolve().parent))
from common import *
from moods import MOODS
from decal_preview import apply as apply_decal
from compositor_camera import configure
bpy.ops.wm.open_mainfile(filepath=str(ROOT/'src/moku_character.blend'))
rig=bpy.data.objects['Rig'];mesh=bpy.data.objects['Plush'];scene=bpy.context.scene
configure(scene);scene.render.resolution_x=768;scene.render.resolution_y=768;scene.cycles.samples=24
for b in rig.pose.bones:b.rotation_mode='XYZ'
for mood,(weights,joints,_) in MOODS.items():
 for view in ['front','gaze']:
  for b in rig.pose.bones:b.rotation_euler=(0,0,0)
  for k in mesh.data.shape_keys.key_blocks:k.value=0
  for k,v in weights.items():mesh.data.shape_keys.key_blocks[k].value=v
  for k,v in joints.items():rig.pose.bones[k].rotation_euler=[math.radians(x) for x in v]
  if view=='front':rig.pose.bones['head'].rotation_euler.y=0
  if view=='gaze' and mood=='content':
   rig.pose.bones['head'].rotation_euler=[math.radians(x) for x in [-9,24,4]];rig.pose.bones['chest'].rotation_euler.y=math.radians(9)
  apply_decal(mood);bpy.context.view_layer.update();render(ROOT/f'previews/creative/{mood}_{view}.png')
# Profile evidence for the crossed-paw corrective, including the held blend pose.
for k in mesh.data.shape_keys.key_blocks:k.value=0
for b in rig.pose.bones:b.rotation_euler=(0,0,0)
for k,v in MOODS['disappointed'][0].items():mesh.data.shape_keys.key_blocks[k].value=v
for k,v in MOODS['disappointed'][1].items():rig.pose.bones[k].rotation_euler=[math.radians(x) for x in v]
apply_decal('disappointed');bpy.context.view_layer.update();camera=scene.camera
camera.location=(2.8,-1.6,.9);camera.rotation_euler=(Vector((0,0,.48))-camera.location).to_track_quat('-Z','Y').to_euler()
render(ROOT/'previews/folded-paws-fit.png')
for k in mesh.data.shape_keys.key_blocks:k.value=0
for b in rig.pose.bones:b.rotation_euler=(0,0,0)
for k,v in MOODS['annoyed'][0].items():mesh.data.shape_keys.key_blocks[k].value=v
for k,v in MOODS['annoyed'][1].items():rig.pose.bones[k].rotation_euler=[math.radians(x) for x in v]
apply_decal('annoyed');bpy.context.view_layer.update();render(ROOT/'previews/crossed-arms-fit.png')
