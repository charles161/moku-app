from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from common import *
bpy.ops.wm.open_mainfile(filepath=str(ROOT/'src/moku_character.blend'))
scene=bpy.context.scene;rig=bpy.data.objects['Rig'];rig.scale=(.87,.87,.87);rig.location.z=.09
card=mat('App icon forest enamel',(.085,.22,.14),.7)
outline=[]
for cx,cz,start in [(.475,.475,0),(-.475,.475,90),(-.475,-.475,180),(.475,-.475,270)]:
 for i in range(13):
  a=math.radians(start+i*90/12);outline.append((cx+.18*math.cos(a),cz+.18*math.sin(a)))
verts=[(x,y,z+.54) for y in [.31,.41] for x,z in outline];n=len(outline)
faces=[tuple(reversed(range(n))),tuple(range(n,n*2))]+[(i,(i+1)%n,(i+1)%n+n,i+n) for i in range(n)]
me=bpy.data.meshes.new('IconTile');me.from_pydata(verts,[],faces);me.update();o=bpy.data.objects.new('IconTile',me);bpy.context.collection.objects.link(o);select([o])
mod=o.modifiers.new('Soft enamel edges','BEVEL');mod.width=.014;mod.segments=4;bpy.ops.object.modifier_apply(modifier=mod.name);finish(o,'IconTile',card)

cam=scene.camera;cam.location=(0,-3,.65);cam.rotation_euler=(Vector((0,0,.54))-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.ortho_scale=1.47
scene.render.resolution_x=1024;scene.render.resolution_y=1024;scene.cycles.samples=96
render(ROOT/'icons/AppIcon.png')
