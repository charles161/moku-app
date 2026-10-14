import bpy,numpy as np
from pxr import Usd,UsdGeom,UsdSkel
from pathlib import Path
r=Path(__file__).resolve().parents[1]
bpy.ops.wm.open_mainfile(filepath=str(r/'src/moku_character.blend'));m=bpy.data.objects['Plush']
s=Usd.Stage.Open(str(r/'character/moku_bunny.usdz'));p=next(p for p in s.Traverse() if p.IsA(UsdGeom.Mesh));points=np.array(UsdGeom.Mesh(p).GetPointsAttr().Get());basis=np.array([list(v.co) for v in m.data.shape_keys.key_blocks['Basis'].data]);print('COUNT',points.shape,basis.shape,'BASIS_MAX',np.max(np.abs(points-basis)))
for side in ['L','R']:
 g=m.vertex_groups['part_ear_'+side].index;ids=[v.index for v in m.data.vertices if any(x.group==g for x in v.groups)];print(side,'BASIS',basis[ids].min(axis=0),basis[ids].max(axis=0),'USD',points[ids].min(axis=0),points[ids].max(axis=0),'DELTA',np.max(np.abs(points[ids]-basis[ids])))
for p in s.Traverse():
 if p.IsA(UsdSkel.Skeleton):
  sk=UsdSkel.Skeleton(p);print('JOINTS',sk.GetJointsAttr().Get());print('REST',sk.GetRestTransformsAttr().Get())
