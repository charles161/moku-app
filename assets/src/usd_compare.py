"""Semantic comparison of two USD files: prims, attributes and time samples (max difference), relationships, and
for meshes whose face lists differ, whether the faces are the same set in another order. Blender's voxel remesh and
decimate number the body's faces differently from run to run, so a rebuild is checked this way, not byte for byte.

  Blender --background --factory-startup --python assets/src/usd_compare.py -- A.usdc B.usdc"""
import sys
import numpy as np
from pxr import Usd, Sdf
a_path,b_path=sys.argv[sys.argv.index('--')+1:][:2]
A=Usd.Stage.Open(a_path);B=Usd.Stage.Open(b_path)
def prims(s):return {str(p.GetPath()):p for p in s.Traverse()}
pa,pb=prims(A),prims(B)
diffs=[]
if set(pa)!=set(pb):diffs.append(('PRIMS',sorted(set(pa)^set(pb))[:20]))
for path in sorted(set(pa)&set(pb)):
    x,y=pa[path],pb[path]
    if x.GetTypeName()!=y.GetTypeName():diffs.append((path,'type'))
    na={a.GetName() for a in x.GetAttributes()};nb={a.GetName() for a in y.GetAttributes()}
    if na!=nb:diffs.append((path,'attrs',sorted(na^nb)))
    for name in sorted(na&nb):
        ax,ay=x.GetAttribute(name),y.GetAttribute(name)
        tx,ty=ax.GetTimeSamples(),ay.GetTimeSamples()
        if list(tx)!=list(ty):diffs.append((path,name,'times'));continue
        for t in (tx or [Usd.TimeCode.Default()]):
            vx,vy=ax.Get(t),ay.Get(t)
            if vx is None and vy is None:continue
            try:
                ex,ey=np.array(vx,dtype=float),np.array(vy,dtype=float)
                if ex.shape!=ey.shape:diffs.append((path,name,'shape',ex.shape,ey.shape));break
                d=float(np.max(np.abs(ex-ey))) if ex.size else 0.0
                if d>0:diffs.append((path,name,'maxdiff',d));break
            except Exception:
                if vx!=vy and not (isinstance(vx,Sdf.AssetPath) and vx.path==vy.path):diffs.append((path,name,'value',str(vx)[-60:],str(vy)[-60:]));break
    if x.GetTypeName()=='Mesh' and any(d[0]==path and d[1] in ('faceVertexCounts','faceVertexIndices') for d in diffs):
        def faces(prim):
            c=prim.GetAttribute('faceVertexCounts').Get();i=list(prim.GetAttribute('faceVertexIndices').Get());out=[];k=0
            for n in c:out.append(tuple(sorted(i[k:k+n])));k+=n
            return sorted(out)
        same=faces(x)==faces(y)
        diffs.append((path,'FACE_MULTISET_EQUAL' if same else 'FACE_MULTISET_DIFFERS'))
    for r in x.GetRelationships():
        r2=y.GetRelationship(r.GetName())
        if not r2 or r.GetTargets()!=r2.GetTargets():diffs.append((path,r.GetName(),'rel'))
print('USDCMP',len(diffs),'differences')
for d in diffs[:60]:print('  ',d)
