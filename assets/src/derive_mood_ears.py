"""v0's moods on the v6 rig, plus arm poses for the annoyed and disappointed holds."""
from pathlib import Path
import sys,math,json
sys.path.insert(0,str(Path(__file__).resolve().parent))
from common import *
from mathutils import Vector,Quaternion
from companion import companion_id,paths,species
if companion_id()!='moku':
 # Another companion: its species gives the faces, antenna tilts and arm targets; write its moods.json directly.
 P=paths();bpy.ops.wm.open_mainfile(filepath=str(P.blend))
 import moods
 (P.dir/'moods.json').write_text(json.dumps(moods.data(species().mood_table(bpy.data.objects['Rig'])),indent=2)+'\n')
 print('Wrote',P.dir/'moods.json');sys.exit(0)
bpy.ops.wm.open_mainfile(filepath=str(ROOT/'src/moku_character.blend'))
rig=bpy.data.objects['Rig']
MOODS={
 'content':({'smile': 0.2},{},'Soft upright sit'),
 'happy':({'eyes_happy': 0.85, 'smile': 1, 'brows_up': 0.3, 'cheeks_puff': 0.25},{'head': [-5, 0, -4], 'ear_L_01': [9.4094, 2.6287, -14.922], 'ear_R_01': [15.1042, -6.4226, -8.3327]},'Lifted chest, buoyant ears'),
 'proud':({'eyes_happy': 0.35, 'smile': 0.7},{'head': [-9, 0, 3], 'chest': [-3, 0, 0], 'ear_L_01': [2.6772, 0.4822, -4.1844], 'ear_R_01': [4.0923, -1.9998, -2.1362]},'Chin lifted gently'),
 'curious':({'eyes_wide': 0.75, 'brows_up': 0.7, 'pout': 0.2},{'head': [1, 0, 12], 'ear_L_01': [13.7915, 4.8267, -22.1923]},'Head tilt with one listening ear'),
 'concerned':({'brows_concern': 1, 'frown': 0.55, 'eyes_wide': 0.12},{'head': [7, 0, -5], 'ear_L_01': [-4.3359, -0.3607, 6.7287], 'ear_R_01': [-6.3951, 3.498, 3.1109]},'Small forward lean'),
 'disappointed':({'brows_concern': 0.6, 'blink_L': 0.35, 'blink_R': 0.35, 'frown': 0.85, 'pout': 0.2, 'arms_fold': 0, 'paws_lap': 1},{'head': [12, 0, 0], 'chest': [4, 0, 0], 'ear_L_01': [-7.5992, -0.2958, 11.7826], 'ear_L_02': [0.1973, -0.5233, 4.9677], 'ear_R_01': [-11.0836, 6.3347, 5.1871], 'ear_R_02': [-1.6997, 0.2533, -4.6993]},'Lowered ears, never accusatory'),
 'annoyed':({'brows_angry': 1, 'blink_L': 0.25, 'blink_R': 0.25, 'frown': 0.55, 'pout': 0.55, 'arms_fold': 1},{'head': [0, 0, -7], 'ear_L_01': [-1.6207, -0.1949, 2.5199], 'ear_R_01': [-2.4192, 1.2708, 1.2116]},'Still, restrained eyebrow acting'),
 'sleepy':({'blink_L': 0.94, 'blink_R': 0.94, 'brows_concern': 0.12, 'pout': 0.15},{'head': [13, 0, 7], 'chest': [5, 0, 0], 'ear_L_01': [-9.2256, -0.1555, 14.3062], 'ear_L_02': [0.2936, -0.8448, 7.9478], 'ear_R_01': [-13.3988, 7.8139, 6.1403], 'ear_R_02': [-2.7276, 0.3381, -7.5218]},'Heavy lids and drooping ears'),
}
# v0's expressions, exactly: face weights, head tilt and ear joints. Only the
# crossed and lap-folded paws below are newer body language layered on top.
# Crossed paws: distinct vertical layering avoids palm interpenetration.
for side,sign in [('L',1),('R',-1)]:
 name='arm_'+side;bone=rig.data.bones[name];r=bone.matrix_local.to_quaternion()
 target=Vector((-sign*.23,-.17 if side=='L' else -.145,-.018 if side=='L' else -.065))
 world=(bone.tail_local-bone.head_local).rotation_difference(target)
 q=r.inverted() @ world @ r
 MOODS['annoyed'][1][name]=[round(math.degrees(a),4) for a in q.to_euler('XYZ')]
# Lap fold is lower, inward and softer than the annoyed chest cross.
for side,sign in [('L',1),('R',-1)]:
 name='arm_'+side;bone=rig.data.bones[name];r=bone.matrix_local.to_quaternion()
 target=Vector((-sign*.19,-.15 if side=='L' else -.13,-.17 if side=='L' else -.20))
 world=(bone.tail_local-bone.head_local).rotation_difference(target);q=r.inverted() @ world @ r
 MOODS['disappointed'][1][name]=[round(math.degrees(a),4) for a in q.to_euler('XYZ')]
source='''import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
# Joint-local XYZ degrees derived from rest matrices restored exactly from v0.
MOODS = '''+repr(MOODS)+'''
def data(MOODS=MOODS):
 moods={k:{'blendShapes':w,'jointEulerDegrees':j,'posture':p,'faceDecal':k,**({'transitionIn':'fold_arms','transitionOut':'unfold_arms','idleAnimation':'disappointed_hold'} if k=='disappointed' else {'transitionIn':'cross_arms','transitionOut':'uncross_arms','idleAnimation':'annoyed_hold'} if k=='annoyed' else {})} for k,(w,j,p) in MOODS.items()}
 earMap={'LOP':'content','LIFT':'happy','ANTENNA_L':'curious','FORWARD':'concerned','CURTAIN':'disappointed','PINNED':'annoyed','MELT':'sleepy'}
 ears={label:{'blendShapes':{k:v for k,v in MOODS[mood][0].items() if k.startswith('ear')},'jointEulerDegrees':{k:v for k,v in MOODS[mood][1].items() if k.startswith('ear_')}} for label,mood in earMap.items()}
 ears['ANTENNA_R']={'blendShapes':{'ear_antenna_R':1},'jointEulerDegrees':{'ear_L_01':[0,0,0],'ear_R_01':[0,0,0]}}
 bodies={'lean_in':{'jointEulerDegrees':{'chest':[6,0,0],'head':[3,0,0]}},'slump':{'jointEulerDegrees':{'chest':[9,0,0],'head':[19,-12,0]}},'chest_out':{'jointEulerDegrees':{'chest':[-5,0,0],'head':[-15,0,0]}},'three_quarter':{'jointEulerDegrees':{'chest':[0,9,0],'head':[-9,24,4]}}}
 for label,mood in [('paws_lap','disappointed'),('arms_crossed','annoyed')]:bodies[label]={'blendShapes':{k:MOODS[mood][0].get(k,0) for k in ['arms_fold','paws_lap']},'jointEulerDegrees':{k:v for k,v in MOODS[mood][1].items() if k.startswith(('arm_','hand_'))}}
 return {'schemaVersion':2,'angleUnit':'degrees','rotationSpace':'jointLocalXYZ','rigRevision':5,'earTransitionManifest':'ear_transitions.json','poseLibraryRule':'Reset unspecified weights/joint offsets to zero before applying a complete library pose. Layer only explicitly chosen body/ear/face groups.','earPoses':ears,'bodyPoses':bodies,'moods':moods}
if __name__=='__main__':(ROOT/'character/moods.json').write_text(json.dumps(data(),indent=2)+'\\n')
'''
(ROOT/'src/moods.py').write_text(source)
print('Wrote v0 moods')
