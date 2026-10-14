"""Mesh builders for the companions: rounded boxes, lathed solids, swept tubes and flat glyphs, each with
UVs and outward normals, so a species module describes shapes rather than vertex bookkeeping."""
import bpy,bmesh,math
from mathutils import Vector
from common import finish

def mesh_object(name,verts,faces,material,smooth=True,uv_scale=4.0,inside=None):
 """One object from vertices and faces, normals made outward, box-projected UVs (per face corner, so no seams).
 Closed shapes are oriented by Blender. Open ones (a visor decal, a tube) say what is inside them: one point, or a
 point per vertex (a tube's centre line); each face then faces away from it."""
 me=bpy.data.meshes.new(name);me.from_pydata([tuple(v) for v in verts],[],faces);me.update()
 bm=bmesh.new();bm.from_mesh(me)
 if inside is None:bmesh.ops.recalc_face_normals(bm,faces=bm.faces)
 else:
  per=isinstance(inside,(list,tuple)) and len(inside)==len(verts) and not isinstance(inside[0],(int,float))
  flip=[]
  for f in bm.faces:
   c=f.calc_center_median();ins=Vector(sum((Vector(inside[v.index]) for v in f.verts),Vector()))/len(f.verts) if per else Vector(inside)
   if f.normal.dot(c-ins)<0:flip.append(f)
  bmesh.ops.reverse_faces(bm,faces=flip)
 bm.to_mesh(me);bm.free();me.update()
 # One UV per vertex (a spherical projection about the object's centre): face-corner UVs would make the app's
 # renderer split every vertex, and the face morphs rebuild the whole mesh per change, so splits cost frame time.
 uv=me.uv_layers.new(name='UVMap');n=max(1,len(me.vertices))
 cx=sum(v.co.x for v in me.vertices)/n;cy=sum(v.co.y for v in me.vertices)/n;cz=sum(v.co.z for v in me.vertices)/n
 for li,loop in enumerate(me.loops):
  co=me.vertices[loop.vertex_index].co;d=co-Vector((cx,cy,cz))
  uv.data[li].uv=((math.atan2(d.y,d.x)/(2*math.pi)+.5)*uv_scale,(d.z+.5)*uv_scale*.5)
 o=bpy.data.objects.new(name,me);bpy.context.collection.objects.link(o)
 finish(o,name,material)
 if not smooth:
  for p in o.data.polygons:p.use_smooth=False
 return o

def rounded_box(name,center,half,exponent,material,n=16):
 """A superellipsoid |x/a|^e+|y/b|^e+|z/c|^e=1 from an equal-angle cube sphere: crisp, evenly spaced, no poles."""
 verts=[];index={};faces=[]
 def vid(p):
  key=tuple(round(c,6) for c in p)
  if key not in index:index[key]=len(verts);verts.append(p)
  return index[key]
 for k in range(3):
  others=[c for c in range(3) if c!=k]
  for sgn in (-1,1):
   grid=[[0]*(n+1) for _ in range(n+1)]
   for i in range(n+1):
    for j in range(n+1):
     p=[0,0,0];p[k]=sgn;p[others[0]]=-1+2*i/n;p[others[1]]=-1+2*j/n;grid[i][j]=vid(tuple(p))
   for i in range(n):
    for j in range(n):faces.append((grid[i][j],grid[i+1][j],grid[i+1][j+1],grid[i][j+1]))
 out=[]
 for p in verts:
  d=Vector([math.tan(c*math.pi/4) for c in p]).normalized()
  s=(abs(d.x)**exponent+abs(d.y)**exponent+abs(d.z)**exponent)**(1/exponent)
  out.append(Vector((center[0]+half[0]*d.x/s,center[1]+half[1]*d.y/s,center[2]+half[2]*d.z/s)))
 return mesh_object(name,out,faces,material)

def frame(axis):
 """Two unit vectors perpendicular to `axis` (and to each other)."""
 axis=Vector(axis).normalized();helper=Vector((0,0,1)) if abs(axis.z)<.9 else Vector((1,0,0))
 u=axis.cross(helper).normalized();v=axis.cross(u).normalized();return u,v

def lathe(name,a,b,profile,material,seg=24,squash=(1,1)):
 """A solid of revolution from a to b. `profile` is [(t, radius)] from 0 to 1; radius 0 at an end closes it."""
 a,b=Vector(a),Vector(b);axis=b-a;u,v=frame(axis);verts=[];faces=[];rows=[]
 for t,r in profile:
  c=a+axis*t
  if r<=1e-6:rows.append([len(verts)]);verts.append(c);continue
  row=[]
  for k in range(seg):
   ang=2*math.pi*k/seg;row.append(len(verts));verts.append(c+u*(r*squash[0]*math.cos(ang))+v*(r*squash[1]*math.sin(ang)))
  rows.append(row)
 for r0,r1 in zip(rows,rows[1:]):
  if len(r0)==1 and len(r1)>1:faces+=[(r0[0],r1[(k+1)%seg],r1[k]) for k in range(seg)]
  elif len(r1)==1 and len(r0)>1:faces+=[(r0[k],r0[(k+1)%seg],r1[0]) for k in range(seg)]
  elif len(r0)>1 and len(r1)>1:faces+=[(r0[k],r0[(k+1)%seg],r1[(k+1)%seg],r1[k]) for k in range(seg)]
 if len(rows[0])>1:faces.append(tuple(reversed(rows[0])))
 if len(rows[-1])>1:faces.append(tuple(rows[-1]))
 return mesh_object(name,verts,faces,material)

def capsule(name,a,b,radius,material,seg=20,caps=6,squash=(1,1)):
 """A rounded rod from a to b (the caps are inside the length)."""
 L=(Vector(b)-Vector(a)).length;cap=min(radius,L/2)/L;prof=[]
 for i in range(caps+1):
  ang=math.pi/2*i/caps;prof.append((cap*(1-math.cos(ang)),radius*math.sin(ang)))
 for i in range(caps,-1,-1):
  ang=math.pi/2*i/caps;prof.append((1-cap*(1-math.cos(ang)),radius*math.sin(ang)))
 return lathe(name,a,b,prof,material,seg,squash)

def strip_faces(rows,cols,closed=False):
 faces=[]
 for j in range(rows-1):
  for i in range(cols if closed else cols-1):
   a=j*cols+i;b=j*cols+(i+1)%cols;faces.append((a,b,b+cols,a+cols))
 return faces
