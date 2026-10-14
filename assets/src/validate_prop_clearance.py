"""Check the raised mallet against the evaluated face and ears; grasp overlap is intentional."""
import sys,json,math
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from common import *
from mathutils import Matrix
from mathutils.bvhtree import BVHTree
import motion_v2 as motion
from life_props import hammer
bpy.ops.wm.open_mainfile(filepath=str(ROOT/'src/moku_character.blend'))
rig=bpy.data.objects['Rig'];mesh=bpy.data.objects['Plush'];motion.bind(rig,mesh);props=hammer()
a=json.loads((ROOT/'character/prop_attachments.json').read_text())['build_hammer'];v=a['wrapperLocalMatrixColumnMajor'];wrapper=Matrix([[v[c*4+r] for c in range(4)] for r in range(4)])
conversion=Matrix.Rotation(-math.pi/2,4,'X');rest=[o.matrix_world.copy() for o in props]
parts={g.index for g in mesh.vertex_groups if g.name.startswith(('part_head','part_ear_','part_eye_','part_pupil_','part_glint','part_nose','part_mouth','part_brow'))}
indices={v.index for v in mesh.data.vertices if any(g.group in parts for g in v.groups)}
faces=[tuple(p.vertices) for p in mesh.data.polygons if all(i in indices for i in p.vertices)]
checks=[]
for frame in range(59):
 motion.pose('build_hammer',frame/24,58/24)
 evaluated=mesh.evaluated_get(bpy.context.evaluated_depsgraph_get());verts=[mesh.matrix_world @ v.co for v in evaluated.data.vertices]
 face=BVHTree.FromPolygons(verts,faces)
 for obj,base in zip(props,rest):
  xf=rig.matrix_world @ rig.pose.bones['hand_R'].matrix @ wrapper @ conversion @ base
  prop=BVHTree.FromPolygons([xf @ v.co for v in obj.data.vertices],[tuple(p.vertices) for p in obj.data.polygons])
  overlaps=face.overlap(prop);assert not overlaps,('mallet/face overlap',frame,obj.name,len(overlaps))
 checks.append(frame)
(ROOT/'reports/prop-clearance.json').write_text(json.dumps({'passed':True,'clip':'build_hammer','samples':len(checks),'checkedParts':'head, eyes, face details and ears against mallet surface','surfaceIntersections':0,'excluded':'Paws intentionally grasp the handle; body/ground checks use the profile/animation review.'},indent=2)+'\n')
print('PASS',len(checks),'evaluated mallet poses; zero face/ear surface intersections')
