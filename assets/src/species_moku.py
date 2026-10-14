"""Moku the bunny, v6: v0's quiet face (hairline w and brows) on the v5 rig and ears. The species module for
companion.py; its geometry, materials and morphs are exactly those character.py built before the split.
No particles, no runtime subdivision or shader dependency.
"""
import math,json,array,random
from common import *
from mathutils import Vector
import numpy as np
from companion import ear_step_name,EAR_TARGETS,EAR_STEPS
import face_shapes
ID='moku';SEED=47;VERSION=6
REST_WEIGHTS={'smile':.2}
SCOPES=[('face_decals',('brow_','mouth_','tongue')),('eye_hidden_L',('eye_L','pupil_L','glint_L','glintsmall_L')),('eye_hidden_R',('eye_R','pupil_R','glint_R','glintsmall_R'))]
cream=pink=belly=cocoa=pupil=black=rose=white=interior=tongue=headmat=None
ear_data={}

def materials(P):
 global cream,pink,belly,cocoa,pupil,black,rose,white,interior,tongue,headmat,lum,lum8
 cream=mat('Ivory woven plush',(.86,.75,.58),.93)
 pink=mat('Petal pink velour',(.64,.31,.29),.94)
 belly=mat('Warm milk plush',(.91,.82,.68),.93)
 cocoa=mat('Cocoa glass eyes',(.042,.016,.006),.23)
 pupil=mat('Deep cocoa pupil',(.014,.006,.003),.19)
 black=mat('Espresso embroidery',(.105,.042,.023),.95)
 rose=mat('Rose nose',(.43,.16,.14),.77)
 white=mat('Softbox catchlights',(1,.94,.8),.25)
 interior=mat('Petal mouth interior',(.578,.202,.202),.92)
 tongue=mat('Soft pink tongue',(.791,.367,.352),.93)
 # Bake the generated felt swatch into ordinary albedo/normal textures.
 source=bpy.data.images.load(str(ROOT/'src/felt_source.png'));source.scale(1024,1024)
 src=np.array(source.pixels[:],dtype=np.float32).reshape((1024,1024,4))
 # Repeat four times, using a mirrored tile to avoid a hard seam in the source swatch.
 coords=np.arange(1024)*4;coords=np.where((coords//1024)%2,1023-(coords%1024),coords%1024)
 felt=src[coords[:,None],coords[None,:],:3];lum=felt.mean(axis=2)
 img=normal_image('plush_normal',lum,P.dir/'plush_normal.png')
 for m in [cream,belly,pink]:
  nd=m.node_tree.nodes;p=nd.get('Principled BSDF');p.inputs['Sheen Weight'].default_value=.6;p.inputs['Sheen Roughness'].default_value=.8;p.inputs['Sheen Tint'].default_value=(.97,.82,.60,1);p.inputs['Specular IOR Level'].default_value=.16
  tex=nd.new('ShaderNodeTexImage');tex.image=img;tex.extension='REPEAT';uv=nd.new('ShaderNodeTexCoord');mapping=nd.new('ShaderNodeVectorMath');mapping.operation='SCALE';mapping.inputs[3].default_value=1
  m.node_tree.links.new(uv.outputs['UV'],mapping.inputs[0]);m.node_tree.links.new(mapping.outputs[0],tex.inputs['Vector'])
  normal=nd.new('ShaderNodeNormalMap');normal.inputs['Strength'].default_value=.48
  m.node_tree.links.new(tex.outputs['Color'],normal.inputs['Color']);m.node_tree.links.new(normal.outputs['Normal'],p.inputs['Normal'])
 # Portable subtle albedo variation with diffuse painted blush for the head.
 n=1024;albedo=bpy.data.images.new('ivory_felt_albedo',width=n,height=n,alpha=False);pix=array.array('f')
 for y in range(n):
  v=(y+.5)/n;theta=(1-v)*math.pi;z=.59+.275*math.cos(theta)
  for x in range(n):
   u=(x+.5)/n;phi=u*math.pi*2;xx=.31*math.sin(theta)*math.cos(phi);yy=.23*math.sin(theta)*math.sin(phi)
   noise=float(lum[y,x]-.79)*.42+random.uniform(-.009,.009)
   c=[.935+noise,FELT_G+noise,.745+noise]
   blush=math.exp(-((abs(xx)-.19)/.07)**2-((z-.493)/.048)**2)*max(0,-yy/.20)*.68
   for k,b in enumerate([.91,.49,.44]):c[k]=c[k]*(1-blush)+b*blush
   # A faint lower lid: a soft warm crease just under each eye's lower curve (moku-look-v2.md step 3).
   if yy<0 and z<.560:
    d=math.sqrt(((abs(xx)-.134)/.073)**2+((z-.578)/.074)**2);lid=math.exp(-((d-1.07)/.035)**2)*min(1,(.560-z)/.03)*.12
    for k,b in enumerate([.55,.36,.30]):c[k]=c[k]*(1-lid)+b*lid
   pix.extend((*c,1))
 albedo.pixels.foreach_set(pix);albedo.filepath_raw=str(P.dir/'ivory_felt_albedo.png');albedo.file_format='PNG';albedo.save()
 headmat=cream.copy();headmat.name='Ivory face diffuse blush';tex=headmat.node_tree.nodes.new('ShaderNodeTexImage');tex.image=albedo;headmat.node_tree.links.new(tex.outputs['Color'],headmat.node_tree.nodes.get('Principled BSDF').inputs['Base Color'])
 # Body textile color uses a tileable fine-grained swatch, retaining scalar tint.
 n=512;bodytex=bpy.data.images.new('felt_color',width=n,height=n,alpha=False);pix=array.array('f')
 for y in range(n):
  for x in range(n):
   noise=float(lum[y*2,x*2]-.79)*.42;pix.extend((.935+noise,FELT_G+noise,.745+noise,1))
 bodytex.pixels.foreach_set(pix);bodytex.filepath_raw=str(P.dir/'felt_color.png');bodytex.file_format='PNG';bodytex.save()
 tex=cream.node_tree.nodes.new('ShaderNodeTexImage');tex.image=bodytex;cream.node_tree.links.new(tex.outputs['Color'],cream.node_tree.nodes.get('Principled BSDF').inputs['Base Color'])
 for m,image in ((pupil,iris_texture(P.dir/'eye_iris.png')),(cocoa,ring_texture(P.dir/'eye_ring.png'))):
  tex=m.node_tree.nodes.new('ShaderNodeTexImage');tex.image=image;tex.extension='EXTEND'
  m.node_tree.links.new(tex.outputs['Color'],m.node_tree.nodes.get('Principled BSDF').inputs['Base Color'])
 # The body, arms, feet, ears and pads share one UV layout now (finish_mesh), at about half the head's texel density,
 # so their felt repeats eight times instead of four and keeps the head's curl size (about 4 repeats a metre).
 global lum8
 half=src.reshape(512,2,512,2,4).mean(axis=(1,3))
 c8=np.arange(1024)*4;c8=np.where((c8//512)%2,511-(c8%512),c8%512)
 lum8=half[c8[:,None],c8[None,:],:3].mean(axis=2)
 fine=normal_image('felt_normal',lum8,P.dir/'felt_normal.png')
 for m in [cream,pink]:
  for node in m.node_tree.nodes:
   if node.type=='TEX_IMAGE' and node.image==img:node.image=fine

COCOA=np.array([.227,.133,.070])  # the eyeball's v0 colour (linear .042, .016, .006) in sRGB
def _smooth(a,b,t):t=np.clip((t-a)/(b-a),0,1);return t*t*(3-2*t)
def _disc(n):
 y,x=np.mgrid[0:n,0:n];u=(x+.5)/n*2-1;v=(y+.5)/n*2-1   # Blender row order: v grows upward
 return u,v,np.hypot(u,v)
def iris_texture(path,n=256):
 """The layered iris on the pupil disc (moku-look-v2.md step 3; the disc's width and height span 0..1): a big warm
 black pupil, then a dark chocolate iris with fine radial fibres that warms to amber toward the bottom and meets the
 eyeball's cocoa at the disc's edge, as on the concept sheet."""
 u,v,r=_disc(n);angle=np.arctan2(v,u)
 rng=np.random.default_rng(11);spokes=sum(rng.uniform(.3,1)*np.cos(k*angle+rng.uniform(0,6.3)) for k in (23,37,51,64))/4
 chocolate=np.array([.20,.10,.05]);amber=np.array([.56,.31,.14]);black=np.array([.06,.035,.024])
 warm=_smooth(.15,-.8,v)*np.exp(-((r-.84)/.13)**2)*.8   # the lower half glows, most in the middle of the band
 rgb=chocolate+(amber-chocolate)*warm[...,None]
 rgb*=(1+.18*spokes*_smooth(.62,.7,r))[...,None]
 rgb=rgb+(COCOA-rgb)*_smooth(.9,1,r)[...,None]
 rgb=rgb+(black-rgb)*(1-_smooth(.56,.66,r))[...,None]
 import occlusion as oc
 return oc.save('eye_iris',path,np.clip(rgb,0,1))
def ring_texture(path,n=128):
 """The eyeball round the disc: v0's cocoa, darkening to a rim at its edge (also the edge of a closed eye's arc)."""
 u,v,r=_disc(n)
 rgb=COCOA+(np.array([.10,.055,.032])-COCOA)*_smooth(.84,.98,r)[...,None]
 import occlusion as oc
 return oc.save('eye_ring',path,np.clip(rgb,0,1))

def normal_image(name,height,path):
 """A tangent-space normal map (OpenGL +Y) from a felt height field, written to `path`."""
 dx=(np.roll(height,-1,axis=1)-np.roll(height,1,axis=1))*3.8
 dy=(np.roll(height,-1,axis=0)-np.roll(height,1,axis=0))*3.8
 norm=np.stack((-dx,-dy,np.ones_like(height)),axis=-1);norm/=np.linalg.norm(norm,axis=-1,keepdims=True)
 n=height.shape[0];rgba=np.ones((n,n,4),dtype=np.float32);rgba[:,:,:3]=norm*.5+.5
 img=bpy.data.images.new(name,width=n,height=n,alpha=False);img.pixels.foreach_set(rgba.ravel());img.filepath_raw=str(path);img.file_format='PNG';img.save();img.colorspace_settings.name='Non-Color'
 return img

# Exact v0 crown-and-lop rest restored per Charles. Expressions use deltas.
curves={
 'L':[(.22,.025,.735),(.33,.015,.66),(.47,-.006,.35),(.36,-.026,.215)],
 'R':[(.11,.15,.79),(.11,.07,.95),(-.015,.03,.99),(-.21,.04,.78),(-.30,0,.51),(-.35,-.01,.25)]}
def bez(points,t):
 p=list(map(Vector,points))
 if len(p)>4:
  u=t*(len(p)-1);i=min(len(p)-2,int(u));v=u-i;p0=p[max(0,i-1)];p1=p[i];p2=p[i+1];p3=p[min(len(p)-1,i+2)]
  return .5*((2*p1)+(-p0+p2)*v+(2*p0-5*p1+4*p2-p3)*v*v+(-p0+3*p1-3*p2+p3)*v*v*v)
 return p[0]*(1-t)**3+3*p[1]*t*(1-t)**2+3*p[2]*t*t*(1-t)+p[3]*t**3

# The ear's cross-section (moku-look-v2.md): a plush cup, not a flat card. The back is round; the front has a rolled
# rim standing forward and a shallow dish inside, where the inner felt sits a touch proud of the dish floor. The
# outline, centre curve, ring layout (20 points on 31 rings), joints and skin weights are as before, so every ear pose
# and in-between keeps working: build, morph and ear_transitions all place ear points through this one function.
EAR_BACK=.036;EAR_RIM=.042;EAR_DISH=.004
def ear_point(c,side,u,k,inner):
 """Point k (0..19 round the ring) of the ear at u (0 root .. 1 tip of this part) around centre c, `side` across."""
 t=.10+.82*u if inner else u
 a=k*math.pi*2/20;x=math.cos(a);s=math.sin(a);g=math.sin(math.pi*t)**.5
 if inner:
  width=.048*math.sin(math.pi*u)**.40+.0008;depth=.004*math.sin(math.pi*u)**.5+.0005
  return c+side*width*x+Vector((0,-(EAR_DISH*g+.0025)+depth*s,0))
 width=.078*math.sin(math.pi*u)**.40+.0008
 if s>=0:y=(EAR_BACK*g+.0005)*s
 else:
  r=math.sqrt(-s);rim=math.exp(-((abs(x)-.82)/.13)**2)
  y=-(EAR_DISH+(EAR_RIM-EAR_DISH)*rim)*r*g+.0005*s
 return c+side*width*x+Vector((0,y,0))

def build(add):
 # Fused body and haunches remove the balloon joins while keeping short arms articulated.
 bodyparts=[sphere('Torso',(0,.035,.224),(.224,.167,.212),cream,40,28)]
 for s in [-1,1]:
  bodyparts.append(sphere('Haunch',(s*.143,.043,.112),(.119,.134,.107),cream,32,20))
  bodyparts.append(sphere('Shoulder',(s*.17,-.025,.295),(.075,.088,.105),cream,28,20))
 select(bodyparts);bpy.ops.object.join();body=bpy.context.object;body.name='Body'
 remesh=body.modifiers.new('Seamless plush volume','REMESH');remesh.mode='VOXEL';remesh.voxel_size=.012;bpy.ops.object.modifier_apply(modifier=remesh.name)
 sm=body.modifiers.new('Soft toy transitions','SMOOTH');sm.factor=1.1;sm.iterations=5;bpy.ops.object.modifier_apply(modifier=sm.name)
 dec=body.modifiers.new('Realtime retopology','DECIMATE');dec.ratio=.65;bpy.ops.object.modifier_apply(modifier=dec.name)
 select([body]);bpy.ops.object.mode_set(mode='EDIT');bpy.ops.mesh.select_all(action='SELECT');bpy.ops.uv.smart_project(island_margin=.02);bpy.ops.object.mode_set(mode='OBJECT');finish(body,'Body',None);add(body,'body','spine')
 head=add(sphere('Head',(0,0,.59),(.31,.23,.275),headmat,56,40),'head','head')
 # Explicit spherical UV mapping for blush alignment and softly pushed-in muzzle volumes.
 for p in head.data.polygons:
  us=[]
  for li in p.loop_indices:
   ve=head.data.vertices[head.data.loops[li].vertex_index].co;u=(math.atan2(ve.y/.23,ve.x/.31)/(2*math.pi))%1;v=1-math.acos(max(-1,min(1,ve.z/.275)))/math.pi;us.append((li,u,v))
  seam=max(x[1] for x in us)-min(x[1] for x in us)>.5
  for li,u,v in us:head.data.uv_layers.active.data[li].uv=(u+1 if seam and u<.5 else u,v)
 for ve in head.data.vertices:
  z=ve.co.z+.59
  if ve.co.y<0:
   bulge=.012*math.exp(-((abs(ve.co.x)-.047)/.075)**2-((z-.485)/.045)**2);ve.co.y-=bulge
  # Submillimeter irregularity, no added geometry or hair.
  ve.co+=ve.normal*random.uniform(-.0007,.0007)
 # Face shell follows actual head polygons at exactly 0.5 mm, avoiding z-fighting
 # and preserving the head's sculpted muzzle. Transparent by default; opt-in atlas.
 faceMat=mat('Face decals',(1,1,1),1)
 blank=bpy.data.images.load(str(ROOT/'character/face_decal_blank.png'))
 node=faceMat.node_tree.nodes.new('ShaderNodeTexImage');node.image=blank;node.extension='CLIP'
 p=faceMat.node_tree.nodes.get('Principled BSDF');faceMat.node_tree.links.new(node.outputs['Color'],p.inputs['Base Color']);faceMat.node_tree.links.new(node.outputs['Alpha'],p.inputs['Alpha'])
 select([head]);tri=head.modifiers.new('Stable face triangulation','TRIANGULATE');bpy.ops.object.modifier_apply(modifier=tri.name)
 head.data.update();selected=[]
 for poly in head.data.polygons:
  coords=[head.data.vertices[i].co+head.location for i in poly.vertices]
  if all(abs(v.x)<.27 and .40<v.z<.765 and v.y<-.085 for v in coords):selected.append(poly)
 used=sorted({i for poly in selected for i in poly.vertices});lookup={i:j for j,i in enumerate(used)}
 verts=[head.data.vertices[i].co+head.location+head.data.vertices[i].normal*.0005 for i in used]
 faces=[tuple(lookup[i] for i in poly.vertices) for poly in selected]
 me=bpy.data.meshes.new('FaceShell');me.from_pydata(verts,[],faces);me.update();uv=me.uv_layers.new(name='UVMap')
 for poly in me.polygons:
  for li in poly.loop_indices:
   v=me.vertices[me.loops[li].vertex_index].co;uv.data[li].uv=((v.x+.27)/.54,(v.z-.40)/.365)
 obj=bpy.data.objects.new('FaceShell',me);bpy.context.collection.objects.link(obj);add(finish(obj,obj.name,faceMat),'face_shell','head')
 for s,l in [(1,'L'),(-1,'R')]:
  # Tucked short arms blend into the softened shoulder silhouette.
  arm=add(sphere('Arm_'+l,(s*.151,-.100,.275),(.062,.071,.099),cream,28,20),'arm_'+l,'arm_'+l);arm.rotation_euler[1]=s*.29
  # Big visible soles angled toward the viewer.
  foot=add(sphere('Foot_'+l,(s*.15,-.136,.095),(.108,.103,.095),cream,32,20),'foot_'+l,'foot_'+l)
  pad=add(sphere('Pad_'+l,(s*.15,-.235,.090),(.056,.007,.052),pink,24,16),'pad_'+l,'foot_'+l);
  for v in pad.data.vertices:
   xx=v.co.x;zz=v.co.z+pad.location.z-.095
   v.co.y=-.136-.103*math.sqrt(max(.03,1-(xx/.108)**2-(zz/.095)**2))-.002-pad.location.y-abs(v.co.y)*.12
  for i in range(3):
   o=add(sphere('Toe_'+l+str(i),(s*.15+(i-1)*.035,-.212,.152+(0.011 if i==1 else 0)),(.014,.010,.016),pink,16,10),'pad_'+l,'foot_'+l);o.rotation_euler.x=-.3
  # Eyes wider and lower, with brown rim, deep pupil, paired highlights.
  eye=add(sphere('Eye_'+l,(s*.134,-.207,.578),(.073,.023,.074),cocoa,40,28),'eye_'+l,'eye_'+l)
  disc=add(sphere('Pupil_'+l,(s*.134,-.230,.578),(.052,.004,.058),pupil,32,20),'pupil_'+l,'eye_'+l)
  # Flat maps across each one's front: the pupil disc carries the iris (eye_iris.png), the eyeball a cocoa ring with a
  # darker rim (eye_ring.png). The disc sinks back as the lids close, so a closed eye is still the v0 cocoa arc.
  for o,(w,h) in ((eye,(.146,.148)),(disc,(.104,.116))):
   for poly in o.data.polygons:
    for li in poly.loop_indices:
     v=o.data.vertices[o.data.loops[li].vertex_index].co+o.location
     o.data.uv_layers.active.data[li].uv=((v.x-s*.134)/w+.5,(v.z-.578)/h+.5)
  add(sphere('Glint_'+l,(s*.134-.021,-.237,.605),(.017,.005,.021),white,20,12),'glint_'+l,'eye_'+l)
  add(sphere('GlintSmall_'+l,(s*.134+.020,-.238,.556),(.006,.003,.007),white,16,10),'glintsmall_'+l,'eye_'+l)
  # Hidden at neutral. Concern/anger/curiosity morphs bring embroidery to the surface.
  add(tube('Brow_'+l,[(s*.096,-.160,.687),(s*.136,-.166,.697),(s*.175,-.157,.690)],.0045,black,8),'brow_'+l,'head')
 for l,curve in curves.items():
  for inner in [False,True]:
   nr=30;ns=20;verts=[];faces=[];uvs=[]
   for j in range(nr+1):
    u=j/nr;t=.10+.82*u if inner else u;c=bez(curve,t);ta=bez(curve,min(1,t+.002))-bez(curve,max(0,t-.002));side=Vector((ta.z,0,-ta.x)).normalized()
    for k in range(ns):verts.append(ear_point(c,side,u,k,inner))
   for j in range(nr):
    for k in range(ns):a=j*ns+k;b=j*ns+(k+1)%ns;faces.append((a,b,b+ns,a+ns))
   faces.extend([tuple(reversed(range(ns))),tuple(nr*ns+k for k in range(ns))])
   me=bpy.data.meshes.new('LopEar');me.from_pydata(verts,[],faces);me.update();uv=me.uv_layers.new(name='UVMap')
   for p in me.polygons:
    for li in p.loop_indices:
     idx=me.loops[li].vertex_index;uv.data[li].uv=(idx%ns/ns,idx//ns/nr)
   o=bpy.data.objects.new(('InnerEar_' if inner else 'Ear_')+l,me);bpy.context.collection.objects.link(o);add(finish(o,o.name,pink if inner else cream),'ear_'+l,'ear_'+l+'_01');ear_data[o.name]=(nr,ns,inner)
 add(sphere('Tail',(0,.199,.129),(.105,.096,.102),belly,32,22),'tail','tail')
 # Small heart-like rose nose and w embroidery; muzzle is sculpted into the head.
 nose=add(sphere('Nose',(0,-.241,.511),(.021,.011,.014),rose,24,16),'nose','head')
 for ve in nose.data.vertices:ve.co.x*=.72+.28*(ve.co.z/.014+1)/2
 for s,l in [(1,'L'),(-1,'R')]:add(tube('Mouth_'+l,[(0,-.232,.501),(s*.018,-.230,.480),(s*.039,-.221,.492)],.0037,black,10),'mouth_'+l,'head')
 add(sphere('MouthInterior',(0,-.213,.483),(.017,.003,.0015),interior,24,14),'mouth_inside','head')
 add(sphere('Tongue',(0,-.19,.462),(.024,.003,.009),tongue,20,12),'tongue','head')
 # Feathered blush overlays: neutral sits inside head, blush_more emerges at full weight.
 blushmat=mat('Expression blush',(.91,.39,.37),1)
 bi=bpy.data.images.new('expression_blush',width=128,height=128,alpha=True)
 ba=np.ones((128,128,4),dtype=np.float32)
 for iy in range(128):
  for ix in range(128):
   r2=((ix-63.5)/63.5)**2+((iy-63.5)/63.5)**2
   ba[iy,ix]=(.94,.48,.45,max(0,1-r2)**2*.70)
 bi.pixels.foreach_set(ba.ravel());bi.filepath_raw=str(ROOT/'character/expression_blush.png');bi.file_format='PNG';bi.save()
 bt=blushmat.node_tree.nodes.new('ShaderNodeTexImage');bt.image=bi
 bp=blushmat.node_tree.nodes.get('Principled BSDF');blushmat.node_tree.links.new(bt.outputs['Color'],bp.inputs['Base Color']);blushmat.node_tree.links.new(bt.outputs['Alpha'],bp.inputs['Alpha'])
 for side,sign in [('L',1),('R',-1)]:
  verts=[];faces=[];nr=8
  for j in range(nr+1):
   for i in range(nr+1):
    x=sign*.19+(i/nr-.5)*.13;z=.49+(j/nr-.5)*.095
    y=-.23*math.sqrt(max(.02,1-(x/.31)**2-((z-.59)/.275)**2))+.006
    verts.append((x,y,z))
  for j in range(nr):
   for i in range(nr):
    a=j*(nr+1)+i;faces.append((a,a+1,a+nr+2,a+nr+1))
  me=bpy.data.meshes.new('Blush');me.from_pydata(verts,[],faces);me.update();uv=me.uv_layers.new(name='UVMap')
  for poly in me.polygons:
   for li in poly.loop_indices:
    vi=me.loops[li].vertex_index;uv.data[li].uv=(vi%(nr+1)/nr,vi//(nr+1)/nr)
  obj=bpy.data.objects.new('Blush_'+side,me);bpy.context.collection.objects.link(obj);add(finish(obj,obj.name,blushmat),'blush_'+side,'head')

# Felt colours in sRGB, for the textures that now carry them (their runtime tint is white).
# Look v2 (2026-10-04), toward the concept sheet: deeper, warmer pinks, and a cream a touch less green (more peach).
PAD_PINK=(.82,.56,.51);INNER_EAR_PINK=(.80,.46,.43);MILK=(.958,.922,.855);FELT_G=.838
# The fuzzy edge: how far the shell stands off the felt (about 2 px at Moku's live size), the tufts' size and opacity.
FUZZ={'offset':.007,'cell':.009,'alpha':(.1,1),'lumps':.9,'lump_cell':.012}
TRIANGLE_BUDGET=56000  # with the fuzz shell (about 13,000)
# Textures the app reads loose from character/ (materials.json sets every felt's and eye's colour and normal map, and
# the shells' colour and fibres), so the model carries 4×4 stand-ins (slim_model.py). Anything that renders the USDZ
# without runtime/materials.json sees plain felt.
LOOSE_TEXTURES=('felt_fuzz.png','face_fuzz.png','milk_fuzz.png','felt_color.png','felt_normal.png','ivory_felt_albedo.png',
                'plush_normal.png','petal_felt.png','milk_felt.png','eye_iris.png','eye_ring.png')
def finish_mesh(P,mesh,member):
 """Bakes occlusion into the felt (moku-look-v2.md step 2, occlusion.py). The cream, pink and milk parts share their
 UV spheres, so each gets its own layout first; the head keeps its spherical layout (the blush is painted in it).
 Hidden, see-through or moving face parts (decals, blush cards, embroidery, the mouth, the eyes, which close, and the
 nose, which twitches) cast none."""
 import occlusion as oc
 me=mesh.data
 cream=oc.material_faces(mesh,['Ivory woven plush']);head=oc.material_faces(mesh,['Ivory face diffuse blush'])
 pink=oc.material_faces(mesh,['Petal pink velour']);milk=oc.material_faces(mesh,['Warm milk plush'])
 for faces in (cream,pink,milk):oc.relayout(mesh,faces)
 hidden={'Face decals','Expression blush','Espresso embroidery','Petal mouth interior','Soft pink tongue','Softbox catchlights','Deep cocoa pupil','Cocoa glass eyes','Rose nose'}
 felt=set(cream+head+pink+milk);tag={i:t for t,vs in member.items() for i in vs}
 faces={}
 for p in me.polygons:
  if me.materials[p.material_index].name not in hidden:faces.setdefault(tag[p.vertices[0]],[]).append(p.index)
 def part(*names):return [f for t,fs in faces.items() if t.startswith(names) for f in fs]
 def felt_vertices(*names):return sorted({v for f in part(*names) if f in felt for v in me.polygons[f].vertices})
 # Shade is baked at rest, so a part that moves must not darken what it leaves: the arms and ears cast nothing on the
 # body and head (they'd leave grey ghosts when they lift); the arms still take shade where they press on the body,
 # and each ear only shades its own cup.
 ao=np.ones(len(me.vertices))
 steady=part('body','head','foot','pad','tail')
 for receivers,occluders,reach in [(felt_vertices('body','head','foot','pad','tail'),steady,.12),
                                   (felt_vertices('arm_'),steady+part('arm_'),.12),
                                   (felt_vertices('ear_L'),part('ear_L'),.05),(felt_vertices('ear_R'),part('ear_R'),.05)]:
  shade=oc.vertex_occlusion(mesh,receivers,occluders,distance=reach);ao[receivers]=shade[receivers]
 receivers=sorted({v for f in felt for v in me.polygons[f].vertices})
 grain=(lum8[::2,::2]-.79)*.42
 # The body's felt: the grain of its normal map (eight mirrored repeats), now with its occlusion.
 body=np.stack([.935+grain,FELT_G+grain,.745+grain],axis=-1)
 body=oc.shade(body,oc.paint(mesh,cream,ao,512));oc.save('felt_color',P.dir/'felt_color.png',body)
 face=np.array(bpy.data.images['ivory_felt_albedo'].pixels[:],dtype=np.float32).reshape(1024,1024,4)[...,:3]
 face=oc.shade(face,oc.paint(mesh,head,ao,1024,wrap=True));oc.save('ivory_felt_albedo',P.dir/'ivory_felt_albedo.png',face)
 # Pink: the pads as before, the inner ears a deeper pink.
 inner=np.zeros(len(me.vertices))
 for side in 'LR':inner[member['ear_'+side]]=1
 ear=oc.paint(mesh,pink,inner,256)[...,None]
 rgb=np.array(PAD_PINK)*(1-ear)+np.array(INNER_EAR_PINK)*ear+grain[::2,::2,None]*.7
 oc.save('petal_felt',P.dir/'petal_felt.png',oc.shade(rgb,oc.paint(mesh,pink,ao,256)))
 rgb=np.array(MILK)+(lum[::8,::8,None]-.79)*.42
 tail=oc.shade(rgb,oc.paint(mesh,milk,ao,128));oc.save('milk_felt',P.dir/'milk_felt.png',tail)
 for name,image in [('Petal pink velour','petal_felt'),('Warm milk plush','milk_felt')]:
  m=bpy.data.materials[name];tex=m.node_tree.nodes.new('ShaderNodeTexImage');tex.image=bpy.data.images[image]
  m.node_tree.links.new(tex.outputs['Color'],m.node_tree.nodes.get('Principled BSDF').inputs['Base Color'])
 print('OCCLUSION',{k:round(float(np.percentile(ao[receivers],k)),3) for k in (1,5,25,50)})
 # The fuzzy edge (fuzz.py): a shell over the cream felt, the head and the tail, where they can be the outline; none
 # over the pink. The face stays bare (the eyes, brows, nose and mouth face the camera; the blush cards are left out).
 import fuzz
 co=np.array([v.co[:] for v in me.vertices])
 cheek=np.sqrt(((np.abs(co[:,0])-.19)/.075)**2+((co[:,2]-.49)/.055)**2)+(co[:,1]>0)*9  # 1 at the blush cards' edge (build)
 band=fuzz.silhouette_band(mesh,soft=20)
 count=fuzz.grow(mesh,[dict(base='Ivory woven plush',name='Ivory woven fuzz',image='felt_fuzz',path=P.dir/'felt_fuzz.png',rgb=body,weight=band*fuzz.clear_of(mesh,['Petal pink velour'],.006,.02),**FUZZ),
                       dict(base='Ivory face diffuse blush',name='Ivory face fuzz',image='face_fuzz',path=P.dir/'face_fuzz.png',rgb=face.reshape(512,2,512,2,3).mean(axis=(1,3)),wrap=True,weight=band*fuzz.smooth(1,1.5,cheek),**FUZZ),
                       dict(base='Warm milk plush',name='Warm milk fuzz',image='milk_fuzz',path=P.dir/'milk_fuzz.png',rgb=tail.repeat(2,0).repeat(2,1),weight=band,**FUZZ)])
 print('FUZZ_TRIANGLES',count)

def skin(o,tag,joint,vg):
 """Ears bend over two joints along their length; the arm's lower third follows the hand."""
 if tag.startswith('ear_'):
  vg2=o.vertex_groups.new(name=joint.replace('_01','_02'));nr,ns,inner=ear_data[o.name]
  for v in o.data.vertices:
   t=(v.index//ns)/nr;t=.10+.82*t if inner else t;w=max(0,min(1,(t-.34)/.36));vg.add([v.index],1-w,'REPLACE');vg2.add([v.index],w,'REPLACE')
  return True
 if tag.startswith('arm_'):
  hand=o.vertex_groups.new(name=joint.replace('arm_','hand_'))
  for v in o.data.vertices:
   w=max(0,min(1,(.24-v.co.z)/.07));vg.add([v.index],1-w,'REPLACE');hand.add([v.index],w,'REPLACE')
  return True
 return False

def morph(name,tag,part_index,co,s):
 if name=='face_decals' and (tag.startswith(('brow_','mouth_')) or tag=='tongue'):co.y+=.20
 if name=='eye_hidden_'+('L' if s==1 else 'R') and tag.startswith(('eye_','pupil_','glint')):co.y+=.20
 if tag.startswith('ear_') and name in ['ears_curtain','ears_pinned','ears_lift','ear_antenna_L','ear_antenna_R'] and not ((name=='ear_antenna_L' and tag=='ear_R') or (name=='ear_antenna_R' and tag=='ear_L')):
  # Corrective shape deltas preserve the original basis exactly. They collapse
  # the signature crown fold only in the expressive pose, never at rest.
  side=1 if tag=='ear_L' else -1;inner=part_index>=620;vi=part_index%620;j=vi//20;k=vi%20;u=j/30;t=.10+.82*u if inner else u
  curve=[(side*.22,.025,.735),(side*.33,.015,.66),(side*.47,-.006,.35),(side*.36,-.026,.215)]
  if name=='ears_lift':curve=[(side*.22,.025,.735),(side*.25,.015,.92),(side*.36,-.01,1.15),(side*.43,-.055,1.23)]
  if name.startswith('ear_antenna_'):curve=[(side*.22,.025,.735),(side*.20,.015,1.0),(side*.25,-.01,1.28),(side*.34,-.08,1.22)]
  if name=='ears_pinned':curve=[(side*.22,.035,.735),(side*.31,.25,.70),(side*.26,.40,.54),(side*.15,.37,.39)]
  c=bez(curve,t);ta=bez(curve,min(1,t+.002))-bez(curve,max(0,t-.002));sv=Vector((ta.z,0,-ta.x)).normalized()
  co[:]=ear_point(c,sv,u,k,inner)
 if tag=='nose' and name=='nose_twitch':co.z+=.009;co.y-=.007;co.x*=.9
 if tag.startswith('arm_') and name in ['arms_fold','paws_lap']:
  w=max(0,min(1,(.29-co.z)/.115));co.z-=(.115 if name=='paws_lap' else .044)*w
 if tag.startswith(('eye_','pupil_','glint')):
  match=name=='blink_'+('L' if s==1 else 'R')
  # v0 lids: a blink closes to a flat line and a happy eye to a soft arc. The
  # sparkle sinks only a little, so partly lowered lids keep it.
  if match or name=='eyes_happy':
   # A blink still closes to v0's flat line; a happy eye bows into a smiling arc (face_shapes.py).
   if name=='eyes_happy':co.z=face_shapes.happy_eye(co.x,co.y,co.z,s)[2]
   else:co.z=.578+(co.z-.578)*.025
   if tag.startswith('glint'):co.y+=.016
  if name=='eyes_proud':
   co.z=.578+(co.z-.578)*.11;co.z-=.035*max(0,1-min(1,((co.x-s*.134)/.073)**2))
   if tag.startswith('glint'):co.y+=.080
  if name in ['lid_flat','lid_sad','lid_smile_lower']:
   if name=='lid_flat':co.z=min(co.z,.595)+(co.z-.578)*-.12
   elif name=='lid_sad':co.z=min(co.z,.609-(abs(co.x)-.134)*.30)
   else:co.z=face_shapes.smile_lower_lid(co.x,co.y,co.z,s)[2]  # the lower lid rises in a curve (face_shapes.py)
  if name=='eyes_wide':co.z=.578+(co.z-.578)*1.12;co.x=s*.134+(co.x-s*.134)*1.06
  if name=='eyes_narrow':co.z=.578+(co.z-.578)*.35
  if name=='eyes_look_down' and tag.startswith(('pupil_','glint')):co.z-=.018;co.x+=.009
 if tag.startswith('brow_'):
  # v0 brows sit under the felt and surface only a little: restrained acting.
  if name=='brows_up':co.z+=.02;co.y-=.063
  if name=='brow_raise_'+('L' if s==1 else 'R'):co.z+=.03;co.y-=.063
  if name=='brows_concern':co.z+=(.136-abs(co.x))*.45;co.y-=.063
  if name=='brows_angry':co.z+=(abs(co.x)-.136)*.65-.015;co.y-=.066
 if tag.startswith('mouth_') and tag!='mouth_inside':
  # The v0 w never opens into a grin: the biggest smile only lifts its corners.
  if name=='smile':co.z+=abs(co.x)*.22;co.x*=1.10
  if name=='mouth_smile_open':co.z+=abs(co.x)*.30;co.x*=1.16
  if name=='lips_press':co.z=.49+(co.z-.49)*.35;co.x*=.85
  if name=='frown':co.z-=abs(co.x)*.48;co.z+=.004
  if name=='pout':co.x*=.5;co.y-=.006
  if name=='mouth_open':co.z-=.017;co.x*=.7;co.y-=.013
 if tag.startswith('blush_') and name=='blush_more':co.y-=.030;co.z+=.006
 if tag in ['head','face_shell'] and name=='cheeks_raise' and co.y<0:
  w=math.exp(-((abs(co.x)-.18)/.085)**2-((co.z-.49)/.065)**2);co.z+=.019*w;co.y-=.012*w
 if tag=='mouth_inside' and name=='mouth_open':co.z=.471+(co.z-.483)*12;co.y-=.025
 if tag in ['head','face_shell'] and name=='cheeks_puff' and co.y<0:
  w=math.exp(-((abs(co.x)-.18)/.085)**2-((co.z-.49)/.065)**2);co.x+=math.copysign(.006*w,co.x);co.y-=.012*w

# Unfurl the hanging tips after the roots. Each adjacent keypose preserves volume.
# In-between controls replace ears_lift/antenna weights, never add on top of them.
def ear_path(side,target,phase):
 sign=1 if side=='L' else -1
 end=[(sign*.22,.025,.735),(sign*.25,.015,.92),(sign*.36,-.01,1.15),(sign*.43,-.055,1.23)]
 if target.startswith('ear_antenna'):end=[(sign*.22,.025,.735),(sign*.20,.015,1.0),(sign*.25,-.01,1.28),(sign*.34,-.08,1.22)]
 start=[bez(curves[side],i/120) for i in range(121)];finish=[bez(end,i/120) for i in range(121)]
 out=[start[0].lerp(finish[0],phase)]
 for i in range(120):
  a=start[i+1]-start[i];b=finish[i+1]-finish[i]
  # Root-first wave, continuous at both ends. Curl persists until the tip follows.
  t=(i+.5)/120;v=max(0,min(1,(phase-.64*t)/.36));v=v*v*(3-2*v)
  ax=math.atan2(a.x*sign,a.z);bx=math.atan2(b.x*sign,b.z)
  delta=(bx-ax+math.pi)%(2*math.pi)-math.pi
  angle=ax+delta*v
  # Counter-bend near the hanging tip: upright base, soft belly, trailing tip.
  angle+=.36*math.sin(2*math.pi*t)*math.sin(math.pi*phase)**2
  length=a.length*(1-phase)+b.length*phase
  yy=(a.normalized().y*(1-v)+b.normalized().y*v);xz=math.sqrt(max(0,1-yy*yy))
  out.append(out[-1]+Vector((sign*math.sin(angle)*xz,yy,math.cos(angle)*xz))*length)
 # Endpoints are the exact authored target, avoiding a final snap.
 if phase==1:return finish
 return out

def ear_transitions(mesh,member,names):
 transitionRecords=[]
 for target in EAR_TARGETS:
  steps=[{'phase':0,'blendShapes':{},'jointEulerDegrees':{}}]
  for step in range(1,EAR_STEPS):
   phase=step/EAR_STEPS;name=ear_step_name(target,step);names.append(name)
   key=mesh.shape_key_add(name=name,from_mix=False);key.value=0
   for side in ['L','R']:
    if target.startswith('ear_antenna_') and not target.endswith(side):continue
    path=ear_path(side,target,phase)
    def sample(t):
     f=t*120;i=min(119,int(f));return path[i].lerp(path[i+1],f-i)
    for part_index,idx in enumerate(member['ear_'+side]):
     inner=part_index>=620;vi=part_index%620;u=(vi//20)/30;t=.10+.82*u if inner else u
     c=sample(t);ta=sample(min(1,t+.002))-sample(max(0,t-.002));sv=Vector((ta.z,0,-ta.x)).normalized()
     key.data[idx].co=ear_point(c,sv,u,vi%20,inner)
   steps.append({'phase':phase,'blendShapes':{name:1},'jointEulerDegrees':{}})
  steps.append({'phase':1,'blendShapes':{target:1},'jointEulerDegrees':{}})
  transitionRecords.append({'target':target,'keyposes':steps})
 return transitionRecords

def bones():
 out=[('root',None,(0,0,0),(0,0,.10)),('hips','root',(0,0,.135),(0,0,.20)),('spine','hips',(0,0,.20),(0,0,.28)),('chest','spine',(0,0,.28),(0,0,.35)),('neck','chest',(0,0,.35),(0,0,.40)),('head','neck',(0,0,.40),(0,0,.68))]
 for s,l in [(1,'L'),(-1,'R')]:
  a=bez(curves[l],0);b=bez(curves[l],.50);c=bez(curves[l],1)
  out.extend([(f'ear_{l}_01','head',a,b),(f'ear_{l}_02',f'ear_{l}_01',b,c),(f'eye_{l}','head',(s*.134,-.207,.578),(s*.134,-.245,.578)),(f'arm_{l}','chest',(s*.176,-.065,.348),(s*.158,-.12,.24)),(f'hand_{l}',f'arm_{l}',(s*.158,-.12,.24),(s*.15,-.15,.172)),(f'leg_{l}','hips',(s*.14,.035,.137),(s*.144,-.05,.072)),(f'foot_{l}',f'leg_{l}',(s*.144,-.05,.072),(s*.144,-.17,.072))])
 out.append(('tail','hips',(0,.15,.129),(0,.24,.129)))
 return out

def moods():
 from moods import MOODS
 return MOODS
