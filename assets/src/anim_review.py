"""Render the exact sampled v2 pose functions at 120 pt review scale."""
import sys,math,json
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from common import *
import motion_v2 as motion
bpy.ops.wm.open_mainfile(filepath=str(ROOT/'src/moku_character.blend'))
rig=bpy.data.objects['Rig'];mesh=bpy.data.objects['Plush'];motion.bind(rig,mesh)
from compositor_camera import configure
scene=bpy.context.scene;configure(scene);scene.render.resolution_x=256;scene.render.resolution_y=256;scene.cycles.samples=8
out=ROOT/'previews/anim-v2';out.mkdir(exist_ok=True)
requested=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
if not requested or 'controls' in requested:
 for target in ['ears_lift','ear_antenna_L','ear_antenna_R']:
  for i in range(17):
   motion.neutral();motion.mood('content');motion.ear_lift(i/16,target);bpy.context.view_layer.update();render(out/f'{target}/{i:03d}.png')
 for i in range(9):
  motion.neutral();motion.mood('content')
  for side in ['L','R']:motion.shape('blink_'+side,i/8)
  bpy.context.view_layer.update();render(out/f'blink/{i:03d}.png')
if requested==['controls']:sys.exit(0)
records=[] if not requested else [r for r in json.loads((ROOT/'reports/anim-v2-frames.json').read_text()) if r['name'] not in requested]
for name,duration,loop in motion.CLIPS:
 if name in motion.ALIASES:continue
 if requested and name not in requested:continue
 duration=round(duration*24)/24;frames=max(6,round(duration*12))
 props=[]
 if name in ['drink_water','carry_lantern','build_hammer','tea_sit']:
  import world
  from mathutils import Matrix
  world.materials()
  if name=='build_hammer':
   from life_props import hammer
   props=hammer()
  else:props=world.lantern() if name=='carry_lantern' else world.cup()
  attach=json.loads((ROOT/'character/prop_attachments.json').read_text())[name];v=attach['wrapperLocalMatrixColumnMajor'];wrapper=Matrix([[v[c*4+r] for c in range(4)] for r in range(4)])
  conversion=Matrix.Rotation(-math.pi/2,4,'X');propRest=[o.matrix_world.copy() for o in props]
 def update_props(phase):
  for obj,rest in zip(props,propRest if props else []):
   obj.hide_render=not (attach['visibleNormalizedTime'][0]<=phase<=attach['visibleNormalizedTime'][1])
   obj.matrix_world=rig.matrix_world @ rig.pose.bones[attach['joint']].matrix @ wrapper @ conversion @ rest
  bpy.context.view_layer.update()
 for f in range(frames+1):
  motion.pose(name,duration*f/frames,duration);update_props(f/frames)
  render(out/f'{name}/{f:03d}.png')
 # Side view at primary action is a separate fit check, no camera change in the movie.
 old=scene.camera.matrix_world.copy();scene.camera.location=(3,-.4,.85);scene.camera.rotation_euler=(Vector((0,0,.58))-scene.camera.location).to_track_quat('-Z','Y').to_euler()
 motion.pose(name,duration*.45,duration);update_props(.45);render(out/f'{name}-profile.png');scene.camera.matrix_world=old
 for obj in props:bpy.data.objects.remove(obj,do_unlink=True)
 records.append({'name':name,'frames':frames+1,'fps':frames/duration,'duration':duration,'loop':loop,'source':'motion_v2.py (same sampled poses as USDZ)'})
(ROOT/'reports/anim-v2-frames.json').write_text(json.dumps(records,indent=2)+'\n')
