"""Seated, toy-scale bunny animation. All distances are meters, angles degrees.
Motion is sampled at 24 Hz; no runtime procedural dependency.
"""
import math,json
from common import *
from companion import paths,species
# The companion being animated (--companion=<id>, Moku by default): its moods, ear paths and signature moves.
P=paths();SP=species()
MOODS=SP.moods()
rig=None;mesh=None
EAR_PATHS=json.loads((P.dir/'ear_transitions.json').read_text())
def bind(r,m):
 global rig,mesh
 rig=r;mesh=m
 for b in rig.pose.bones:b.rotation_mode='XYZ'
def neutral():
 for b in rig.pose.bones:b.location=(0,0,0);b.rotation_euler=(0,0,0);b.scale=(1,1,1)
 for k in mesh.data.shape_keys.key_blocks:k.value=0

def mood(name):
 weights,joints,_=MOODS[name]
 for k in mesh.data.shape_keys.key_blocks:k.value=0
 for k,v in weights.items():shape(k,v)
 for k,v in joints.items():rot(k,*v,raw=True)

def smooth(x):x=max(0,min(1,x));return x*x*(3-2*x)
def pulse(t,a,b,c):return smooth((t-a)/(b-a))*(1-smooth((t-b)/(c-b))) if a<t<c else 0
def envelope(u):return math.sin(math.pi*u)**2

def rot(j,x=0,y=0,z=0,raw=False):
 rig.pose.bones[j].rotation_euler=[math.radians(a) for a in (x,y,z if raw or not j.startswith(('arm_','hand_')) else -z)]
def shape(k,v):mesh.data.shape_keys.key_blocks[k].value=max(0,min(1,v))
def app_euler(degrees):
 """Blender XYZ degrees for the turn the app gives a mood's angles (x, then y, then z about the joint's own axes)."""
 from mathutils import Quaternion
 q=Quaternion((1,0,0),math.radians(degrees[0]))@Quaternion((0,1,0),math.radians(degrees[1]))@Quaternion((0,0,1),math.radians(degrees[2]))
 return [math.degrees(a) for a in q.to_euler('XYZ')]
def ear_lift(v,target='ears_lift'):
 for k in EAR_PATHS['clearControls']:shape(k,0)
 steps=next(p['keyposes'] for p in EAR_PATHS['paths'] if p['target']==target)
 segments=len(steps)-1;f=max(0,min(1,v))*segments;i=min(segments-1,int(f));t=f-i
 for key,w in steps[i]['blendShapes'].items():shape(key,w*(1-t))
 for key,w in steps[i+1]['blendShapes'].items():shape(key,w*t)
def arm(side,direction,v=1):
 bone=rig.data.bones['arm_'+side];r=bone.matrix_local.to_quaternion()
 world=(bone.tail_local-bone.head_local).rotation_difference(Vector(direction))
 from mathutils import Quaternion
 q=Quaternion().slerp(r.inverted() @ world @ r,max(0,min(1,v)))
 rig.pose.bones['arm_'+side].rotation_euler=q.to_euler('XYZ')
def smiling(v,opened=False):
 shape('blink_L',.18*(1-v));shape('blink_R',.18*(1-v));shape('eyes_happy',v)
 shape('cheeks_raise',v);shape('blush_more',v);ear_lift(v)
 shape('smile',.3*(1-v) if opened else .3+.7*v)
 if opened:shape('mouth_smile_open',v)
def tall(v):
 # Haunches/feet remain planted. Only upper torso lengthens, paws reach forward.
 rig.pose.bones['spine'].scale.y=1+.09*v
 rot('chest',x=-5*v);rot('head',x=-5*v)
 for side,sign in [('L',1),('R',-1)]:arm(side,(sign*.07,-.20,-.01),v)
 ear_lift(.82*v)
def standing(v):tall(v) # compatibility for the retired lantern pose

def upright_hands():
 bpy.context.view_layer.update()
 for side in ['L','R']:
  hand=rig.data.bones['hand_'+side];parent=rig.data.bones['arm_'+side]
  localRest=(parent.matrix_local.inverted() @ hand.matrix_local).to_quaternion()
  currentParent=rig.pose.bones['arm_'+side].matrix.to_quaternion()
  rig.pose.bones['hand_'+side].rotation_euler=((currentParent @ localRest).inverted() @ hand.matrix_local.to_quaternion()).to_euler('XYZ')

def hop_motion(u,amplitude=.085,reach=1):
 crouch=pulse(u,0,.16,.30);push=pulse(u,.16,.29,.40)
 flight=math.sin(math.pi*(u-.29)/.43) if .29<u<.72 else 0
 land=pulse(u,.69,.78,1)
 rig.pose.bones['root'].location.y=amplitude*flight
 rig.pose.bones['spine'].scale=(1+.025*crouch+.025*land,1-.10*crouch+.055*push-.075*land,1+.015*crouch)
 rot('head',x=5*crouch-4*push+4*land)
 for side,sign in [('L',1),('R',-1)]:
  arm(side,(sign*.075,-.23,-.025),reach*max(push,flight*.7))
  # Both hind feet tuck together during flight; never alternate like human steps.
  rot('leg_'+side,x=-7*flight);rot('foot_'+side,x=7*flight)
  rot('ear_'+side+'_02',x=(-7*push+8*land)*(1 if side=='L' else .7))
 rot('tail',x=12*push-8*land)
 return flight

def aim(bone,direction,v=1):
 from mathutils import Quaternion
 b=rig.data.bones[bone];r=b.matrix_local.to_quaternion()
 world=(b.tail_local-b.head_local).rotation_difference(Vector(direction))
 rig.pose.bones[bone].rotation_euler=Quaternion().slerp(r.inverted() @ world @ r,max(0,min(1,v))).to_euler('XYZ')
def lowest(prefixes):
 bpy.context.view_layer.update()
 dg=bpy.context.evaluated_depsgraph_get();ev=mesh.evaluated_get(dg);me=ev.to_mesh()
 groups={g.index:g.name for g in mesh.vertex_groups};low=None
 for v in me.vertices:
  if any(groups.get(g.group,'').startswith(prefixes) for g in mesh.data.vertices[v.index].groups):
   z=(ev.matrix_world @ v.co).z;low=z if low is None else min(low,z)
 ev.to_mesh_clear();return low
def stand_base(s):
 """Standing on the hind feet, with no mood: s 0 is the seated rest, 1 fully up. Cute rather than tall
 (Charles: "while standing its not cute"): knees bent so it stays low and round, feet pigeon-toed with the
 pink pads showing, chest puffed a touch, a sassy head tilt, the body a little squashed. The whole body
 rises just enough that the feet stay planted at every s (nothing ever dips below the ground)."""
 from mathutils import Quaternion
 for side,sign in [('L',1),('R',-1)]:aim('leg_'+side,(sign*.08,-1.2,-1),s)
 bpy.context.view_layer.update()
 for side,sign in [('L',1),('R',-1)]:
  foot=rig.data.bones['foot_'+side];leg=rig.pose.bones['leg_'+side]
  turn=Quaternion((0,0,1),math.radians(sign*8*s)) @ Quaternion((1,0,0),math.radians(40*s))
  localRest=(rig.data.bones['leg_'+side].matrix_local.inverted() @ foot.matrix_local).to_quaternion()
  rig.pose.bones['foot_'+side].rotation_euler=((leg.matrix.to_quaternion() @ localRest).inverted() @ turn @ foot.matrix_local.to_quaternion()).to_euler('XYZ')
 rot('chest',x=-6*s);rot('head',x=5*s,z=6*s)
 rig.pose.bones['spine'].scale=(1+.05*s,1-.06*s,1+.05*s)
 rig.pose.bones['root'].location.y=0
 rig.pose.bones['root'].location.y=-min(lowest(('part_foot','part_pad')),lowest(('part_body','part_tail')))

# The drink (drink_water): 12 s, three sips starting at these seconds; a sip tips the cup this many degrees.
DRINK_SECONDS=12;DRINK_SIPS=[2.45,4.75,7.05];DRINK_TIP=-26

def pose(name,t,duration):
 aliases={'walk_cycle':'hop_cycle','stand_up':'sit_up_tall','sit_down':'settle_down'}
 name=aliases.get(name,name);neutral();u=max(0,min(1,t/duration))
 # A companion's signature moves replace the shared clip of the same name (Tetsu's boot-up is its hello_wave).
 custom=getattr(SP,'pose',None)
 if custom and custom(name,u,t,duration):bpy.context.view_layer.update();return
 if name=='stand_poses':
  # A pose library, not a performance: frame k is the standing base at s = k / 24. The app blends along it.
  stand_base(u);bpy.context.view_layer.update();return
 mood('content');e=envelope(u)
 # Secondary motion fades completely at seated endpoints.
 for side,sign in [('L',1),('R',-1)]:rot('ear_'+side+'_02',x=1.6*math.sin(2*math.pi*u)*e,z=sign*.8*math.sin(4*math.pi*u)*e)
 rot('tail',x=3*math.sin(2*math.pi*u)*e)
 if name=='idle_breathe':
  s=math.sin(2*math.pi*u);rig.pose.bones['spine'].scale=(1+.008*s,1+.013*s,1+.006*s);rot('head',x=.5*s)
  for side in ['L','R']:shape('blink_'+side,.18+.82*pulse(u,.65,.68,.73))
 elif name=='sit_settle':
  v=math.sin(3*math.pi*u)*math.exp(-5*u)*smooth(u*10)*(1-smooth((u-.8)/.2));rig.pose.bones['spine'].scale.y=1-.055*v;rot('head',x=4*v)
 elif name=='look_around':
  yaw=18*(pulse(u,.06,.26,.5)-pulse(u,.48,.72,.96));rot('head',x=-2*e,y=yaw,z=2*math.sin(2*math.pi*u)*e)
  rot('eye_L',z=-3*math.sin(2*math.pi*u)*e);rot('eye_R',z=-3*math.sin(2*math.pi*u)*e);shape('brows_up',.18*e)
 elif name in ['sit_up_tall','settle_down']:
  v=smooth((u-.10)/.72) if name=='sit_up_tall' else 1-smooth(u/.83);tall(v)
  anticipation=pulse(u,0,.09,.22) if name=='sit_up_tall' else pulse(u,.70,.84,1)
  rig.pose.bones['spine'].scale.y-=.035*anticipation;rot('head',x=-5*v+3*anticipation)
 elif name in ['hop_cycle','hop','hop_start','hop_stop','hop_turn']:
  hop_motion(u,.085 if name=='hop_cycle' else .065)
  if name=='hop_start':rot('chest',x=5*pulse(u,0,.20,.50))
  if name=='hop_stop':rot('chest',x=4*pulse(u,.64,.78,1))
  if name=='hop_turn':rot('root',y=30*smooth((u-.29)/.43))
 elif name in ['celebrate','big_celebrate','cheer']:
  v=pulse(u,.05,.42,.97);smiling(v,opened=True)
  if name!='cheer':
   count=2 if name=='big_celebrate' else 1
   phase=(u*count)%1 if u<1 else 1;flight=hop_motion(phase,.105 if count==2 else .070,.35)
  for side,sign in [('L',1),('R',-1)]:arm(side,(sign*.20,-.09,.09),v*.85)
  rot('head',x=-4*v,z=4*math.sin(2*math.pi*u)*v)
 elif name=='stretch':
  v=pulse(u,.05,.48,.96);rig.pose.bones['spine'].scale.y=1+.075*v
  for side,sign in [('L',1),('R',-1)]:arm(side,(sign*.15,-.12,.10),v)
  rot('head',x=-9*v);shape('eyes_happy',.85*v);shape('blink_L',.18*(1-v));shape('blink_R',.18*(1-v));ear_lift(.55*v)
 elif name=='drink_water':
  # Charles: "it should drink for at least 10-15 seconds ... improved a ton". Twelve seconds, a real drink:
  # the cup comes up to the lap, then to the mouth; three sips, each tipping the cup with the head back and
  # the eyes closed, a small gulp and a breath between them; then the cup comes down with a contented "ahh"
  # (happy eyes, a small smile, ears up, a little wiggle) and Moku settles back to rest. Everything eases.
  s=u*DRINK_SECONDS
  hold=smooth((s-.35)/.9)*(1-smooth((s-10.45)/1.2))       # paws out holding the cup
  atMouth=smooth((s-1.25)/1.1)*(1-smooth((s-9.3)/1.15))   # the cup at the mouth, not the lap
  sip=sum(pulse(s,a,a+.75,a+1.7) for a in DRINK_SIPS)     # tip the cup, head back
  gulp=sum(pulse(s,a+1.45,a+1.6,a+1.9) for a in DRINK_SIPS)
  breath=sum(pulse(s,a+1.85,a+2.1,a+2.3) for a in DRINK_SIPS[:-1])
  aah=pulse(s,9.35,10.05,11.6)
  for side,sign in [('L',1),('R',-1)]:
   lap,mouth=(-sign*.10,-.21,-.09),(-sign*.08,-.23,.015)
   up=[a+(b-a)*atMouth for a,b in zip(lap,mouth)];up[2]+=.07*sip  # a sip lifts the cup to the lips
   arm(side,up,hold)
  # Wrist counter-rotation keeps the cup upright; a sip tips it toward the mouth.
  upright_hands()
  for side in ['L','R']:rig.pose.bones['hand_'+side].rotation_euler.x+=math.radians(DRINK_TIP*sip)
  rot('head',x=7*hold*(1-atMouth)+3*atMouth-8*sip+2.5*gulp-5*aah,z=2.5*math.sin(2*math.pi*(s-9.9)/.7)*pulse(s,9.8,10.3,11.2))
  rot('chest',x=-2.5*sip-2*aah)
  rig.pose.bones['spine'].scale.y=1-.012*gulp+.014*breath+.01*aah
  lids=.18+.2*hold+.62*sip
  for side in ['L','R']:shape('blink_'+side,min(.95,lids)*(1-aah))
  shape('eyes_happy',.85*aah);shape('smile',.2+.45*aah);shape('cheeks_raise',.45*aah);shape('blush_more',.35*aah)
  shape('pout',.3*sip+.15*gulp);shape('cheeks_puff',.12*sip)
  ear_lift(.3*aah)
 elif name=='build_hammer':
  seconds=u*2.4
  lift=sum(pulse(seconds,start+.04,start+.23,start+.34) for start in [0,.55,1.10])
  follow=sum(pulse(seconds,start+.34,start+.39,start+.50) for start in [0,.55,1.10])
  arm('R',(-.10,-.19,-.07+.22*lift),.85)
  arm('L',(.04,-.17,-.12),.45);rot('head',x=5+2*follow-1.5*lift)
  rig.pose.bones['spine'].scale.y=1+.004*math.sin(2*math.pi*u)
  # Keep the mallet in front of the face as the elbow rises; the old wrist arc
  # swept its head into the cheek at each raised key.
  upright_hands()
  rot('ear_R_02',x=2.5*follow-1.5*lift);shape('brows_up',.12)
 elif name=='tea_sit':
  for side,sign in [('L',1),('R',-1)]:arm(side,(-sign*.08,-.23,-.035),.88)
  rig.pose.bones['spine'].scale.y=1+.006*math.sin(2*math.pi*u)
  upright_hands();rot('head',x=3+.4*math.sin(2*math.pi*u),z=-2)
  for side in ['L','R']:shape('blink_'+side,.18+.82*pulse(u,.64,.68,.74))
 elif name=='yawn':
  v=pulse(u,.02,.49,.98);rot('head',x=-8*v);arm('L',(-.02,-.18,.07),.8*v)
  shape('mouth_open',v)
  for side in ['L','R']:shape('blink_'+side,.18+.82*v)
  shape('brows_up',.2*v);rig.pose.bones['spine'].scale.y=1+.035*v
 elif name in ['wave','hello_wave']:
  v=pulse(u,.08,.30,.98);arm('L',(.24+.035*math.sin(6*math.pi*u),-.14,.12+.025*math.sin(6*math.pi*u)),v)
  rot('hand_L',z=12*math.sin(6*math.pi*u)*v);rot('head',z=-5*v);smiling(.7*v)
  if name=='hello_wave' and u<.22:hop_motion(u/.22,.045,.4)
 elif name=='nod':
  v=e;rot('head',x=(-3*pulse(u,0,.14,.25)+9*math.sin(2*math.pi*u)*e));smiling(.28*v)
 elif name=='sigh':
  v=pulse(u,.08,.46,.97);rot('head',x=8*v);rig.pose.bones['spine'].scale.y=1+.026*pulse(u,0,.20,.44)-.025*v
  for side in ['L','R']:shape('blink_'+side,.18+.46*v)
  shape('pout',.55*v)
 elif name=='pat_reaction':
  v=pulse(u,.03,.28,.97);rig.pose.bones['spine'].scale.y=1-.035*v;rot('head',x=-4*v,z=5*v);smiling(.7*v);shape('cheeks_puff',.25*v)
 elif name in ['fold_arms','unfold_arms','disappointed_hold','cross_arms','uncross_arms','annoyed_hold']:
  held='annoyed' if name in ['cross_arms','uncross_arms','annoyed_hold'] else 'disappointed'
  v=1 if name.endswith('_hold') else 1-smooth(u) if name.startswith(('unfold','uncross')) else smooth(u)
  weights,joints,_=MOODS[held]
  for k in set(weights)|set(MOODS['content'][0]):shape(k,MOODS['content'][0].get(k,0)+(weights.get(k,0)-MOODS['content'][0].get(k,0))*v)
  for k,degrees in joints.items():
   # The app holds a mood's joints as rest·Rx·Ry·Rz (RealityCharacter), Blender's XYZ Euler is Rz·Ry·Rx: these clips
   # end (and the releases start) on the turn the app holds, so nothing swings when one takes over from the other.
   start=MOODS['content'][1].get(k,[0,0,0]);rot(k,*[a+(b-a)*v for a,b in zip(start,app_euler(degrees))],raw=True)
  # No head shake. A quiet breath is the only held motion.
  if name.endswith('_hold'):rig.pose.bones['spine'].scale.y=1+.006*math.sin(2*math.pi*u)
  else:rig.pose.bones['chest'].rotation_euler.x+=math.radians(-1.5*pulse(u,0,.12,.26))
 elif name=='carry_lantern':
  tall(1);rot('arm_R',x=-45,z=35);rot('hand_R',x=10);rot('head',x=-3)
 elif name=='sleep_loop':
  mood('sleepy');s=math.sin(2*math.pi*u);rig.pose.bones['spine'].scale=(1+.007*s,1+.012*s,1+.006*s);rot('head',x=15+.6*s,z=12);shape('blink_L',1);shape('blink_R',1)
 # A companion's own secondary motion over the shared clips (a tail that keeps swishing).
 after=getattr(SP,'after_pose',None)
 if after:after(name,u)
 bpy.context.view_layer.update()

CLIPS=[('idle_breathe',4,True),('sit_settle',1.25,False),('look_around',3.5,False),('stand_up',1.2,False),('sit_down',1.2,False),('walk_cycle',13/24,True),('hop',1.1,False),('celebrate',1.8,False),('big_celebrate',3,False),('cheer',2.2,False),('stretch',3.2,False),('drink_water',DRINK_SECONDS,False),('yawn',3,False),('wave',2.2,False),('nod',1.3,False),('sigh',2.5,False),('pat_reaction',1.5,False),('sleep_loop',5,True),('fold_arms',.9,False),('unfold_arms',.8,False),('disappointed_hold',4,True),('cross_arms',.9,False),('uncross_arms',.8,False),('annoyed_hold',4,True),('carry_lantern',3,True),('hop_cycle',13/24,True),('hop_start',.75,False),('hop_stop',.75,False),('hop_turn',.75,False),('sit_up_tall',1.2,False),('settle_down',1.2,False),('hello_wave',3,False)]
ALIASES={'walk_cycle':'hop_cycle','stand_up':'sit_up_tall','sit_down':'settle_down'}
CLIPS += [('build_hammer',2.4,True),('tea_sit',4,True),('stand_poses',1,False)]
# Extra clips a companion adds under new names (a talent's own clip), listed in animations.json with extra: true.
CLIPS += getattr(SP,'EXTRA_CLIPS',[])
