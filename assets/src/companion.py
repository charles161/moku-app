"""What every companion shares: the rig contract, the morph names, the build pipeline and the export.

A companion is a species module (species_moku.py, species_tetsu.py; Yuzu's species_yuzu.py is at the yuzu-archive tag) that makes its own body,
head, ears (or antennae), tail, materials and face, and says how each part moves for each named morph. This file
joins the parts into one skinned mesh, adds the morphs in the shared order, writes the ear in-betweens, builds the
21-joint rig (plus any extra joints the species appends, such as a tail), and exports it in the format the app
reads. Because the joints and morph names are the same for every companion, the app's expression and motion code
is shared, and the clips (motion_v2.py) drive any of them.

Run a build with `character.py -- --companion=<id>` (Moku when omitted). Moku's files keep their historic paths
(character/moku_bunny.usdz); every other companion lives in character/<id>/ with <id>.usdz.
"""
import sys,math,json,random,importlib
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from common import *
from mathutils import Vector

COMPANIONS=['moku','tetsu']

def companion_id(argv=None):
 """--companion=<id> anywhere on the command line (after Blender's --); Moku when absent."""
 for value in (argv if argv is not None else sys.argv):
  if value.startswith('--companion='):
   cid=value.split('=',1)[1]
   assert cid in COMPANIONS,f'unknown companion {cid}'
   return cid
 return 'moku'

def species(cid=None):return importlib.import_module('species_'+(cid or companion_id()))

class Paths:
 """Where a companion's files go. Moku keeps today's paths so nothing the app or the site reads moves."""
 def __init__(self,cid):
  moku=cid=='moku'
  self.id=cid
  self.rel='character' if moku else f'character/{cid}'           # relative to assets/, as materials.json wants
  self.dir=ROOT/self.rel
  self.model=self.dir/('moku_bunny.usdz' if moku else f'{cid}.usdz')
  self.blend=ROOT/'src'/f'{cid}_character.blend'
  self.report=ROOT/'reports'/('character.json' if moku else f'{cid}-character.json')
  self.previews=ROOT/'previews' if moku else ROOT/'previews'/cid
  # From character/<id>/prop_attachments.json the shared props are one folder further up.
  self.props='../props' if moku else '../../props'
def paths(cid=None):return Paths(cid or companion_id())

# The rig contract. The app checks a clip's joints against its character's, by name, parent and order.
JOINTS=['root','hips','spine','chest','neck','head']
for _l in 'LR':JOINTS+=[f'ear_{_l}_01',f'ear_{_l}_02',f'eye_{_l}',f'arm_{_l}',f'hand_{_l}',f'leg_{_l}',f'foot_{_l}']
JOINTS.append('tail')
PARENTS={'root':None,'hips':'root','spine':'hips','chest':'spine','neck':'chest','head':'neck','tail':'hips'}
for _l in 'LR':PARENTS.update({f'ear_{_l}_01':'head',f'ear_{_l}_02':f'ear_{_l}_01',f'eye_{_l}':'head',f'arm_{_l}':'chest',f'hand_{_l}':f'arm_{_l}',f'leg_{_l}':'hips',f'foot_{_l}':f'leg_{_l}'})

# The morph names, in export order. The app's face code (FacialMorphs, ExpressionLife, RealityCharacter) drives
# these by name, so every companion has all of them, each meaning the same thing in its own face.
MORPHS=['blink_L','blink_R','eyes_happy','eyes_wide','brows_up','brows_concern','brows_angry','smile','frown','mouth_open','pout','cheeks_puff','mouth_smile_open','cheeks_raise','blush_more','eyes_look_down','brow_raise_L','brow_raise_R','lips_press','eyes_narrow','arms_fold','lid_flat','lid_sad','lid_smile_lower','eyes_proud','ears_curtain','ears_pinned','nose_twitch','ears_lift','ear_antenna_L','face_decals','eye_hidden_L','eye_hidden_R','ear_antenna_R','paws_lap']
# Ear poses with authored in-between shapes (ear_transitions.json): 15 keyposes each, named <target>_<phase>.
EAR_TARGETS=['ears_lift','ear_antenna_L','ear_antenna_R']
EAR_STEPS=16
def ear_step_name(target,step):
 suffix=str(step*625//10).zfill(3) if step%2==0 else str(step*625).zfill(4)
 return target+'_'+suffix

def write_ear_transitions(P,names,records):
 (P.dir/'ear_transitions.json').write_text(json.dumps({'schemaVersion':1,'durationSeconds':.36,'shapeRevision':3,'timing':{'riseSeconds':.36,'middlePhaseRange':[.3,.7],'middleMaximumSeconds':5/60,'overshootFraction':.08,'fall':'reverse path, softer landing bounce; clamp morph phase to 0…1 and use joint rotation for overshoot'},'reverseUsesSamePath':True,'interpolation':'piecewise linear weights between adjacent keyposes; ease phase, not weights twice','clearControls':[n for n in names if n.startswith(('ears_','ear_antenna'))],'paths':records,'routing':'To or from LIFT / ANTENNA, use these paths through LOP. Other endpoints first return to LOP. Never add intermediate controls to terminal morphs. Ear joints use zero offsets along these paths; apply final pose joint offsets after arrival.'},indent=2)+'\n')

def ear_transitions(mesh,member,names,sample):
 """In-between shapes for each ear target. `sample(side,target,phase,part_index,rest)` gives a point of that ear at
 `phase` (0 rest, 1 the target), for species whose ears follow a parametric path. Moku has its own (lop ears)."""
 records=[]
 for target in EAR_TARGETS:
  steps=[{'phase':0,'blendShapes':{},'jointEulerDegrees':{}}]
  for step in range(1,EAR_STEPS):
   phase=step/EAR_STEPS;name=ear_step_name(target,step);names.append(name)
   key=mesh.shape_key_add(name=name,from_mix=False);key.value=0
   for side in ['L','R']:
    if target.startswith('ear_antenna_') and not target.endswith(side):continue
    for part_index,idx in enumerate(member['ear_'+side]):
     key.data[idx].co=sample(side,target,phase,part_index,key.data[idx].co.copy())
  steps.append({'phase':phase,'blendShapes':{name:1},'jointEulerDegrees':{}})
  steps.append({'phase':1,'blendShapes':{target:1},'jointEulerDegrees':{}})
  records.append({'target':target,'keyposes':steps})
 return records

def build(sp):
 P=paths(sp.ID);P.dir.mkdir(parents=True,exist_ok=True)
 reset();random.seed(sp.SEED)
 sp.materials(P)
 parts=[];tags={};bindings={}
 def add(o,tag,joint):parts.append(o);tags[o.name]=tag;bindings[o.name]=joint;return o
 sp.build(add)
 select(parts);bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
 for o in parts:
  tag=tags[o.name];g=o.vertex_groups.new(name='part_'+tag);g.add(list(range(len(o.data.vertices))),1,'REPLACE');joint=bindings[o.name];vg=o.vertex_groups.new(name=joint)
  if not sp.skin(o,tag,joint,vg):vg.add(list(range(len(o.data.vertices))),1,'REPLACE')
 select(parts);bpy.context.view_layer.objects.active=parts[0];bpy.ops.object.join();mesh=bpy.context.object;mesh.name='Plush'
 member={}
 for g in mesh.vertex_groups:
  if g.name.startswith('part_'):member[g.name[5:]]=[v.index for v in mesh.data.vertices if any(x.group==g.index for x in v.groups)]
 mesh.shape_key_add(name='Basis',from_mix=False).value=0
 names=list(MORPHS)+list(getattr(sp,'EXTRA_MORPHS',[]))
 for name in names:
  key=mesh.shape_key_add(name=name,from_mix=False);key.value=0
  for tag,indices in member.items():
   for part_index,idx in enumerate(indices):
    co=key.data[idx].co;s=1 if tag.endswith('L') else -1
    sp.morph(name,tag,part_index,co,s)
 records=sp.ear_transitions(mesh,member,names)
 write_ear_transitions(P,names,records)
 # Scope regression: material-mode switches may never reshape ears or body.
 for control,prefixes in sp.SCOPES:
  for tag,indices in member.items():
   if not tag.startswith(prefixes):
    assert all((mesh.data.shape_keys.key_blocks[control].data[i].co-mesh.data.shape_keys.key_blocks['Basis'].data[i].co).length<1e-8 for i in indices),(control,tag)
 bpy.ops.object.armature_add(enter_editmode=True,location=(0,0,0));rig=bpy.context.object;rig.name='Rig';rig.data.edit_bones.remove(rig.data.edit_bones[0])
 bones=sp.bones()
 # The contract: the shared 21 joints first, in order and with the same parents; species extras after them.
 assert [b[0] for b in bones[:len(JOINTS)]]==JOINTS,[b[0] for b in bones]
 assert all(b[1]==PARENTS[b[0]] for b in bones[:len(JOINTS)])
 for name,parent,a,b in bones:
  e=rig.data.edit_bones.new(name);e.head=a;e.tail=b
  if parent:e.parent=rig.data.edit_bones[parent]
 bpy.ops.object.mode_set(mode='OBJECT');mod=mesh.modifiers.new('Plush skeleton','ARMATURE');mod.object=rig;mesh.parent=rig
 scene=bpy.context.scene;scene.render.fps=24;scene.frame_start=1;scene.frame_end=1
 # A species may finish the joined mesh before export (Moku bakes its felt's occlusion: occlusion.py).
 if hasattr(sp,'finish_mesh'):sp.finish_mesh(P,mesh,member)
 for k,v in sp.REST_WEIGHTS.items():mesh.data.shape_keys.key_blocks[k].value=v
 export(P.model,[rig,mesh])
 # Only the points each blend shape moves, and stand-ins for textures the app reads loose (slim_model.py).
 from slim_model import slim;print('SPARSE_SHAPES',slim(P.model,getattr(sp,'LOOSE_TEXTURES',())))
 for k in mesh.data.shape_keys.key_blocks:k.value=0
 for k,v in sp.REST_WEIGHTS.items():mesh.data.shape_keys.key_blocks[k].value=v
 count=triangles([mesh]);print('CHARACTER_TRIANGLES',count)
 assert count<getattr(sp,'TRIANGLE_BUDGET',40000),count
 P.report.write_text(json.dumps({'version':sp.VERSION,'triangles':count,'vertices':len(mesh.data.vertices),'joints':[b[0] for b in bones],'blendShapes':names,'materials':[m.name for m in mesh.data.materials]},indent=2))
 if hasattr(sp,'after_export'):sp.after_export(P,rig,mesh)
 cam=studio(target=(0,0,.46),distance=3,ortho=1.38);cam.location=(1.18,-3,1.0);cam.rotation_euler=(Vector((0,0,.46))-cam.location).to_track_quat('-Z','Y').to_euler();scene.cycles.samples=64
 # Warm neutral lighting with soft, low-contrast fill and gentle golden rim.
 bpy.data.objects['Key'].data.energy=310;bpy.data.objects['Key'].data.color=(1,.84,.65);bpy.data.objects['Fill'].data.energy=205;bpy.data.objects['Rim'].data.energy=190
 bpy.ops.wm.save_as_mainfile(filepath=str(P.blend))
 if '--quick' in sys.argv:sys.exit(0)
 P.previews.mkdir(parents=True,exist_ok=True)
 render(P.previews/'character.png')
 for view,pos in [('front',(0,-3,.58)),('side',(3,0,.57)),('back',(0,3,.57))]:
  cam.location=pos;cam.rotation_euler=(Vector((0,0,.46))-cam.location).to_track_quat('-Z','Y').to_euler();render(P.previews/f'character_{view}.png')

def aim_degrees(rig,bone,direction):
 """Local XYZ degrees that turn `bone` to point along `direction` (armature space), as derive_mood_ears does."""
 b=rig.data.bones[bone];r=b.matrix_local.to_quaternion()
 world=(b.tail_local-b.head_local).rotation_difference(Vector(direction));q=r.inverted() @ world @ r
 return [round(math.degrees(a),4) for a in q.to_euler('XYZ')]
def tilt_degrees(rig,bone,outward,forward,side):
 """Local XYZ degrees that tilt `bone` `outward` (away from the middle) and `forward` (toward the viewer), in degrees."""
 from mathutils import Quaternion
 b=rig.data.bones[bone];r=b.matrix_local.to_quaternion()
 world=Quaternion((1,0,0),math.radians(forward)) @ Quaternion((0,1,0),math.radians(side*outward));q=r.inverted() @ world @ r
 return [round(math.degrees(a),4) for a in q.to_euler('XYZ')]
