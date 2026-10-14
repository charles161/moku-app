"""Scene-only craft mallet and shared prop placement for the two home-life loops."""
import math,json
from common import *
from mathutils import Matrix

def hammer():
 import world
 world.materials()
 handle=cylinder('Mallet handle',(0,0,.035),.013,.17,world.bark,12)
 head=sphere('Felt faced mallet',(0,0,.126),(.060,.038,.040),world.bark,16,10)
 ends=[sphere('Soft mallet face '+str(sign),(sign*.056,0,.126),(.008,.036,.037),world.cream,12,8) for sign in [-1,1]]
 return [handle,head,*ends]

def attach_for_preview(name,rig):
 import world
 from companion import paths
 P=paths()  # the companion being animated: its attachments file, the shared props folder
 world.materials()
 props=hammer() if name=='build_hammer' else world.cup()
 if name=='build_hammer':
  if P.id=='moku':export(ROOT/'props/hammer.usdz',props)
  # In the hand: the hand joint itself, unless the species says where its grip is (Tetsu's hand bone starts at the
  # elbow, so its mitten's grip is further along).
  from companion import species
  grip=species().hand_grip(rig) if hasattr(species(),'hand_grip') else (rig.matrix_world @ rig.pose.bones['hand_R'].matrix).translation
  desired=Matrix.Translation(grip) @ Matrix.Rotation(math.radians(65),4,'X')
  file=P.props+'/hammer.usdz'
 else:
  # In front of the chest, unless the species holds it somewhere of its own (Tetsu: between its mittens).
  from companion import species
  at=species().held_anchor(rig,.126) if hasattr(species(),'held_anchor') else (0,-.31,.29)
  desired=Matrix.Translation(at);file=P.props+'/water_cup.usdz'
 conversion=Matrix.Rotation(-math.pi/2,4,'X')
 attachment=(rig.matrix_world @ rig.pose.bones['hand_R'].matrix).inverted() @ desired @ conversion.inverted()
 record={'file':file,'joint':'hand_R','wrapperLocalMatrixColumnMajor':[attachment[r][c] for c in range(4) for r in range(4)],'visibleNormalizedTime':[0,1],'instructions':'Attach wrapper to composed hand_R world pose. Keep imported prop root conversion. Home scene only; hide on desktop.'}
 path=P.dir/'prop_attachments.json';data=json.loads(path.read_text());data[name]=record;path.write_text(json.dumps(data,indent=2)+'\n')
 for obj in props:obj.matrix_world=desired @ obj.matrix_world
 return props
