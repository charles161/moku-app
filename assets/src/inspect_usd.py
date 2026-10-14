from pxr import Usd,UsdGeom,UsdSkel,UsdShade
from pathlib import Path
p=Path(__file__).resolve().parents[1]/'character/moku_bunny.usdz';s=Usd.Stage.Open(str(p))
print('UP',UsdGeom.GetStageUpAxis(s));cache=UsdGeom.XformCache()
for prim in s.Traverse():
 if prim.IsA(UsdGeom.Xform) or prim.IsA(UsdSkel.Skeleton):print(prim.GetPath(),cache.GetLocalToWorldTransform(prim))
 if prim.IsA(UsdShade.Shader):
  sh=UsdShade.Shader(prim)
  if sh.GetIdAttr().Get()=='UsdUVTexture':print('TEX',prim.GetPath(),[(i.GetBaseName(),str(i.Get())) for i in sh.GetInputs()])
