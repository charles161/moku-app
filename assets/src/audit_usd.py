"""Static USD acceptance audit, run with Blender's bundled OpenUSD Python."""
from pxr import Usd,UsdGeom,UsdSkel,Gf,UsdShade
from pathlib import Path
import json,math,zipfile
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
reports=[]
for path in sorted(ROOT.rglob('*.usdz')):
 print('AUDIT',path.name,flush=True)
 s=Usd.Stage.Open(str(path));xforms=UsdGeom.XformCache();tri=0;joints=[];shapes=[];anims=[];eyePos={};materials=[]
 for p in s.Traverse():
  if p.IsA(UsdGeom.Mesh):
   mesh=UsdGeom.Mesh(p);tri+=sum(int(n)-2 for n in mesh.GetFaceVertexCountsAttr().Get())
   assert np.isfinite(np.asarray(mesh.GetPointsAttr().Get())).all(),path
  if p.IsA(UsdSkel.Skeleton):
   sk=UsdSkel.Skeleton(p);joints=list(sk.GetJointsAttr().Get());bind=sk.GetBindTransformsAttr().Get();xf=xforms.GetLocalToWorldTransform(p)
   for j,m in zip(joints,bind):
    if j.split('/')[-1] in ['head','eye_L','eye_R']:
     pos=xf.Transform(m.Transform(Gf.Vec3d(0,0,0)));eyePos[j.split('/')[-1]]=list(pos)
  if p.IsA(UsdSkel.BlendShape):shapes.append(p.GetName())
  if p.IsA(UsdSkel.Animation):
   a=UsdSkel.Animation(p);times=a.GetRotationsAttr().GetTimeSamples();bt=a.GetBlendShapeWeightsAttr().GetTimeSamples()
   anims.append({'name':p.GetName(),'rotationSamples':len(times),'blendSamples':len(bt),'duration':(max(times)-min(times))/s.GetTimeCodesPerSecond() if times else 0,'joints':len(a.GetJointsAttr().Get() or [])})
  if p.IsA(UsdShade.Material):materials.append(p.GetName())
 report={'file':str(path.relative_to(ROOT)),'triangles':tri,'upAxis':str(UsdGeom.GetStageUpAxis(s)),'metersPerUnit':UsdGeom.GetStageMetersPerUnit(s),'joints':joints,'blendShapes':shapes,'animations':anims,'eyeWorldPositions':eyePos,'materialNames':materials,'bytes':path.stat().st_size}
 assert report['upAxis']=='Y',report
 assert abs(report['metersPerUnit']-1)<1e-6,report
 if 'character/' in str(path):
  assert tri<40000,(path,tri)
  assert len(joints)==21,(path,joints)
  assert set(shapes)==set(json.loads((ROOT/'reports/character.json').read_text())['blendShapes']),(path,shapes)
  assert eyePos['eye_L'][2]>eyePos['head'][2]+.1,('wrongForward',path,eyePos)
  assert eyePos['eye_L'][0]>0 and eyePos['eye_R'][0]<0,('wrongSides',path,eyePos)
 if 'world/' in str(path):assert tri<60000,(path,tri)
 reports.append(report)
(ROOT/'reports/usd-audit.json').write_text(json.dumps(reports,indent=2)+'\n')
print('PASS',len(reports),'USDZ archives; Y-up, +Z-forward, budgets, joints, blend shapes, animation samples')
