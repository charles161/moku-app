"""Preserve the complete clip range when USD sparsifies a leading/trailing rest."""
from pathlib import Path
from pxr import Usd,UsdSkel,UsdUtils,Sdf
import tempfile,zipfile,os,sys

def pin_animation_bounds(path):
 path=Path(path).resolve()
 with tempfile.TemporaryDirectory(prefix='moku-animation-') as tmp:
  folder=Path(tmp).resolve()
  with zipfile.ZipFile(path) as archive:
   root=folder/archive.namelist()[0]
   for entry in archive.infolist():
    target=(folder/entry.filename).resolve()
    if not target.is_relative_to(folder):raise ValueError('Unsafe USD package member')
   archive.extractall(folder)
  stage=Usd.Stage.Open(str(root));bounds=[stage.GetStartTimeCode(),stage.GetEndTimeCode()];changed=0
  for prim in stage.Traverse():
   if not prim.IsA(UsdSkel.Animation):continue
   a=UsdSkel.Animation(prim)
   for attr in [a.GetRotationsAttr(),a.GetTranslationsAttr(),a.GetScalesAttr(),a.GetBlendShapeWeightsAttr()]:
    if not attr or not attr.HasValue():continue
    times=attr.GetTimeSamples()
    for t in bounds:
     if t not in times:
      value=attr.Get(Usd.TimeCode(t))
      if value is not None:attr.Set(value,Usd.TimeCode(t));changed+=1
  if changed:
   stage.GetRootLayer().Save()
   packed=folder/'bounded.usdz'
   if not UsdUtils.CreateNewUsdzPackage(Sdf.AssetPath(str(root)),str(packed)):raise RuntimeError('USDZ repack failed')
   os.replace(packed,path)
 return changed

if __name__=='__main__':
 args=sys.argv[sys.argv.index('--')+1:]
 for p in args:print('PINNED',p,pin_animation_bounds(p))
