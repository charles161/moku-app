"""Transparent micro-expression samples, always on the soft content baseline."""
from pathlib import Path
import sys,math
sys.path.insert(0,str(Path(__file__).resolve().parent))
from common import *
from moods import MOODS
from compositor_camera import configure
bpy.ops.wm.open_mainfile(filepath=str(ROOT/'src/moku_character.blend'))
rig=bpy.data.objects['Rig'];mesh=bpy.data.objects['Plush'];scene=bpy.context.scene
configure(scene);scene.render.resolution_x=768;scene.render.resolution_y=768;scene.cycles.samples=24
for b in rig.pose.bones:b.rotation_mode='XYZ'
for name in ['brow_raise_L','brow_raise_R','lips_press','eyes_narrow']:
 for weight in [.2,.35,.5]:
  for k in mesh.data.shape_keys.key_blocks:k.value=0
  for k,v in MOODS['content'][0].items():mesh.data.shape_keys.key_blocks[k].value=v
  for k,v in MOODS['content'][1].items():rig.pose.bones[k].rotation_euler=[math.radians(x) for x in v]
  mesh.data.shape_keys.key_blocks[name].value=weight;bpy.context.view_layer.update()
  render(ROOT/f'previews/micro/{name}_{int(weight*100):02d}.png')
