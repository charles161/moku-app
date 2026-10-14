"""Instanced craft home, progress blueprint and one-tree-per-focused-hour forest."""
import sys,math,json,random
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from common import *
from mathutils import Matrix,Quaternion
OUT=ROOT/'world/kit';OUT.mkdir(exist_ok=True);PRE=ROOT/'previews/world-v2';PRE.mkdir(exist_ok=True)
reset();rng=random.Random(24)
M={}
for name,color in {'moss':(.20,.31,.12),'cork':(.28,.16,.08),'walnut':(.22,.105,.044),'birch':(.79,.75,.60),'plank':(.55,.33,.15),'slate':(.32,.38,.35),'roof':(.18,.32,.29),'paper':(.92,.84,.65),'ink':(.07,.24,.30),'sage':(.20,.36,.17),'pine':(.075,.22,.14),'blossom':(.77,.43,.43),'maple':(.69,.25,.075),'leafLight':(.38,.48,.20),'amber':(.93,.58,.18),'petal':(.92,.70,.40)}.items():
 M[name]=mat('Craft '+name,color,.92)
 if name in ['moss','roof','sage','pine','blossom','maple','leafLight']:
  p=M[name].node_tree.nodes.get('Principled BSDF');p.inputs['Sheen Weight'].default_value=.35
  tex=M[name].node_tree.nodes.new('ShaderNodeTexImage');tex.image=bpy.data.images.load(str(ROOT/'character/plush_normal.png'),check_existing=True);tex.image.colorspace_settings.name='Non-Color'
  normal=M[name].node_tree.nodes.new('ShaderNodeNormalMap');normal.inputs['Strength'].default_value=.23
  M[name].node_tree.links.new(tex.outputs['Color'],normal.inputs['Color']);M[name].node_tree.links.new(normal.outputs['Normal'],p.inputs['Normal'])
prototypes={};assets=[]
def box(name,loc,scale,m,bevel=.06):
 bpy.ops.mesh.primitive_cube_add(size=1,location=loc);o=bpy.context.object;o.scale=scale;bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
 mod=o.modifiers.new('Hand softened edges','BEVEL');mod.width=min(scale)*bevel;mod.segments=2;bpy.ops.object.modifier_apply(modifier=mod.name)
 return finish(o,name,M[m])
def save(name,objects):
 select(objects);bpy.ops.object.join();o=bpy.context.object;o.name=name
 bpy.context.scene.cursor.location=(0,0,0);bpy.ops.object.origin_set(type='ORIGIN_CURSOR');bpy.ops.object.transform_apply(location=False,rotation=True,scale=True)
 export(OUT/(name+'.usdz'),[o]);count=triangles([o]);assert count<6000,(name,count)
 prototypes[name]=o;assets.append({'name':name,'file':'kit/'+name+'.usdz','triangles':count,'pivot':'center' if name.startswith('unit_') and name not in ['unit_flower','unit_carrot'] else 'ground'})
 o.hide_render=True;o.hide_set(True);return o
for name,m in [('unit_stake','walnut'),('unit_beam','walnut'),('unit_plank','plank'),('unit_shingle','roof'),('unit_picket','paper'),('unit_loft_board','plank')]:save(name,[box(name,(0,0,0),(1,1,1),m)])
save('unit_stone',[sphere('stone',(0,0,0),(.5,.5,.5),M['slate'],12,8)])
save('unit_string',[cylinder('String',(0,0,0),.5,1,M['paper'],8)])
for i,scale in enumerate([(1,.72,.22),(.78,1,.26),(1,.9,.18)]):
 o=sphere('return stone',(0,0,.03),tuple(x*.5 for x in scale),M['slate'],12,8);save('path_stone_'+str(i+1),[o])
# Tree prototypes have two to four felt volumes, broad readable silhouettes and low triangle counts.
for species in ['round_felt','pine','birch','blossom','autumn_maple','sapling']:
 p=[];trunkMat='birch' if species=='birch' else 'walnut';h=.86 if species!='sapling' else .42
 p.append(cylinder('trunk',(0,0,h*.34),.043 if species!='sapling' else .022,h*.68,M[trunkMat],10))
 if species=='pine':
  for j in range(3):
   bpy.ops.mesh.primitive_cone_add(vertices=16,radius1=.35-j*.074,radius2=.055,depth=.42,location=(0,0,.47+j*.23));p.append(finish(bpy.context.object,'felt pine tier',M['pine']))
 elif species=='sapling':
  for s in [-1,1]:p.append(sphere('leaf',(s*.095,0,.33+(.06 if s==1 else 0)),(.12,.055,.073),M['sage'],12,8))
 elif species=='birch':
  for j in range(3):
   p.append(sphere('oval wool canopy',((j-1)*.15,0,.77+(.12 if j==1 else 0)),(.19,.19,.33),M['leafLight' if j==1 else 'sage'],12,8))
  for j in range(5):p.append(box('bark stitch',(.015,-.041,.10+j*.09),(.044,.004,.011),'walnut'))
 else:
  col={'round_felt':'sage','blossom':'blossom','autumn_maple':'maple'}[species]
  for j,(x,y,z,r) in enumerate([(-.16,0,.69,.26),(.16,.02,.73,.27),(0,-.08,.88,.29)]):p.append(sphere('felt crown',(x,y,z),(r,r*.87,r*.91),M[col if j!=2 or species!='round_felt' else 'leafLight'],14,9))
  if species=='blossom':
   for j in range(8):
    a=j*2.399;p.append(sphere('embroidered blossom',(.24*math.cos(a),.20*math.sin(a),.86+(j%3)*.07),(.035,.025,.026),M['paper'],8,5))
 save('tree_'+species,p)
# Small garden units alternate wool blooms and carrot leaves.
p=[cylinder('stem',(0,0,.075),.008,.15,M['sage'],8)]
for i in range(5):
 a=i*2*math.pi/5;p.append(sphere('petal',(.037*math.cos(a),.037*math.sin(a),.16),(.031,.028,.015),M['petal'],8,5))
p.append(sphere('center',(0,0,.17),(.022,.022,.017),M['amber'],8,5));save('unit_flower',p)
p=[sphere('carrot',(0,0,.025),(.033,.031,.04),M['maple'],10,6)]
for s in [-1,1]:p.append(sphere('carrot leaf',(s*.023,0,.085),(.02,.015,.055),M['sage'],8,5))
save('unit_carrot',p)
# Board is freestanding; the paper face receives a separate project texture.
p=[box('board',(0,0,.68),(.92,.065,.71),'walnut')]
for x in [-.29,.29]:p.append(box('leg',(x,.02,.33),(.052,.075,.66),'walnut'))
p.append(box('brace',(0,.22,.23),(.055,.08,.46),'walnut'));p[-1].rotation_euler.x=-.5
save('blueprint_board',p)
# Tent remains on the plot until the roof is completed.
p=[]
for sign in [-1,1]:
 o=box('cotton tent side',(sign*.18,0,.25),(.50,.62,.025),'paper');o.rotation_euler.y=sign*math.radians(48);p.append(o)
p.append(box('tent bed',(0,0,.04),(.56,.67,.065),'roof'));save('tent',p)
# Round door, paper-backed window, chimney, garden bench and telescope finales.
p=[cylinder('round door',(0,-.065,.33),.33,.06,M['roof'],24)];p[0].rotation_euler.x=math.pi/2
p.append(box('door frame backing',(0,0,.525),(.72,.055,1.05),'plank'))
for x in [-.15,0,.15]:p.append(box('door seam',(x,-.10,.33),(.006,.003,.54),'walnut'))
p.append(sphere('door knob',(.18,-.12,.34),(.025,.023,.025),M['amber'],10,6));save('door',p)
p=[cylinder('window rim',(0,0,0),.19,.06,M['walnut'],24),cylinder('window glass',(0,-.036,0),.155,.015,M['amber'],24)]
for o in p:o.rotation_euler.x=math.pi/2
p+=[box('cross',(0,-.05,0),(.023,.015,.31),'paper'),box('cross',(0,-.05,0),(.31,.015,.023),'paper')];save('window',p)
p=[]
for y in [-.66,.66]:
 me=bpy.data.meshes.new('gable');me.from_pydata([(-.92,y,1.36),(0,y,1.94),(.92,y,1.36)],[],[(0,1,2)]);me.update();o=bpy.data.objects.new('gable',me);bpy.context.collection.objects.link(o);p.append(finish(o,'gable',M['plank']))
save('gables',p)
save('chimney',[box('chimney',(0,0,.22),(.24,.25,.44),'slate'),box('cap',(0,0,.44),(.29,.30,.07),'slate')])
p=[box('seat',(0,0,.20),(.55,.20,.055),'plank'),box('back',(0,.09,.34),(.55,.045,.19),'plank')]
for x in [-.21,.21]:p.append(box('bench leg',(x,0,.095),(.05,.14,.19),'walnut'))
save('bench',p)
p=[cylinder('scope',(0,0,.49),.07,.35,M['walnut'],16)];p[0].rotation_euler.x=.9
for x,y in [(-.13,-.1),(.13,-.1),(0,.15)]:p.append(link_between('tripod',(x,y,0),(0,0,.4),.015,M['walnut']))
save('telescope',p)
# Shared cork island and reusable site furniture.
p=[sphere('cork island',(0,0,-.26),(5.8,5.8,.34),M['cork'],48,20),sphere('felt moss',(0,0,.005),(5.83,5.83,.085),M['moss'],48,20)]
for i in range(22):
 a=i*math.pi*2/22;p.append(sphere('moss edge scallop',(5.69*math.cos(a),5.69*math.sin(a),-.005),(.19,.19,.07),M['moss'],8,5))
save('island',p)
# Small permanent site dressing remains separate from progress units and trees.
p=[]
for x,y in [(-1.9,-.2),(1.5,-1.4),(-1.55,1.35),(1.9,.6)]:
 p.append(sphere('moss tuft',(x,y,.105),(.16,.12,.06),M['sage'],10,6))
 for j in range(3):p.append(sphere('felt grass',(x+(j-1)*.045,y,.16+j*.009),(.017,.023,.08),M['leafLight'],8,5))
for x,y in [(-1.65,-.5),(-1.75,-.42),(.95,1.55)]:
 p.append(cylinder('mushroom stem',(x,y,.13),.017,.10,M['paper'],8));p.append(sphere('mushroom cap',(x,y,.19),(.07,.06,.025),M['maple'],10,6))
save('site_dressing',p)
p=[]
for x in [-1.13,1.13]:
 for y in [-.82,.82]:p.append(box('scaffold upright',(x,y,.72),(.045,.045,1.44),'walnut'))
 for z in [.46,.98]:p.append(box('scaffold plank',(x,0,z),(.27,1.86,.055),'plank'))
save('scaffolding',p)
p=[box('crane foot',(0,0,.055),(.55,.45,.11),'walnut'),box('crane mast',(0,0,.75),(.07,.07,1.5),'walnut'),box('crane arm',(.25,0,1.50),(.75,.07,.075),'plank')]
p.append(cylinder('rope',(.58,0,1.10),.012,.76,M['paper'],8));p.append(sphere('bucket',(.58,0,.70),(.10,.10,.10),M['walnut'],12,8));save('hand_crane',p)
p=[box('barrow tray',(0,0,.22),(.35,.46,.07),'plank')]
for x in [-.14,.14]:p.append(box('barrow handle',(x,.25,.17),(.035,.47,.035),'walnut'))
p.append(cylinder('wheel',(0,-.24,.09),.09,.08,M['slate'],12));p[-1].rotation_euler.y=math.pi/2
save('wheelbarrow',p)
# House project placements. Runtime scales go on a wrapper around the imported root.
C=Matrix.Rotation(-math.pi/2,4,'X');projects=[]
def slot(asset,loc,scale=(1,1,1),rotation=(0,0,0),**extra):
 from mathutils import Euler
 q=(C @ Euler(rotation).to_matrix().to_4x4() @ C.inverted()).to_quaternion()
 return {'asset':asset,'translation':[round(loc[0],6),round(loc[2],6),round(-loc[1],6)],'scale':[scale[0],scale[2],scale[1]],'rotationQuaternion':[q.x,q.y,q.z,q.w],**extra}
def beam(a,b,width=.09):
 a,b=Vector(a),Vector(b);q=(b-a).to_track_quat('Z','Y');return slot('unit_beam',(a+b)/2,(width,width,(b-a).length),q.to_euler())
def project(i,name,start,count,units,finale):
 assert len(units)==count,(name,len(units),count)
 for j,u in enumerate(units):u['index']=j;u['id']=f'{name}_{j:03d}'
 projects.append({'index':i,'id':name,'startPoints':start,'pointsPerUnit':10,'unitCount':count,'slots':units,'finale':finale,'blueprint':{'paper':'blueprints/'+name+'_paper.png','pending':'blueprints/'+name+'_pending.png','inked':'blueprints/'+name+'_inked.png','unitLines':'blueprints/'+name+'.json'}})
project(0,'plot',0,3,[slot('unit_stake',(-1,-.75,.20),(.055,.055,.40)),slot('unit_stake',(1,-.75,.20),(.055,.055,.40)),slot('unit_string',(0,-.75,.31),(.012,.012,2),(0,math.pi/2,0))],[])
units=[]
for j in range(9):
 x=-.82+(j%3)*.82;y=-.55+(j//3)*.55;units.append(slot('unit_stone',(x,y,.17),(.70,.43,.24)))
project(1,'foundation',30,9,units,[slot('path_stone_1',(0,-.94,.12),(.85,.55,1))])
units=[]
for x in [-.9,.9]:
 for y in [-.63,.63]:units.append(beam((x,y,.26),(x,y,1.36)))
for z in [.33,1.36]:
 for y in [-.63,.63]:units.append(beam((-.9,y,z),(.9,y,z)))
 for x in [-.9,.9]:units.append(beam((x,-.63,z),(x,.63,z)))
for y in [-.63,.63]:
 units+=[beam((-.98,y,1.36),(0,y,1.97)),beam((0,y,1.97),(.98,y,1.36))]
units+=[beam((0,-.76,1.97),(0,.76,1.97)),beam((-.86,.63,.35),(.86,.63,1.3),.06)]
project(2,'frame',120,18,units,[])
units=[]
for j in range(10):units.append(slot('unit_plank',(-.82+j*.182,.66,.83),(.176,.075,1.05)))
for side in [-1,1]:
 for j in range(7):units.append(slot('unit_plank',(side*.93,-.55+j*.183,.83),(.075,.177,1.05)))
for x in [-.82,-.63,-.44,.44,.63,.82]:units.append(slot('unit_plank',(x,-.66,.83),(.18,.075,1.05)))
project(3,'walls',300,30,units,[slot('door',(0,-.72,.28)),slot('window',(-.64,-.72,1.06),(.7,.7,.7)),slot('gables',(0,0,0))])
units=[]
for side in [-1,1]:
 for row in range(5):
  x=side*(1.03-row*.215);z=1.36+(1.03-abs(x))*.62
  for j in range(9):units.append(slot('unit_shingle',(x,-.76+j*.19,z),(.26,.22,.035),(0,side*math.atan(.62),0)))
project(4,'roof',600,90,units,[slot('chimney',(.52,.30,1.69),(.8,.8,.8))])
units=[]
for j in range(90):
 a=2*math.pi*j/90;x=1.48*math.cos(a);y=1.12*math.sin(a)
 # Front opening remains clear; tiny alternating garden crafts fill the sides/back.
 if abs(x)<.48 and y<0:y=.95
 units.append(slot('unit_picket',(x,y,.26),(.028,.045,.34),(0,0,a)))
for j in range(160):
 side=-1 if j%2 else 1;k=j//2;x=side*(1.24+(k%5)*.10);y=-.60+(k//5)*.085
 units.append(slot('unit_carrot' if j%3 else 'unit_flower',(x,y,.09),(.8,.8,.8)))
project(5,'garden',1500,250,units,[slot('bench',(-1.18,-.94,.10),(.8,.8,.8))])
units=[]
# 600 small craft units: a 28x18 loft deck, 72 rail pegs and 24 ladder rungs.
for j in range(504):units.append(slot('unit_loft_board',(-.70+(j%28)*.052,1.13+(j//28)*.043,1.38),(.048,.038,.04)))
for j in range(72):
 a=2*math.pi*j/72;units.append(slot('unit_picket',(.75*math.cos(a),1.5+.43*math.sin(a),1.56),(.018,.022,.33)))
for j in range(24):units.append(slot('unit_beam',(.85,1.0+j*.018,.14+j*.052),(.35,.03,.027)))
project(6,'lookout',4000,600,units,[slot('telescope',(0,1.5,1.40))])
projects[-1]['structuralBase']=[beam((x,y,.09),(x,y,1.38),.07) for x in [-.65,.65] for y in [1.15,1.80]]
# 200 ordered trees: concentric rings, front sightline kept open, angularly balanced prefixes.
trees=[];species=['round_felt','pine','birch','blossom','autumn_maple','sapling']
for ring,(radius,count) in enumerate([(2.13,18),(2.85,28),(3.60,40),(4.35,50),(5.1,64)]):
 candidates=[]
 for j in range(count):
  # Leave a 76-degree wedge aimed toward the front camera free of foliage.
  a=math.radians(-52)+j/(count-1)*math.radians(284)
  candidates.append((radius*math.cos(a),radius*math.sin(a)))
 # Farthest-point angular sequence balances 1/5/20 tree compositions.
 order=[];remaining=list(range(count));k=count//2
 while remaining:
  if not order:k=count//2
  else:k=max(remaining,key=lambda j:min(min(abs(j-o),count-abs(j-o)) for o in order))
  order.append(k);remaining.remove(k)
 for j in order:
  x,y=candidates[j];idx=len(trees);scale=.72+(.12*(idx%4));asset='tree_'+species[(idx*5+ring)%6]
  trees.append(slot(asset,(x,y,.09),(scale,scale,scale),(0,0,idx*2.399),index=idx,ring=ring,focusHoursRequired=idx+1))
assert len(trees)==200
paths=[]
for i in range(200):
 if i<30:
  u=i/29;x=.13*math.sin(u*math.pi*3);y=-.95-u*3.8
 else:
  u=(i-30)/169;a=-math.pi/2+u*math.pi*3.3;r=1.8+u*3.3;x=r*math.cos(a);y=r*math.sin(a)
 paths.append(slot('path_stone_'+str(i%3+1),(x,y,.09),(.18,.14,.18),(0,0,i*.71),index=i))
# Legacy stages remain readable by existing importers; v2 scene uses kit/projects fields.
legacy=json.loads((ROOT/'world/layouts.json').read_text())
legacyStages=legacy.get('legacyStages',legacy['stages'])
layout={'schemaVersion':2,'upAxis':'Y','forward':'+Z','units':'meters','strategy':'instancedProjectUnitsAndOrderedTrees','stages':legacyStages,'legacyStages':legacyStages,'projects':projects,'kit':assets,'treeSlots':trees,'pathSlots':paths,'treeRule':{'focusedHoursPerTree':1,'count':'floor(focusMinutesAllTime / 60)','maxVisibleSlots':200,'overflow':'Retain total count; cap instanced forest at 200.','fillOrder':'ascending index; nearest ring first'},'blueprintAnchor':slot('blueprint_board',(-1.40,-1.13,.10),(.95,.95,.95),(0,0,-.12)),'characterAnchor':[.75,.10,1.3],'tentAnchor':slot('tent',(1.32,.30,.10),(.8,.8,.8)),'groundY':.09,'islandAsset':'island','siteProps':[slot('wheelbarrow',(1.18,-1.0,.09)),slot('hand_crane',(1.72,.60,.09))],'scaffoldingAsset':'scaffolding','previewHours':[0,3,25,120],'placement':'Place wrapper in Y-up coordinates; import USDZ as child retaining its authored root conversion. Each prototype is shared; reuse ModelComponent/mesh/material resources.','progress':'stage is highest startPoints <= focusMinutesAllTime (+ return growth points if supplied); completed=min(unitCount,floor((points-startPoints)/10)). Earlier projects complete. Show next 3 ghosts only.','boardScreenMinimumWidthPt':96}
(ROOT/'world/layouts.json').write_text(json.dumps(layout,indent=2)+'\n')
(ROOT/'world/kit/materials.json').write_text(json.dumps({'materials':[{'name':m.name,'baseTint':list(m.node_tree.nodes.get('Principled BSDF').inputs['Base Color'].default_value),'roughness':.92,'normalMapPath':'character/plush_normal.png' if name in ['moss','roof','sage','pine','blossom','maple','leafLight'] else None,'normalScale':.23,'normalTiling':[1,1],'sheenColor':[c*.35 for c in m.node_tree.nodes.get('Principled BSDF').inputs['Base Color'].default_value[:3]] if name in ['moss','roof','sage','pine','blossom','maple','leafLight'] else [0,0,0],'sheenRoughness':.85} for name,m in M.items()]},indent=2)+'\n')
# Store prototypes for composing reviews without rebuilding USDZs.
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'src/world_v2.blend'))
print('WORLD_V2_KIT',len(assets),'prototypes',sum(a['triangles'] for a in assets),'triangles; projects',sum(p['unitCount'] for p in projects),'treeSlots',len(trees))
