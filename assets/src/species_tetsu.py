"""Tetsu (TETSU-01), the desk robot, rebuilt as an actual robot (next-wave.md §7, 2026-10-04).

The face is a display: an LED matrix behind the dark glass of its visor. The app draws it (PixelFace.swift) from
character/tetsu/pixel_face.json (tetsu_pixels.py) as pixel-art frames picked by the face weights every companion
shares, so a blink is pixel frames and a mood change is a crisp swap. The model carries no eye shapes: each face
morph name moves only a small hidden carrier inside the head (the names exist for the app and the clips can drive
them), and Tetsu's own display channels ride the same way: px_boot (the boot-up, rows lighting one by one), px_scan
(the scanning sweep), px_spin (the loading spinner) and px_heart (a pat).

The body is a machine: a brushed-metal shell with panel seams and screws, gunmetal joint hubs with polished rings, a
ribbed neck, a dark glass visor in a gunmetal housing, cyan status LEDs (antenna tips, ear rings, three on the chest),
a charging port with an amber light, and TETSU-01 on the chest plate. Its arms are brushed segments with recessed joints
and its hands are mittens in the boots' language (arm()). Same size and the same 21-joint rig.

It moves like a machine: servo() turns every clip into quick moves that overshoot a touch and settle, and nothing
squashes (no bone scale).
"""
import math,json
from common import *
from mathutils import Vector,Quaternion
from shapes import mesh_object,rounded_box,lathe,capsule,frame
from companion import ear_transitions as shared_ear_transitions,MORPHS
import tetsu_pixels
ID='tetsu';SEED=101;VERSION=2
REST_WEIGHTS={}
EXTRA_MORPHS=['led_dim','eyes_dot','sleep_z','px_boot','px_scan','px_spin','px_heart']
# Morphs that move real geometry: the antennae (on the ear chains), their LEDs, and the clamps. Every other name is a
# display channel: it moves only its own triangle of the hidden carrier.
GEOMETRY_MORPHS={'ears_curtain','ears_pinned','ears_lift','ear_antenna_L','ear_antenna_R','arms_fold','paws_lap','led_dim','nose_twitch'}
CHANNELS=[n for n in MORPHS+EXTRA_MORPHS if n not in GEOMETRY_MORPHS]
SCOPES=[('face_decals',('chan',)),('eye_hidden_L',('chan',)),('eye_hidden_R',('chan',))]

# The visor is part of a sphere: radius R about C, flat enough that the boxy head never pokes through its corners.
R=1.0;ZC=.60;YC=-.226+R
# The eye joints keep v1's pivots (the visor's old centre of curvature), so the rig is unchanged.
R1=.60;YC1=-.226+R1
EX,EZ=.100,.614                                  # where the app's hidden pupils sit (the face anchor), x = ±EX
def on_visor(x,z,off):return Vector((x,YC-math.sqrt(max(1e-6,(R+off)**2-x*x-(z-ZC)**2)),z))
VW,VH,VP=.214,.136,4.0                           # visor outline: a superellipse, half width/height and exponent
def outline(r,a):
 c,s=math.cos(a),math.sin(a)
 return VW*r*math.copysign(abs(c)**(2/VP),c),ZC+VH*r*math.copysign(abs(s)**(2/VP),s)
# The display's texture covers the whole visor, a cell per LED pitch, centred on it: UV (0,0) at its bottom-left
# corner, (1,1) at its top-right (tetsu_pixels.TEXTURE; the LED matrix sits inside it at tetsu_pixels.ORIGIN).
DW,DH=tetsu_pixels.TEXTURE[0]*tetsu_pixels.PITCH/2,tetsu_pixels.TEXTURE[1]*tetsu_pixels.PITCH/2
HEAD_C,HEAD_A,HEAD_E=Vector((0,.005,.60)),Vector((.285,.215,.225)),3.8
BODY_C,BODY_A,BODY_E=Vector((0,.02,.215)),Vector((.19,.155,.19)),3.6

M={}
SHELL=(.80,.81,.82);PANEL=(.88,.88,.87);GUN=(.11,.12,.13);CYAN=(.30,.92,1.0);AMBER=(1.0,.58,.10)
def materials(P):
 M['shell']=mat('Tetsu brushed shell',SHELL,.36,.9)
 M['panel']=mat('Tetsu chest panel',PANEL,.30,.7)
 M['gun']=mat('Tetsu gunmetal',GUN,.32,.85)
 M['ring']=mat('Tetsu polished ring',(.86,.87,.89),.16,1.0)
 M['seam']=mat('Tetsu seam',(.022,.024,.028),.7)
 M['display']=mat('Tetsu display',(.006,.008,.010),.06)
 M['display'].node_tree.nodes.get('Principled BSDF').inputs['Specular IOR Level'].default_value=1.0
 M['glint']=mat('Tetsu visor glint',(.85,.88,.92),.3,emission=.35)
 M['led']=mat('Tetsu LED',CYAN,.3,emission=4.0)
 M['amber']=mat('Tetsu amber light',AMBER,.3,emission=3.0)
 # The app finds the face's anchor by the pupil's material name (Moku's): two discs hidden behind the display.
 M['pupil']=mat('Deep cocoa pupil',(.008,.010,.012),.10)

def materials_json(P):
 """Rules for the app (character/tetsu/materials.json): the same schema as runtime/materials.json."""
 def rule(name,tint,rough,spec=.4,emissive=None,intensity=None,normal=None,scale=1.0,flush=False,metal=0.0,tiling=1.0,flushColor=None):
  r={'name':name,'aliases':[name.replace(' ','_')],'baseTint':list(tint)+[1.0],'tintColorSpace':'linearSRGB','baseTintMode':'multiplyTexture','baseColorTexturePath':None,'roughness':rough,'metallic':metal,'specular':spec,'sheenColor':[0,0,0],'sheenColorSpace':'linearSRGB','sheenRoughness':1.0,'normalMapPath':normal,'normalMapColorSpace':'raw','normalScale':scale,'normalTiling':[tiling,tiling],'uvOffset':[0.0,0.0],'opacity':1.0,'doubleSided':False}
  if emissive:r['emissive']=list(emissive);r['emissiveIntensity']=intensity
  if flush:r['flush']=True
  if flushColor:r['flushColor']=list(flushColor)
  return r
 brushed='character/tetsu/brushed_normal.png'
 rules=[rule('Tetsu brushed shell',SHELL,.30,.5,normal=brushed,scale=.45,metal=.55,tiling=2.0),
  rule('Tetsu chest panel',PANEL,.26,.5,normal=brushed,scale=.25,metal=.4,tiling=2.0),
  rule('Tetsu gunmetal',GUN,.30,.5,metal=.7),
  rule('Tetsu polished ring',(.86,.87,.89),.16,.6,metal=1.0),
  rule('Tetsu seam',(.022,.024,.028),.7,.2),
  # The display: the app replaces it with the LED matrix, an unlit picture of dark glass and lit dots (PixelFace.swift).
  rule('Tetsu display',(.006,.008,.010),.07,1.0),
  rule('Deep cocoa pupil',(.008,.010,.012),.10,.9),
  rule('Tetsu LED',CYAN,.3,.2,emissive=CYAN,intensity=2.4,flush=True,flushColor=AMBER),
  rule('Tetsu amber light',AMBER,.3,.2,emissive=AMBER,intensity=1.6),
  rule('Tetsu visor glint',(.85,.88,.92),.3,.2,emissive=(.85,.88,.92),intensity=.22)]
 (P.dir/'materials.json').write_text(json.dumps({'schemaVersion':1,'assetRoot':'assets','pathResolution':'All texture paths are relative to the assets directory, not this JSON file.','matching':'Exact material name or aliases. These rules win over runtime/materials.json for the same name: the hidden pupils keep Moku\'s name (Deep cocoa pupil) so FacialMorphs finds the face.','notes':['flush: true marks what changes when Tetsu is cross: the status LEDs turn from cyan to flushColor (amber). The display draws its own amber.','Tetsu display: the emissive texture is drawn by the app (PixelFace.swift, from pixel_face.json).'],'materials':rules},indent=2)+'\n')

# ---------------------------------------------------------------- surfaces of the superellipsoid shells
def shell_point(c,a,e,d,out=0.0):
 """Where direction d from the shell's centre meets its surface (rounded_box's mapping), pushed `out` along it."""
 d=Vector(d);s=(abs(d.x)**e+abs(d.y)**e+abs(d.z)**e)**(1/e);p=Vector((a.x*d.x/s,a.y*d.y/s,a.z*d.z/s))
 return c+p+p.normalized()*out
def solve_axis(c,a,e,known,axis,sign):
 """The surface coordinate along `axis` (0 x, 1 y, 2 z) on the `sign` side, given the other two coordinates."""
 rest=sum(abs((known[i]-c[i])/a[i])**e for i in range(3) if i!=axis)
 return c[axis]+sign*a[axis]*max(0,1-rest)**(1/e)
def groove(name,points,closed,material,r=.0019,seg=4):
 """A thin dark line laid on a surface (a panel seam), as a tube through `points`."""
 pts=[Vector(p) for p in points];n=len(pts);verts=[];centres=[];faces=[]
 for i,p in enumerate(pts):
  t=(pts[(i+1)%n]-pts[i-1]) if closed else (pts[min(n-1,i+1)]-pts[max(0,i-1)]);u,v=frame(t)
  for k in range(seg):a=2*math.pi*k/seg;verts.append(p+u*r*math.cos(a)+v*r*math.sin(a));centres.append(p)
 for i in range(n if closed else n-1):
  for k in range(seg):a=i*seg+k;b=i*seg+(k+1)%seg;c2=((i+1)%n)*seg+(k+1)%seg;d=((i+1)%n)*seg+k;faces.append((a,b,c2,d))
 return mesh_object(name,verts,faces,material,inside=centres)
def torus(name,centre,axis,big,small,material,seg=24,sides=6):
 centre=Vector(centre);axis=Vector(axis).normalized();u,v=frame(axis);verts=[];centres=[];faces=[]
 for i in range(seg):
  a=2*math.pi*i/seg;radial=u*math.cos(a)+v*math.sin(a);ring=centre+radial*big
  for k in range(sides):b=2*math.pi*k/sides;verts.append(ring+radial*small*math.cos(b)+axis*small*math.sin(b));centres.append(ring)
 for i in range(seg):
  for k in range(sides):a=i*sides+k;b=i*sides+(k+1)%sides;c=((i+1)%seg)*sides+(k+1)%sides;d=((i+1)%seg)*sides+k;faces.append((a,b,c,d))
 return mesh_object(name,verts,faces,material,inside=centres)
def screw(name,at,normal,material,slot,r=.0068):
 """A socket-head screw seated on a surface: a domed head along `normal`, a dark hex socket in it."""
 at=Vector(at);n=Vector(normal).normalized()
 head=lathe(name,at-n*.002,at+n*.0028,[(0,0),(.001,r*.98),(.55,r),(.85,r*.82),(1,0)],material,10)
 sock=lathe(name+'Socket',at+n*.0018,at+n*.0031,[(0,0),(0,r*.45),(1,r*.45),(1,0)],slot,6)
 return head,sock

# ---------------------------------------------------------------- the antennae (on the ear chains)
def ant_curve(s,name='rest'):
 c={'rest':[(.125,.010,.810),(.128,.010,.890),(.148,.006,.960),(.160,.000,1.020)],
  'ears_lift':[(.125,.010,.810),(.126,.006,.910),(.140,-.004,1.010),(.150,-.016,1.085)],      # telescoped up, alert
  'ear_antenna':[(.125,.010,.810),(.122,.000,.905),(.124,-.022,.995),(.128,-.050,1.070)],     # one perks forward to listen
  'ears_curtain':[(.125,.010,.810),(.150,.012,.880),(.225,.004,.900),(.285,-.010,.845)],      # wilted out to the side
  'ears_pinned':[(.125,.010,.810),(.130,.045,.880),(.142,.105,.925),(.150,.170,.945)]}[name]  # swept back
 return [Vector((s*x,y,z)) for x,y,z in c]
def bezier(p,t):return p[0]*(1-t)**3+3*p[1]*t*(1-t)**2+3*p[2]*t*t*(1-t)+p[3]*t**3
NR,NS,LS,LR=26,10,14,9   # rod rows and sides, LED sphere segments and rings
def rod_radius(t):
 # A thin machined rod with two segment collars and a socket for the LED at the tip.
 def band(c):return 1 if abs(t-c)<.022 else 0
 r=.0058*(1+.42*(band(.34)+band(.66)))
 if t>.90:k=min(1,(t-.90)/.05);k=k*k*(3-2*k);r=r+(.0118-r)*k
 return r
def antenna_points(curve,led=1.0):
 pts=[]
 for j in range(NR+1):
  t=j/NR;c=bezier(curve,t);ta=(bezier(curve,min(1,t+.002))-bezier(curve,max(0,t-.002))).normalized();u,v=frame(ta)
  r=rod_radius(t)
  for k in range(NS):a=2*math.pi*k/NS;pts.append(c+u*r*math.cos(a)+v*r*math.sin(a))
 tip=bezier(curve,1);ta=(bezier(curve,1)-bezier(curve,.996)).normalized();u,v=frame(ta)
 pts.append(tip+ta*.001)                      # the socket's cap centre
 rad=.0175*led;centre=tip+ta*(rad*.78)       # the LED stays seated in its socket at any brightness
 for j in range(1,LR):
  th=math.pi*j/LR
  for k in range(LS):a=2*math.pi*k/LS;pts.append(centre+ta*(rad*math.cos(th))+(u*math.cos(a)+v*math.sin(a))*(rad*math.sin(th)))
 pts.append(centre+ta*rad);pts.append(centre-ta*rad)
 return pts
def antenna_inside(curve):
 """Each antenna vertex's inside point: the rod's centre line, the socket's tip, the LED's centre."""
 pts=[]
 for j in range(NR+1):pts+=[bezier(curve,j/NR)]*NS
 tip=bezier(curve,1);ta=(bezier(curve,1)-bezier(curve,.996)).normalized()
 pts.append(tip-ta*.01);pts+=[tip+ta*.014]*((LR-1)*LS+2)
 return pts
def antenna_faces():
 f=[];mat_idx=[]
 for j in range(NR):
  for k in range(NS):a=j*NS+k;b=j*NS+(k+1)%NS;f.append((a,b,b+NS,a+NS));mat_idx.append(0)
 cap=(NR+1)*NS;f+=[(NR*NS+k,NR*NS+(k+1)%NS,cap) for k in range(NS)];mat_idx+=[0]*NS
 f.append(tuple(reversed(range(NS))));mat_idx.append(0)
 base=cap+1;top=base+(LR-1)*LS;bottom=top+1
 for j in range(LR-2):
  for k in range(LS):a=base+j*LS+k;b=base+j*LS+(k+1)%LS;f.append((a,b,b+LS,a+LS));mat_idx.append(1)
 f+=[(base+k,base+(k+1)%LS,top) for k in range(LS)];mat_idx+=[1]*LS
 last=base+(LR-2)*LS;f+=[(last+(k+1)%LS,last+k,bottom) for k in range(LS)];mat_idx+=[1]*LS
 return f,mat_idx

# ---------------------------------------------------------------- the arms and hands
# The joints the arm hangs from (the rig's arm and hand bones): the shoulder, the elbow, and the hand bone's tip.
def arm_joints(s):return Vector((s*.205,.000,.350)),Vector((s*.232,-.030,.236)),Vector((s*.237,-.072,.118))
def placed(o,centre,axes):
 """An object built about the origin, moved into the frame `axes` (its x, y and z) at `centre`."""
 from mathutils import Matrix
 R=Matrix((axes[0],axes[1],axes[2])).transposed()
 for v in o.data.vertices:v.co=Vector(centre)+R @ v.co
 if R.determinant()<0:o.data.flip_normals()  # a mirrored frame (the left hand's) turns the faces inside out
 o.data.update();return o
def box_seam(name,centre,axes,half,e,at,material,seg=32):
 """A seam round a placed rounded box, across it at `at` (-1 its bottom … 1 its top, along its z)."""
 a,b,c=half;left=max(0,1-abs(at)**e)**(1/e);pts=[]
 from mathutils import Matrix
 R=Matrix((axes[0],axes[1],axes[2])).transposed()
 for k in range(seg):
  t=2*math.pi*k/seg;cx,cy=math.cos(t),math.sin(t);k2=left/(abs(cx)**e+abs(cy)**e)**(1/e)
  pts.append(Vector(centre)+R @ Vector((cx*(k2*a+.0006),cy*(k2*b+.0006),at*c)))
 return groove(name,pts,True,material,.0017)
def arm(add,s,l):
 """An arm built like the rest of the machine (Charles, 2026-10-04: "I don't like the hands of tetsu"): brushed
 segments with recessed gunmetal joints, each joint with its polished ring, and a mitten hand that reads at 100 px.
 The hand is the boots' language: a brushed shell over a gunmetal grip pad on the palm, a knuckle seam and two
 finger grooves across its back, a thumb toward you. The bones are unchanged, so every clip and prop still fits."""
 sh,gun,ring,seam=M['shell'],M['gun'],M['ring'],M['seam']
 S,E,W=arm_joints(s);up=(E-S).normalized();down=(W-E).normalized()
 x=Vector((s,0,0));out=(x-down*down.dot(x)).normalized();fwd=out.cross(down)
 if fwd.y>0:fwd=-fwd
 A,H='arm_'+l,'hand_'+l
 add(lathe('Shoulder_'+l,(s*.168,.000,.348),(s*.236,.000,.348),[(0,.044),(.15,.050),(.85,.050),(1,.044),(1,0)],gun,24),A,A)
 add(torus('ShoulderRing_'+l,(s*.226,.000,.348),(1,0,0),.050,.0050,ring,24,6),A,A)
 add(lathe('UpperArm_'+l,S+up*.022,E-up*.004,[(0,0),(.001,.027),(.10,.035),(.55,.036),(.92,.033),(1,.026),(1,0)],sh,22),A,A)
 # The elbow: a hub turned along x, narrower than the arm round it, so it reads as a joint, not a band.
 add(lathe('Elbow_'+l,E-x*.024,E+x*.024,[(0,.026),(.12,.029),(.88,.029),(1,.026),(1,0)],gun,20),H,H)
 add(torus('ElbowRing_'+l,E+x*.019,(1,0,0),.029,.0030,ring,20,5),H,H)
 add(lathe('Forearm_'+l,E+down*.012,E+down*.078,[(0,0),(.001,.029),(.12,.036),(.55,.035),(.94,.032),(1,.028),(1,0)],sh,22),H,H)
 add(lathe('Cuff_'+l,E+down*.073,E+down*.089,[(0,0),(.001,.025),(.2,.028),(.8,.028),(1,.025),(1,0)],gun,20),H,H)
 add(torus('CuffRing_'+l,E+down*.081,down,.028,.0028,ring,20,5),H,H)
 # The mitten: its broad side to the body, the thumb toward you, the palm's grip pad to the inside.
 axes=(out,fwd,-down);half=(.034,.040,.045);e=2.5;c=E+down*.132
 add(placed(rounded_box('Mitt_'+l,(0,0,0),half,e,sh,9),c,axes),H,H)
 add(placed(rounded_box('Grip_'+l,(0,0,0),(.007,.032,.035),2.6,gun,6),c-out*(half[0]-.0045)+down*.003,axes),H,H)
 add(box_seam('Knuckles_'+l,c,axes,half,e,.14,seam),H,H)
 for f in (-.33,.33):
  pts=[]
  for k in range(7):
   t=.14-1.06*k/6*.82;left=max(0,1-abs(t)**e-abs(f)**e)**(1/e)
   pts.append(c+out*(half[0]*left+.0006)+fwd*(f*half[1])-down*(t*half[2]))
  add(groove(f'Finger{"AB"[f>0]}_'+l,pts,False,seam,.0015),H,H)
 base=c+fwd*.032-down*.014-out*.006;tip=base+fwd*.016+down*.024-out*.010
 add(capsule('Thumb_'+l,base,tip,.015,sh,14,4),H,H)
MITT=.132  # the mitten's centre, along the hand bone from the elbow
def hand_grip(rig,side='R',along=.124):
 """Where a held prop sits (a hammer's handle): in the mitten's grip, in armature space for the current pose."""
 s=1 if side=='L' else -1;_,E,W=arm_joints(s);down=(W-E).normalized()
 bone=rig.pose.bones['hand_'+side];rest=rig.data.bones['hand_'+side].matrix_local
 return rig.matrix_world @ bone.matrix @ rest.inverted() @ (E+down*along)
def hand_toward(rig,side,target):
 """The hand joint's local turn that points the forearm from the (posed) elbow at `target` (armature space), the palm
 turned to face the middle. The arm must be posed already."""
 from mathutils import Quaternion
 s=1 if side=='L' else -1
 bone=rig.pose.bones['hand_'+side];rest=rig.data.bones['hand_'+side].matrix_local.to_quaternion()
 parent=rig.pose.bones['arm_'+side];relative=(rig.data.bones['arm_'+side].matrix_local.inverted() @ rig.data.bones['hand_'+side].matrix_local).to_quaternion()
 unposed=parent.matrix.to_quaternion() @ relative             # the hand's rotation with nothing of its own
 want=(Vector(target)-bone.head).normalized()
 turned=(unposed @ Vector((0,1,0))).rotation_difference(want) @ unposed
 _,E,W=arm_joints(s);down=(W-E).normalized();x=Vector((s,0,0));out=(x-down*down.dot(x)).normalized()
 palm=turned @ (rest.inverted() @ -out)                      # where the palm faces now
 goal=Vector((-s,0,0));goal=(goal-want*goal.dot(want)).normalized();palm=(palm-want*palm.dot(want)).normalized()
 angle=palm.angle(goal,0.0)*(1 if palm.cross(goal).dot(want)>0 else -1)
 return unposed.inverted() @ Quaternion(want,angle) @ turned
def reach(side,arm_direction,target,v=1.0):
 """The upper arm along `arm_direction`, the forearm turned at the elbow toward `target`, eased in by `v`: a mitten
 holding something in front of the chest."""
 import motion_v2 as m
 from mathutils import Quaternion
 m.arm(side,arm_direction,v);bpy.context.view_layer.update()
 m.rig.pose.bones['hand_'+side].rotation_euler=Quaternion().slerp(hand_toward(m.rig,side,target),max(0,min(1,v))).to_euler('XYZ')
def two_hand_hold(v,lift=0.0,width=0.0):
 """Both mittens round something held up in front of the chest plate (the battery cell; `width` more for a cup)."""
 for side,s in [('L',1),('R',-1)]:reach(side,(-s*.35,-.88,-.33),(s*(.03+width),-.21,.245+lift),v)
 bpy.context.view_layer.update()
def held_anchor(rig,height):
 """The base of a held thing `height` tall, between the mittens' centres (the pose on now)."""
 mid=(hand_grip(rig,'L',MITT)+hand_grip(rig,'R',MITT))/2
 return mid-Vector((0,0,height/2))

def build(add):
 sh,gun,seam,ring=M['shell'],M['gun'],M['seam'],M['ring']
 # ---- head: a machined box, the display set into its face in a gunmetal housing
 add(rounded_box('Head',tuple(HEAD_C),tuple(HEAD_A),HEAD_E,sh,18),'head','head')
 K,S=12,72;verts=[on_visor(0,ZC,0)];faces=[]
 for i in range(1,K+1):
  for k in range(S):x,z=outline(i/K,2*math.pi*k/S);verts.append(on_visor(x,z,0))
 faces+=[(0,1+k,1+(k+1)%S) for k in range(S)]
 for i in range(K-1):
  for k in range(S):a=1+i*S+k;b=1+i*S+(k+1)%S;faces.append((a,b,b+S,a+S))
 visor=mesh_object('Display',verts,faces,M['display'],inside=(0,YC,ZC))
 # Planar UVs over the display's texture, all inside 0…1.
 uv=visor.data.uv_layers['UVMap']
 for loop in visor.data.loops:
  co=visor.data.vertices[loop.vertex_index].co;uv.data[loop.index].uv=((co.x+DW)/(2*DW),(co.z-(ZC-DH))/(2*DH))
 add(visor,'visor','head')
 # The housing: a gunmetal lip round the glass and a slim frame proud of the face.
 S2,C2=96,8;verts=[];faces=[];centres=[]
 for k in range(S2):
  a=2*math.pi*k/S2;x,z=outline(1.0,a);x2,z2=outline(1.0,a+.01);t=Vector((x2-x,0,z2-z)).normalized();out=Vector((t.z,0,-t.x))
  if out.dot(Vector((x,0,z-ZC)))<0:out=-out
  c=on_visor(x,z,0)+Vector((0,.006,0))+out*.004
  for m in range(C2):b=2*math.pi*m/C2;verts.append(c+out*(.016*math.cos(b))+Vector((0,-.012*math.sin(b),0)));centres.append(c)
 for k in range(S2):
  for m in range(C2):a=k*C2+m;b=k*C2+(m+1)%C2;c2=((k+1)%S2)*C2+(m+1)%C2;d=((k+1)%S2)*C2+m;faces.append((a,b,c2,d))
 add(mesh_object('Housing',verts,faces,gun,inside=centres),'bezel','head')
 # Four socket screws at the housing's corners, on the face of the head.
 for i,a in enumerate([math.radians(d) for d in (38,142,218,322)]):
  x,z=outline(1.0,a);x*=1.10;z=ZC+(z-ZC)*1.18
  y=solve_axis(HEAD_C,HEAD_A,HEAD_E,(x,0,z),1,-1);p=Vector((x,y,z));n=(p-HEAD_C);n=Vector((n.x/HEAD_A.x**2,n.y/HEAD_A.y**2,n.z/HEAD_A.z**2)).normalized()
  for o in screw(f'FaceScrew{i}',p,n,gun,seam,.0062):add(o,'bezel','head')
 # Panel seams: a side panel round each ear puck, a hatch on the crown, a seam round the back of the head.
 for s,l in [(1,'L'),(-1,'R')]:
  pts=[]
  for k in range(48):
   a=2*math.pi*k/48;y,z=.012+.098*math.cos(a),.598+.090*math.sin(a);pts.append(Vector((solve_axis(HEAD_C,HEAD_A,HEAD_E,(0,y,z),0,s)+s*.0006,y,z)))
  add(groove('SidePanel_'+l,pts,True,seam),'head','head')
  for j,a in enumerate((.6,2.7,4.6)):
   y,z=.012+.098*math.cos(a),.598+.090*math.sin(a);p=Vector((solve_axis(HEAD_C,HEAD_A,HEAD_E,(0,y,z),0,s),y,z))
   for o in screw(f'SideScrew{l}{j}',p,(s,0,0),gun,seam,.0052):add(o,'head','head')
  # The ear puck: a gunmetal hub, a polished ring, a cyan status LED in its centre.
  add(lathe('EarPuck_'+l,(s*.262,.012,.598),(s*.300,.012,.598),[(0,.060),(.7,.060),(.85,.056),(1,.050),(1,0)],gun,28),'puck_'+l,'head')
  add(torus('PuckRing_'+l,(s*.300,.012,.598),(1,0,0),.040,.0045,ring,24,6),'puck_'+l,'head')
  add(lathe('PuckLED_'+l,(s*.298,.012,.598),(s*.307,.012,.598),[(0,.016),(.6,.015),(1,0)],M['led'],16),'puck_'+l,'head')
 pts=[]
 for k in range(64):
  a=2*math.pi*k/64;x,y=.150*math.copysign(abs(math.cos(a))**.5,math.cos(a)),.035+.120*math.copysign(abs(math.sin(a))**.5,math.sin(a))
  pts.append(Vector((x,y,solve_axis(HEAD_C,HEAD_A,HEAD_E,(x,y,0),2,1)+.0006)))
 add(groove('CrownHatch',pts,True,seam),'head','head')
 for i,(x,y) in enumerate([(-.118,-.060),(.118,-.060),(-.118,.130),(.118,.130)]):
  for o in screw(f'CrownScrew{i}',(x,y,solve_axis(HEAD_C,HEAD_A,HEAD_E,(x,y,0),2,1)),(0,0,1),gun,seam,.0055):add(o,'head','head')
 pts=[]
 for k in range(40):
  x=-.235+.47*k/39;z=.70;pts.append(Vector((x,solve_axis(HEAD_C,HEAD_A,HEAD_E,(x,0,z),1,1)+.0006,z)))
 add(groove('BackSeam',pts,False,seam),'head','head')
 for i,z in enumerate([.645,.618,.591,.564]):
  add(rounded_box(f'Vent{i}',(0,.214,z),(.080,.010,.0065),3,seam,4),'vent','head')
 # Glass glint: a soft reflection of the studio's key light, fixed on the glass.
 verts=[];faces=[]
 for i,(r0,r1,a0,a1) in enumerate([(.86,.91,1.95,2.50),(.86,.91,2.62,2.70)]):
  base=len(verts);n=14
  for k in range(n+1):
   a=a0+(a1-a0)*k/n
   for r in (r0,r1):x,z=outline(r,a);verts.append(on_visor(x,z,.0008))
  faces+=[(base+2*k,base+2*k+1,base+2*k+3,base+2*k+2) for k in range(n)]
 add(mesh_object('VisorGlint',verts,faces,M['glint'],inside=(0,YC,ZC)),'glint','head')
 # The face's anchor for the app (its gaze and overlays): two small dark discs hidden behind the display.
 for s,l in [(1,'L'),(-1,'R')]:
  v=[(s*EX,EZ)]+[(s*EX+.018*math.cos(2*math.pi*k/16),EZ+.018*math.sin(2*math.pi*k/16)) for k in range(16)]
  f=[(0,1+k,1+(k+1)%16) for k in range(16)]
  add(mesh_object('Pupil_'+l,[on_visor(x,z,-.010) for x,z in v],f,M['pupil'],inside=(0,YC,ZC)),'pupil_'+l,'eye_'+l)
 # The display channels' carrier: a tiny triangle per channel, deep inside the head, never seen.
 verts=[];faces=[]
 for i,_ in enumerate(CHANNELS):
  x=-.06+.12*(i%12)/11;z=.56+.02*(i//12);b=len(verts);verts+=[Vector((x,.06,z)),Vector((x+.004,.06,z)),Vector((x,.06,z+.004))];faces.append((b,b+1,b+2))
 add(mesh_object('Channels',verts,faces,gun,inside=(0,.2,.6)),'chan','head')
 # ---- antennae with LED tips, on the ear chains; gunmetal collars with a polished ring where they leave the head
 f,mi=antenna_faces()
 for s,l in [(1,'L'),(-1,'R')]:
  o=mesh_object('Antenna_'+l,antenna_points(ant_curve(s)),f,gun,inside=antenna_inside(ant_curve(s)));o.data.materials.append(M['led'])
  for poly,i in zip(o.data.polygons,mi):poly.material_index=i
  add(o,'ear_'+l,'ear_'+l+'_01')
  add(lathe('Collar_'+l,(s*.125,.010,.790),(s*.125,.010,.840),[(0,.022),(.55,.022),(.75,.017),(1,.011),(1,0)],gun,18),'collar_'+l,'head')
  add(torus('CollarRing_'+l,(s*.125,.010,.812),(0,0,1),.0215,.0032,ring,20,6),'collar_'+l,'head')
 # ---- body: a brushed torso, a raised chest plate with TETSU-01, three status LEDs, a waist seam, a charging port
 add(rounded_box('Body',tuple(BODY_C),tuple(BODY_A),BODY_E,sh,14),'body','spine')
 add(lathe('Neck',(0,0,.350),(0,0,.410),[(0,.076),(1,.072)],gun,24),'neck','chest')
 for i,z in enumerate([.366,.392]):add(torus(f'NeckRing{i}',(0,0,z),(0,0,1),.079,.0055,ring,24,6),'neck','chest')
 add(rounded_box('ChestPlate',(0,-.128,.245),(.118,.014,.104),4.4,M['panel'],8),'plate','spine')
 for i,x in enumerate((-.032,0,.032)):add(rounded_box(f'StatusLED{i}',(x,-.1435,.200),(.0085,.004,.0055),4.0,M['led'],4),'plate','spine')
 add(rounded_box('LEDBezel',(0,-.1405,.200),(.050,.003,.012),4.0,seam,6),'plate','spine')
 for x in (-.096,.096):
  for z in (.165,.322):
   for o in screw('Screw',(x,-.1415,z),(0,-1,0),M['gun'],seam,.0058):add(o,'plate','spine')
 bpy.ops.object.select_all(action='DESELECT')
 cu=bpy.data.curves.new('Stamp','FONT');cu.body='TETSU-01';cu.size=.027;cu.extrude=.0009;cu.align_x='CENTER';cu.align_y='CENTER';cu.space_character=1.15
 txt=bpy.data.objects.new('Stamp',cu);bpy.context.collection.objects.link(txt);txt.location=(0,-.1425,.272);txt.rotation_euler=(math.pi/2,0,0)
 bpy.context.view_layer.objects.active=txt;txt.select_set(True);bpy.ops.object.convert(target='MESH');txt=bpy.context.object;txt.select_set(False)
 add(finish(txt,'Stamp',seam),'plate','spine')
 for z,name in [(.112,'WaistSeam'),(.338,'ShoulderSeam')]:
  pts=[]
  left=1-abs((z-BODY_C.z)/BODY_A.z)**BODY_E
  for k in range(72):
   a=2*math.pi*k/72;c,s2=math.cos(a),math.sin(a)
   k2=(left/(abs(c/BODY_A.x)**BODY_E+abs(s2/BODY_A.y)**BODY_E))**(1/BODY_E)+.0006
   pts.append(Vector((BODY_C.x+k2*c,BODY_C.y+k2*s2,z)))
  add(groove(name,pts,True,seam),'body','spine')
 # The charging port on Tetsu's left side, with its amber light just above it.
 px=solve_axis(BODY_C,BODY_A,BODY_E,(0,-.035,.190),0,1)
 add(rounded_box('Port',(px-.002,-.035,.190),(.0045,.024,.0085),4.0,seam,6),'body','spine')
 add(rounded_box('PortTongue',(px+.0012,-.035,.190),(.0018,.015,.0026),3.0,M['gun'],4),'body','spine')
 add(rounded_box('PortLight',(px-.0012,-.035,.214),(.0035,.0042,.0042),3.0,M['amber'],4),'body','spine')
 for s,l in [(1,'L'),(-1,'R')]:
  arm(add,s,l)
  # Seated legs: a gunmetal hip hub with its ring, a short brushed thigh, a boot with a gunmetal sole toward you.
  add(lathe('Hip_'+l,(s*.078,-.022,.092),(s*.150,-.022,.092),[(0,.040),(.15,.046),(.85,.046),(1,.040),(1,0)],gun,22),'leg_'+l,'leg_'+l)
  add(torus('HipRing_'+l,(s*.142,-.022,.092),(1,0,0),.046,.0045,ring,24,6),'leg_'+l,'leg_'+l)
  add(capsule('Thigh_'+l,(s*.113,-.030,.088),(s*.121,-.096,.080),.045,sh,18,5),'leg_'+l,'leg_'+l)
  add(rounded_box('Boot_'+l,(s*.124,-.152,.078),(.072,.084,.070),3.6,sh,10),'foot_'+l,'foot_'+l)
  add(rounded_box('Sole_'+l,(s*.124,-.236,.078),(.063,.0125,.060),3.4,gun,8),'pad_'+l,'foot_'+l)
  add(torus('AnkleRing_'+l,(s*.124,-.098,.080),(0,1,0),.050,.0042,ring,24,6),'foot_'+l,'foot_'+l)

def skin(o,tag,joint,vg):
 if tag.startswith('ear_'):
  vg2=o.vertex_groups.new(name=joint.replace('_01','_02'))
  for v in o.data.vertices:
   t=1.0 if v.index>=(NR+1)*NS else (v.index//NS)/NR
   w=max(0,min(1,(t-.30)/.40));vg.add([v.index],1-w,'REPLACE');vg2.add([v.index],w,'REPLACE')
  return True
 if tag.startswith('pupil_'):
  head=o.vertex_groups.new(name='head');ids=list(range(len(o.data.vertices)))
  vg.add(ids,.22,'REPLACE');head.add(ids,.78,'REPLACE');return True
 return False

_cache={}
def cached(key,fn):
 if key not in _cache:_cache[key]=fn()
 return _cache[key]

def morph(name,tag,part_index,co,s):
 if tag=='chan':
  if name in CHANNELS and part_index//3==CHANNELS.index(name):co.z+=.001
  return
 if tag.startswith('ear_'):
  side=1 if tag=='ear_L' else -1
  curve={'ears_lift':'ears_lift','ears_curtain':'ears_curtain','ears_pinned':'ears_pinned','ear_antenna_L':'ear_antenna' if side==1 else None,'ear_antenna_R':'ear_antenna' if side==-1 else None}.get(name)
  if curve:co[:]=cached(('ant',side,curve,1.0),lambda:antenna_points(ant_curve(side,curve)))[part_index]
  led={'led_dim':.55,'nose_twitch':1.25}.get(name)
  if led:co[:]=cached(('ant',side,'rest',led),lambda:antenna_points(ant_curve(side),led))[part_index]
  return
 if tag.startswith('hand_') and name in ('arms_fold','paws_lap'):
  # The clamps tuck in toward the body when the arms fold, and settle when they rest in the lap.
  if co.z<.20:
   if name=='arms_fold':co.x-=s*.010;co.y+=.004
   else:co.z-=.006;co.y-=.004

def ear_transitions(mesh,member,names):
 rest={1:ant_curve(1),-1:ant_curve(-1)}
 def sample(side,target,phase,part_index,_):
  sg=1 if side=='L' else -1;goal='ear_antenna' if target.startswith('ear_antenna') else target
  def make():
   end=ant_curve(sg,goal);curve=[a.lerp(b,phase) for a,b in zip(rest[sg],end)];return antenna_points(curve)
  return cached(('trans',sg,goal,round(phase,5)),make)[part_index]
 return shared_ear_transitions(mesh,member,names,sample)

def bones():
 out=[('root',None,(0,0,0),(0,0,.10)),('hips','root',(0,0,.12),(0,0,.20)),('spine','hips',(0,0,.20),(0,0,.28)),('chest','spine',(0,0,.28),(0,0,.35)),('neck','chest',(0,0,.35),(0,0,.39)),('head','neck',(0,0,.39),(0,0,.66))]
 for s,l in [(1,'L'),(-1,'R')]:
  c=ant_curve(s);mid=bezier(c,.5)
  out.extend([(f'ear_{l}_01','head',tuple(c[0]),tuple(mid)),(f'ear_{l}_02',f'ear_{l}_01',tuple(mid),tuple(c[3])),
   (f'eye_{l}','head',(0,YC1,ZC),(s*EX,YC1-math.sqrt((R1+.0025)**2-EX*EX-(EZ-ZC)**2),EZ)),
   (f'arm_{l}','chest',tuple(arm_joints(s)[0]),tuple(arm_joints(s)[1])),(f'hand_{l}',f'arm_{l}',tuple(arm_joints(s)[1]),tuple(arm_joints(s)[2])),
   (f'leg_{l}','hips',(s*.112,-.010,.096),(s*.121,-.096,.080)),(f'foot_{l}',f'leg_{l}',(s*.121,-.096,.080),(s*.124,-.236,.078))])
 out.append(('tail','hips',(0,.15,.13),(0,.24,.13)))
 return out

def after_export(P,rig,mesh):
 materials_json(P);tetsu_pixels.write(P.dir)  # brushed_normal.png: tetsu_pixels.py (Pillow), run by rebuild.sh

# ---------------------------------------------------------------- moods: the display does almost everything
# Joint angles for the antennae are authored as tilts (outward, forward, in degrees) and turned into each bone's
# local rotation by derive_mood_ears.py --companion=tetsu, like the arm poses.
MOOD_FACES={
 'content':({},{},{},'Upright, attentive: two open eyes on the matrix'),
 'happy':({'eyes_happy':.85,'smile':1,'brows_up':.3},{'head':[-5,0,-4]},{'L':(10,0,6,0),'R':(10,0,6,0)},'Pixel arcs for eyes, antennae splayed'),
 'proud':({'eyes_proud':.55,'smile':.6},{'head':[-9,0,3],'chest':[-3,0,0]},{'L':(-3,0,0,0),'R':(-3,0,0,0)},'Chin up, flat-topped eyes'),
 'curious':({'eyes_wide':.75,'brow_raise_L':.6},{'head':[1,0,12]},{'L':(0,14,0,8),'R':(-4,-4,0,0)},'Head tilt, wide eyes, one antenna leaning in'),
 'concerned':({'brows_concern':1,'frown':.55,'eyes_wide':.12},{'head':[7,0,-5]},{'L':(14,4,8,0),'R':(14,4,8,0)},'Tilted eyes, antennae easing down'),
 'disappointed':({'brows_concern':.6,'lid_sad':.8,'blink_L':.35,'blink_R':.35,'frown':.85,'arms_fold':0,'paws_lap':1,'led_dim':.6},{'head':[12,0,0],'chest':[4,0,0]},{'L':(26,6,30,6),'R':(26,6,30,6)},'Sad tilted eyes, antennae wilted, LEDs dim'),
 'annoyed':({'brows_angry':1,'blink_L':.25,'blink_R':.25,'frown':.4,'arms_fold':1},{'head':[0,0,-7]},{'L':(-6,-22,0,-10),'R':(-6,-22,0,-10)},'Cross eyes in amber, antennae swept back'),
 'sleepy':({'eyes_dot':1,'sleep_z':1,'led_dim':1},{'head':[13,0,7],'chest':[5,0,0]},{'L':(30,10,34,10),'R':(30,10,34,10)},'Powered down: two dots and a z'),
}
# Joint angles: moods.json holds them in the app's order (RealityCharacter turns a joint by rest·Rx·Ry·Rz, Blender's
# 'ZYX' Euler), so the held poses on the desktop are the ones authored here. motion_v2 converts them to Blender's XYZ
# for the fold, cross, release and hold clips (app_euler), and app_mood() below does for Tetsu's own moves: both ends
# of every clip meet the held pose.
def app_degrees(q):
 e=q.to_euler('ZYX');return [round(math.degrees(a),4) for a in (e.x,e.y,e.z)]
def moods():
 path=paths_moods()
 if path.exists():
  data=json.loads(path.read_text())['moods']
  return {k:(v['blendShapes'],v['jointEulerDegrees'],v['posture']) for k,v in data.items()}
 return {k:(w,dict(j),p) for k,(w,j,a,p) in MOOD_FACES.items()}
def app_mood(name):
 """motion_v2's mood(), with the joints turned as the app turns them."""
 import motion_v2 as m
 weights,joints,_=m.MOODS[name]
 for k in m.mesh.data.shape_keys.key_blocks:k.value=0
 for k,v in weights.items():m.shape(k,v)
 for k,v in joints.items():m.rot(k,*m.app_euler(v),raw=True)
def paths_moods():
 from companion import paths
 return paths(ID).dir/'moods.json'

# Arms for the held moods: where the upper arm points (armature space) and, where the elbow bends, where the forearm
# points to. Cross is hands on hips (2026-10-04): elbows out, mittens at the hips, so the chest plate and its amber LEDs
# stay in view; the crossed arms of a bunny buried a robot's short arms in its chest. Let down is the mittens resting in
# the lap.
ARM_TARGETS={'annoyed':{'L':((.76,.05,-.64),(.235,-.03,.165)),'R':((-.76,.05,-.64),(-.235,-.03,.165))},
 'disappointed':{'L':((-.07,-.13,-.15),None),'R':((.07,-.12,-.16),None)}}
def mood_table(rig):
 from companion import tilt_degrees
 from mathutils import Euler
 def q(degrees):return Euler([math.radians(a) for a in degrees],'XYZ').to_quaternion()
 table={}
 for b in rig.pose.bones:b.rotation_mode='QUATERNION';b.rotation_quaternion=(1,0,0,0)
 for name,(weights,joints,tilts,posture) in MOOD_FACES.items():
  j={k:q(v) for k,v in joints.items()}
  for side,(o1,f1,o2,f2) in tilts.items():
   sg=1 if side=='L' else -1
   if o1 or f1:j[f'ear_{side}_01']=q(tilt_degrees(rig,f'ear_{side}_01',o1,f1,sg))
   if o2 or f2:j[f'ear_{side}_02']=q(tilt_degrees(rig,f'ear_{side}_02',o2,f2,sg))
  for side,(direction,hand) in ARM_TARGETS.get(name,{}).items():
   b=rig.data.bones['arm_'+side];r=b.matrix_local.to_quaternion()
   j['arm_'+side]=r.inverted() @ (b.tail_local-b.head_local).rotation_difference(Vector(direction)) @ r
   if hand:
    rig.pose.bones['arm_'+side].rotation_quaternion=j['arm_'+side];bpy.context.view_layer.update()
    j['hand_'+side]=hand_toward(rig,side,hand)
    rig.pose.bones['arm_'+side].rotation_quaternion=(1,0,0,0);bpy.context.view_layer.update()
  table[name]=(weights,{k:app_degrees(v) for k,v in j.items()},posture)
 return table

# ---------------------------------------------------------------- signature moves (clips under the shared names)
# scan: while you focus, now and then the eyes narrow and a bright column sweeps the matrix, the antennae flick, then
# a small approving nod.
EXTRA_CLIPS=[('scan',2.6,False)]
def pose(name,u,t,duration):
 import motion_v2 as m
 sm,pulse,rot,shape=m.smooth,m.pulse,m.rot,m.shape
 def base():
  app_mood('content');e=m.envelope(u)
  for side,sign in [('L',1),('R',-1)]:rot('ear_'+side+'_02',x=1.4*math.sin(2*math.pi*u)*e,z=sign*.7*math.sin(4*math.pi*u)*e)
 if name=='hello_wave':
  # Boot-up: powered down for a beat (the LEDs dark), the matrix lights row by row from the top, flashes full, goes
  # dark, the eyes switch on as a line and open, then a wave. 3 s, starting and ending at the content rest.
  s=u*duration;base()
  boot=0 if s<.04 or s>1.62 else min(1,max(.004,(s-.10)/1.45))
  shape('px_boot',boot)
  shape('led_dim',1-sm((s-1.2)/.35))
  rot('head',x=8*(1-sm((s-1.15)/.30)) if s<1.6 else 0)
  for side,sign in [('L',1),('R',-1)]:rot('ear_'+side+'_01',x=10*(1-sm((s-1.25)/.25)),z=-sign*6*(1-sm((s-1.25)/.25)))
  v=pulse(u,.56,.66,.98)
  m.arm('L',(.24+.035*math.sin(8*math.pi*u),-.14,.12+.025*math.sin(8*math.pi*u)),v)
  rot('hand_L',z=14*math.sin(8*math.pi*u)*v);rot('head',z=-5*v)
  shape('eyes_happy',.9*pulse(u,.62,.70,.94))
  return True
 if name=='big_celebrate':
  # Comeback: a happy double beep (the antenna LEDs blip and a smile flashes on the matrix), a spin on the spot, arcs.
  s=u*duration;base();v=pulse(u,.03,.20,.96);shape('eyes_happy',v);m.ear_lift(v)
  beep=pulse(s,.30,.34,.46)+pulse(s,.56,.60,.74)
  shape('mouth_smile_open',1 if beep>.5 else 0);shape('nose_twitch',beep)
  m.hop_motion(min(1,max(0,(u-.30)/.55)),.050,.3)
  rot('root',y=360*sm((u-.36)/.42))
  for side,sign in [('L',1),('R',-1)]:m.arm(side,(sign*.22,-.06,.04),.75*v)
  rot('head',x=-4*v)
  return True
 if name=='pat_reaction':
  # Pat: a heart on the matrix, the antennae wiggle, the LEDs blip.
  base();v=pulse(u,.03,.22,.97);shape('px_heart',1 if v>.25 else 0);shape('nose_twitch',.6*v)
  rot('head',x=-4*v,z=5*v)
  for side,sign in [('L',1),('R',-1)]:
   w=math.sin(2*math.pi*(5*u+(.25 if side=='R' else 0)))*v
   rot('ear_'+side+'_02',x=4*w,z=sign*10*w);rot('ear_'+side+'_01',z=sign*4*w)
  return True
 if name=='drink_water':
  # Water is recharging: the battery cell held up in both mittens, eyes on it, the LEDs brightening as it fills
  # (three charging blips), then a happy beep and it settles. Same 12 s as Moku's drink.
  base();s=u*duration
  hold=sm((s-.35)/.9)*(1-sm((s-10.45)/1.2))
  two_hand_hold(hold)
  look=sm((s-1.0)/1.0)*(1-sm((s-9.2)/.8));rot('head',x=9*look);shape('eyes_look_down',look);shape('eyes_narrow',.6*look)
  charge=sm((s-1.6)/7.6);shape('led_dim',(1-charge)*look*.8)
  blips=sum(pulse(s,a,a+.12,a+.35) for a in (3.2,5.4,7.6));shape('nose_twitch',blips)
  full=pulse(s,9.3,9.8,11.4);shape('eyes_happy',full);shape('mouth_smile_open',1 if pulse(s,9.4,9.5,9.9)>.5 else 0);m.ear_lift(.4*full)
  return True
 if name=='tea_sit':
  # A cup held in both mittens in front of the chest (the home scene's tea), a slow sip-and-rest rhythm, a blink.
  base();two_hand_hold(1,lift=.004*math.sin(2*math.pi*u),width=.05);rot('head',x=4+.4*math.sin(2*math.pi*u),z=-2)
  shape('blink_L',pulse(u,.64,.68,.74));shape('blink_R',pulse(u,.64,.68,.74))
  return True
 if name=='sleep_loop':
  # Powered down: two small dots, a "z" that grows on the matrix, LEDs breathing slowly.
  app_mood('sleepy');sn=math.sin(2*math.pi*u)
  rot('head',x=15,z=7)
  shape('led_dim',.85+.15*sn);shape('sleep_z',1 if (u*2)%1<.5 else .5);return True
 if name=='scan':
  # The eyes narrow, a bright column sweeps the matrix left to right and back, the antennae flick, an approving nod.
  base();v=pulse(u,.04,.12,.90);shape('eyes_narrow',.8 if v>.3 else 0)
  shape('px_scan',min(1,max(0,(u-.14)/.5)) if .14<u<.66 else 0)
  for side,sign in [('L',1),('R',-1)]:
   f=pulse(u,.18+(.04 if side=='R' else 0),.22+(.04 if side=='R' else 0),.30+(.04 if side=='R' else 0))
   rot('ear_'+side+'_02',z=sign*9*math.sin(6*math.pi*u)*f)
  nod=pulse(u,.70,.78,.92);rot('head',x=6*nod)
  if nod>.3:shape('eyes_narrow',0);shape('eyes_happy',.9)
  return True
 return False

def after_pose(name,u):
 """Over the shared clips: Tetsu never squashes, and its display moments are whole frames."""
 for b in m_rig().pose.bones:b.scale=(1,1,1)
def m_rig():
 import motion_v2 as m
 return m.rig

# ---------------------------------------------------------------- servo motion
# Clips Tetsu plays as authored (sampled by phase for travel, or held loops and the standing pose library): only their
# squash is taken out. Every other clip moves like a servo.
SERVO_EXEMPT={'hop_cycle','walk_cycle','hop_start','hop_stop','hop_turn','stand_poses','sleep_loop','idle_breathe','build_hammer','tea_sit','carry_lantern','disappointed_hold','annoyed_hold'}
SEGMENT=.36;MOVE=.58;FREQ=5.2;DAMP=.52
def servo(name,samples,loop,fps=24):
 """Quick moves with a tiny overshoot and settle: the clip's own motion, played in steps (each `SEGMENT` seconds of it
 happens in the first `MOVE` of that time, then holds), through an underdamped spring (`FREQ` Hz, damping `DAMP`).
 The last 0.25 s lands exactly on the authored end, so a clip still hands over to the idle pose seamlessly.
 samples: per frame, {bone: (location, rotation_euler, scale)} plus '__keys' (face weights, left as authored)."""
 for f in samples:
  for k,v in f.items():
   if k!='__keys':f[k]=(v[0],v[1],(1.0,1.0,1.0))
 if name in SERVO_EXEMPT or loop or len(samples)<6:return samples
 n=len(samples);T=(n-1)/fps;segs=max(1,round(T/SEGMENT));seg=T/segs
 def warp(t):
  k=min(segs-1,int(t/seg));a=k*seg;x=min(1,(t-a)/(seg*MOVE));x=x*x*x*(x*(x*6-15)+10);return a+seg*x
 def value(bone,ch,i,t):
  x=t*fps;j=min(n-2,int(x));f=x-j;return samples[j][bone][ch][i]*(1-f)+samples[j+1][bone][ch][i]*f
 bones=[k for k in samples[0] if k!='__keys'];w=2*math.pi*FREQ;sub=12;dt=1/fps/sub
 out=[{k:(list(v[0]),list(v[1]),v[2]) if k!='__keys' else v for k,v in f.items()} for f in samples]
 for bone in bones:
  for ch in (0,1):
   for i in range(3):
    if max(abs(f[bone][ch][i]-samples[0][bone][ch][i]) for f in samples)<1e-6:continue
    y=samples[0][bone][ch][i];vel=0.0
    for fi in range(n):
     t=fi/fps
     if fi>0:
      for s in range(sub):
       ts=t-1/fps+(s+1)*dt;target=value(bone,ch,i,warp(min(T,ts)))
       acc=w*w*(target-y)-2*DAMP*w*vel;vel+=acc*dt;y+=vel*dt
     land=min(1,max(0,(t-(T-.25))/.25));land=land*land*(3-2*land)
     out[fi][bone][ch][i]=y*(1-land)+samples[fi][bone][ch][i]*land
 return [{k:(tuple(v[0]),tuple(v[1]),v[2]) if k!='__keys' else v for k,v in f.items()} for f in out]

# ---------------------------------------------------------------- water: recharging with a small battery cell
BATTERY=1.25  # the cell's scale: big enough to read in the mittens at 100 px
def drink_prop(P,rig):
 """The battery cell Tetsu holds while it recharges (character/tetsu/battery_cell.usdz), between the mittens."""
 from shapes import lathe,rounded_box
 gun=bpy.data.materials['Tetsu gunmetal'];panel=bpy.data.materials['Tetsu chest panel'];led=bpy.data.materials['Tetsu LED']
 k=BATTERY
 parts=[lathe('BatteryBody',(0,0,.006*k),(0,0,.068*k),[(0,0),(.001,.026*k),(.05,.028*k),(.95,.028*k),(.999,.026*k),(1,0)],panel,24),
  lathe('BatteryBase',(0,0,0),(0,0,.010*k),[(0,0),(.01,.027*k),(1,.028*k),(1,0)],gun,24),
  lathe('BatteryCap',(0,0,.064*k),(0,0,.074*k),[(0,0),(0,.027*k),(.9,.026*k),(1,0)],gun,24),
  lathe('BatteryTerminal',(0,0,.073*k),(0,0,.082*k),[(0,0),(0,.009*k),(1,.008*k),(1,0)],gun,16)]
 for i,z in enumerate([.020,.035,.050]):parts.append(rounded_box(f'BatteryCell{i}',(0,-.0262*k,z*k),(.013*k,.003*k,.0055*k),4,led,4))
 path=P.dir/'battery_cell.usdz'
 export(path,parts)
 # Between the mittens, its middle level with theirs.
 bpy.context.view_layer.update()
 return parts,'battery_cell.usdz',tuple(held_anchor(rig,.082*BATTERY))
