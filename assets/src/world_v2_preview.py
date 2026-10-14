"""Compose the exported kit's exact placements, with registered blueprint paper."""
import sys,json,math
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from common import *
from mathutils import Matrix,Quaternion
bpy.ops.wm.open_mainfile(filepath=str(ROOT/'src/world_v2.blend'))
layout=json.loads((ROOT/'world/layouts.json').read_text());prototypes={r['name']:bpy.data.objects[r['name']] for r in layout['kit'] if r['name'] in bpy.data.objects};C=Matrix.Rotation(-math.pi/2,4,'X')
placed=[]
def put(record):
 source=prototypes[record['asset']];o=source.copy();o.data=source.data;bpy.context.collection.objects.link(o);o.hide_render=False;o.hide_set(False)
 x,y,z=record['translation'];o.location=(x,-z,y);s=record['scale'];o.scale=(s[0],s[2],s[1]);q=record['rotationQuaternion'];o.rotation_mode='QUATERNION';o.rotation_quaternion=(C.inverted() @ Quaternion((q[3],q[0],q[1],q[2])).to_matrix().to_4x4() @ C).to_quaternion()
 placed.append(o);return o
# A textured page lies 2mm in front of the wooden board. Same UVs for every project/layer.
def board_page(name,texture):
 me=bpy.data.meshes.new('Blueprint paper');me.from_pydata([(-.42,-.036,.365),(.42,-.036,.365),(.42,-.036,.995),(-.42,-.036,.995)],[],[(0,1,2,3)]);me.update();uv=me.uv_layers.new(name='UVMap')
 for li,value in enumerate([(0,0),(1,0),(1,1),(0,1)]):uv.data[li].uv=value
 o=bpy.data.objects.new(name,me);bpy.context.collection.objects.link(o);m=mat('Craft blueprint paper',(1,1,1),1)
 tex=m.node_tree.nodes.new('ShaderNodeTexImage');tex.image=bpy.data.images.load(str(texture),check_existing=True);m.node_tree.links.new(tex.outputs['Color'],m.node_tree.nodes.get('Principled BSDF').inputs['Base Color']);finish(o,name,m);return o
page=board_page('blueprint_page',ROOT/'world/blueprints/plot_example.png');export(ROOT/'world/kit/blueprint_page.usdz',[page]);page.hide_render=True;page.hide_set(True);prototypes['blueprint_page']=page
if not any(a['name']=='blueprint_page' for a in layout['kit']):layout['kit'].append({'name':'blueprint_page','file':'kit/blueprint_page.usdz','triangles':2,'pivot':'ground'})
layout['blueprintPage']={'asset':'blueprint_page','sameTransformAs':'blueprintAnchor','material':'Craft blueprint paper','uv':'full 0…1; top of paper is V=1','use':'Composite paper + context + pending + completed unit ink into one cached texture; assign to baseColor. Rebuild only on progress changes. For readable 370pt pane, show matching flat blueprint at >=96pt width.'}
# Append Moku once, hidden source. Reuse its real plush and rig at the door.
with bpy.data.libraries.load(str(ROOT/'src/moku_character.blend'),link=False) as (src,dst):dst.objects=['Rig','Plush']
for o in dst.objects:bpy.context.collection.objects.link(o)
rig=bpy.data.objects['Rig'];bunny=bpy.data.objects['Plush'];rig.scale=(.40,.40,.40);rig.location=(.69,-1.14,.10);rig.hide_render=True;bunny.hide_render=True
cam=studio(target=(0,0,.42),ortho=8);scene=bpy.context.scene;scene.render.resolution_x=1000;scene.render.resolution_y=900;scene.cycles.samples=32
requested=set(sys.argv[sys.argv.index('--')+1:]) if '--' in sys.argv else set()
records=[] if not requested else list(layout.get('homePreviews',[]))
def plain(asset,loc=(0,0,0),scale=(1,1,1)):return {'asset':asset,'translation':[loc[0],loc[2],-loc[1]],'scale':[scale[0],scale[2],scale[1]],'rotationQuaternion':[0,0,0,1]}
def compose(hours,forced=None):
 if requested and (('stage_'+str(forced)) if forced is not None else str(hours)) not in requested:return
 for o in placed:bpy.data.objects.remove(o,do_unlink=True)
 placed.clear();points=hours*60;treeCount=min(200,int(hours));active=max([p['index'] for p in layout['projects'] if p['startPoints']<=points] or [0]);completed=min(layout['projects'][active]['unitCount'],max(0,int((points-layout['projects'][active]['startPoints'])//10)))
 if forced is not None:active=min(6,forced);completed=layout['projects'][active]['unitCount']
 planted=layout['treeSlots'][:treeCount];radius=max([2.55]+[(r['translation'][0]**2+r['translation'][2]**2)**.5+.65 for r in planted])
 put(plain('island',scale=(radius/5.83,radius/5.83,1)));put(plain('site_dressing'))
 for pr in layout['projects']:
  if pr['index']>active:break
  n=pr['unitCount'] if pr['index']<active else completed
  if pr.get('structuralBase') and n:
   for r in pr['structuralBase']:put(r)
  for r in pr['slots'][:n]:put(r)
  if n==pr['unitCount']:
   for r in pr['finale']:put(r)
 # Only the next three pieces are ghosted, never a wireframe whole house.
 ghost=mat('Next three pieces',(.90,.85,.70),1);ghost.node_tree.nodes.get('Principled BSDF').inputs['Alpha'].default_value=.25
 for r in layout['projects'][active]['slots'][completed:completed+3]:
  o=put(r);o.data=o.data.copy();o.data.materials.clear();o.data.materials.append(ghost)
 if active<5:put(layout['tentAnchor'])
 if active in [2,3,4]:put(plain('scaffolding'))
 if active<7:
  put(layout['siteProps'][0])
  if active in [2,3,4]:put(layout['siteProps'][1])
 for r in planted:put(r)
 returns={0:0,3:2,25:14,120:65}.get(hours,min(100,int(hours/2)))
 for r in layout['pathSlots'][:returns]:
  if r['translation'][0]**2+r['translation'][2]**2<(radius-.12)**2:put(r)
 put(layout['blueprintAnchor']);paper=put({**layout['blueprintAnchor'],'asset':'blueprint_page'})
 name=layout['projects'][active]['id'];tex=bpy.data.images.load(str(ROOT/f'world/blueprints/progress_{hours:03d}h.png'),check_existing=True) if (ROOT/f'world/blueprints/progress_{hours:03d}h.png').exists() and forced is None else bpy.data.images.load(str(ROOT/f'world/blueprints/{name}_example.png'),check_existing=True)
 m=page.data.materials[0].copy();m.name='Blueprint progress '+str(hours);m.node_tree.nodes.get('Image Texture').image=tex;paper.data=page.data.copy();paper.data.materials.clear();paper.data.materials.append(m)
 rig.hide_render=False;bunny.hide_render=False
 distance=radius*2;cam.location=(distance*.70,-distance*1.4,distance*.97);target=Vector((0,0,.26));cam.rotation_euler=(target-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.ortho_scale=radius*2.42
 label=f'focus_{hours:03d}h' if forced is None else f'home_stage_{forced}_{name if forced<7 else "home"}'
 render(ROOT/f'previews/world-v2/{label}.png')
 records[:]=[r for r in records if r['name']!=label]
 records.append({'name':label,'hours':hours,'trees':treeCount,'project':name,'completedUnits':completed,'unitCount':layout['projects'][active]['unitCount'],'exampleReturns':returns,'cameraOrthoScale':cam.data.ortho_scale,'islandRadius':radius,'preview':f'../previews/world-v2/{label}.png'})
for hours in [0,1,3,5,20,25,100,120]:compose(hours)
for i,h in enumerate([0,1,2,5,10,25,67,167]):compose(h,i)
layout['homePreviews']=records;layout['islandRadiusRule']='max(2.55, radius of farthest planted slot + .65); scale island X/Z by radius/5.83, Y=1';layout['previewCamera']={'positionRatio':[.70,.97,1.4],'target':[0,.26,0],'orthoScale':'islandRadius * 2.42'}
(ROOT/'world/layouts.json').write_text(json.dumps(layout,indent=2)+'\n')
(ROOT/'reports/world-v2.json').write_text(json.dumps({'kit':layout['kit'],'previews':records,'totalProjectUnits':1000,'treeSlots':200,'pathSlots':200},indent=2)+'\n')
