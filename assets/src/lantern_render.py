"""Render the shipped USDZ into registered lantern bodies and independent flames."""
import bpy,sys,math,json
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from common import *
reset();bpy.ops.wm.usd_import(filepath=str(ROOT/'props/lantern.usdz'))
objects=[o for o in bpy.context.scene.objects if o.type=='MESH']
# Blender converts the imported USD Y-up back to authoring Z-up.
scene=bpy.context.scene;cam=studio(target=(0,0,.145),distance=1,ortho=.345)
cam.location=(.28,-1,.29);cam.rotation_euler=(Vector((0,0,.145))-cam.location).to_track_quat('-Z','Y').to_euler()
scene.render.resolution_x=312;scene.render.resolution_y=408;scene.cycles.samples=64
OUT=ROOT/'lantern';OUT.mkdir(exist_ok=True)
materials=[m for o in objects for m in o.data.materials if 'Amber' in m.name]
assert materials,[(o.name,[m.name for m in o.data.materials]) for o in objects]
def linear(h):
 rgb=[int(h[i:i+2],16)/255 for i in [1,3,5]]
 return tuple(x/12.92 if x<=.04045 else ((x+.055)/1.055)**2.4 for x in rgb)
for state,color,power in [('lit','#F3B04E',2.2),('low','#E6CC98',.85),('ember','#D9A25A',.18)]:
 for m in materials:
  p=m.node_tree.nodes.get('Principled BSDF');p.inputs['Base Color'].default_value=(*linear(color),1);p.inputs['Emission Color'].default_value=(*linear(color),1);p.inputs['Emission Strength'].default_value=power
 render(OUT/f'body_{state}_master.png')
for obj in objects:obj.hide_render=True
# A warm teardrop with a separate pale core, rendered on the same registered canvas.
body=mat('Flame amber',linear('#F3B04E'),.85,emission=1.5);core=mat('Flame core',linear('#FFE7B0'),.8,emission=2)
verts=[];faces=[];rings=18;segments=28
for j in range(rings+1):
 t=j/rings;z=.067+t*.087;r=.019*math.sin(math.pi*t)**.72*(1-.55*t);cx=.010*t*t
 for k in range(segments):a=2*math.pi*k/segments;verts.append((cx+r*math.cos(a),-.053+r*.36*math.sin(a),z))
for j in range(rings):
 for k in range(segments):a=j*segments+k;b=j*segments+(k+1)%segments;faces.append((a,b,b+segments,a+segments))
me=bpy.data.meshes.new('Flame');me.from_pydata(verts,[],faces);me.update();o=bpy.data.objects.new('Flame',me);bpy.context.collection.objects.link(o);finish(o,'Flame',body)
c=sphere('Core',(0,-.062,.089),(.009,.004,.021),core,24,14)
for state,scale,color in [('lit',1,'#F3B04E'),('low',.72,'#E6CC98'),('ember',.38,'#D9A25A')]:
 for obj in [o,c]:obj.scale=(scale,scale,scale);obj.location.z=.067*(1-scale)
 p=body.node_tree.nodes.get('Principled BSDF');p.inputs['Base Color'].default_value=(*linear(color),1);p.inputs['Emission Color'].default_value=(*linear(color),1)
 render(OUT/f'flame_{state}_master.png')
# Projected registration anchors, top-left normalized coordinates.
from bpy_extras.object_utils import world_to_camera_view
anchors={}
for name,co in [('ground',(0,0,0)),('flame',(0,-.055,.105)),('handle',(0,0,.272))]:
 v=world_to_camera_view(scene,cam,Vector(co));anchors[name]=[v.x,1-v.y]
(OUT/'render_anchors.json').write_text(json.dumps(anchors,indent=2)+'\n')
