from pxr import Usd, UsdSkel
s = Usd.Stage.Open('assets/character/moku_bunny.usdz')
for p in s.Traverse():
    if p.IsA(UsdSkel.BlendShape):
        v=UsdSkel.BlendShape(p).GetOffsetsAttr().Get()
        print(p.GetName(),len(v),max((x.GetLength() for x in v),default=0))
