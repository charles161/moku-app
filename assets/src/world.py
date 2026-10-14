import sys,math,random,json
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from common import *
NAMES=['seed','sprout','sapling','youngTree','tree','grove','forest','ancientForest']

def materials():
    global earth,moss,leaf,leaflight,leafdark,bark,slate,cream,coral,gold,glass,water,ceramic
    earth=mat('Warm earth',(.19,.10,.057),.94);moss=mat('Velvet moss',(.12,.25,.055),.96)
    leaf=mat('Sage leaf',(.08,.26,.095),.85);leaflight=mat('Sunlit leaf',(.24,.38,.12),.9);leafdark=mat('Pine shade',(.035,.13,.065),.88)
    bark=mat('Walnut bark',(.23,.12,.065),.92);slate=mat('River slate',(.30,.34,.31),.9)
    cream=mat('Daisy milk',(.95,.86,.63),.85);coral=mat('Mushroom coral',(.59,.21,.11),.8)
    gold=mat('Aged bronze',(.30,.16,.048),.38,.62);glass=mat('Amber glow',(1,.47,.095),.32,0,2.2)
    water=mat('Water surface',(.25,.43,.39),.13,.15);ceramic=mat('Sage ceramic',(.24,.36,.24),.4)

def group(name,objects,pivot=(0,0,0)):
    e=bpy.data.objects.new(name,None);bpy.context.collection.objects.link(e)
    e.location=pivot;bpy.context.view_layer.update()
    for o in objects:
        world=o.matrix_world.copy();o.parent=e;o.matrix_world=world
    return e

def leafshape(name,loc,length,width,material,rz=0,tilt=0):
    o=sphere(name,loc,(width,length,.028*length/.15),material,10,7);o.rotation_euler=(tilt,0,rz);return o

def lantern(loc=(0,0,0),scale=1,name='Lantern'):
    objs=[];x,y,z=loc;s=scale
    def cy(n,zz,r,d,m):
        o=cylinder(name+'_'+n,(x,y,z+zz*s),r*s,d*s,m,24);objs.append(o)
    cy('base',.014,.079,.028,gold);cy('glass',.101,.047,.148,glass);cy('cap',.192,.077,.023,gold)
    o=sphere(name+'_roof',(x,y,z+.207*s),(.068*s,.068*s,.035*s),gold,24,12);objs.append(o)
    for i in range(4):
        a=i*math.pi/2+math.pi/4;xx=x+.052*s*math.cos(a);yy=y+.052*s*math.sin(a)
        objs.append(link_between(name+'_rib'+str(i),(xx,yy,z+.028*s),(xx,yy,z+.18*s),.005*s,gold))
    objs.append(tube(name+'_handle',[(x-.035*s,y,z+.23*s),(x-.03*s,y,z+.285*s),(x+.03*s,y,z+.285*s),(x+.035*s,y,z+.23*s)],.006*s,gold,8))
    return objs

def cup():
    # Lathed hollow cup, solid rim; base anchor at zero.
    profile=[(0,0),(.045,0),(.058,.012),(.066,.10),(.065,.123),(.055,.126),(.055,.112),(.049,.021),(0,.021)]
    verts=[];faces=[];seg=40
    for r,z in profile:
        for i in range(seg):a=i*2*math.pi/seg;verts.append((r*math.cos(a),r*math.sin(a),z))
    for j in range(len(profile)-1):
        for i in range(seg):a=j*seg+i;b=j*seg+(i+1)%seg;faces.append((a,b,b+seg,a+seg))
    me=bpy.data.meshes.new('Cup');me.from_pydata(verts,[],faces);me.update();o=bpy.data.objects.new('WaterCup',me);bpy.context.collection.objects.link(o);finish(o,'WaterCup',ceramic)
    handle=tube('CupHandle',[(.054,0,.101),(.10,0,.105),(.103,0,.060),(.063,0,.044)],.011,ceramic,12)
    liquid=cylinder('Water',(0,0,.104),.054,.002,water,40)
    return [o,handle,liquid]

def seedling(level):
    objs=[]
    if level==0:
        o=sphere('Seed',(0,.12,.125),(.10,.06,.046),bark,24,14);o.rotation_euler.z=.4;objs.append(o)
        objs.append(tube('SeedSeam',[(-.085,.105,.133),(0,.095,.171),(.085,.142,.133)],.004,cream,8))
    else:
        height=.27 if level==1 else .52
        objs.append(tube('SproutStem',[(0,.12,.035),(-.015,.12,height*.52),(.0,.12,height)],.016 if level==1 else .020,leaf if level==1 else bark,8))
        for i in range(2 if level==1 else 4):
            side=1 if i%2==0 else -1;zz=height*(.73 if i<2 else .43)
            o=leafshape('SproutLeaf'+str(i),(side*.108,.12,zz),.15,.062,leaflight if i%2 else leaf,rz=side*1.12,tilt=side*.28);objs.append(o)
    return objs

def tree(name,loc,size,ancient=False,pine=False):
    x,y,z=loc;objs=[];r=random.Random(name)
    height=size;tr=.065*size*(1.7 if ancient else 1)
    trunk=tube(name+'_trunk',[(x,y,z),(x-.035*size,y,z+.30*size),(x+.035*size,y+.01*size,z+.67*size),(x,y,z+.88*size)],tr,bark,10);objs.append(trunk)
    for i in range(5):
        a=i*2*math.pi/5
        objs.append(tube(name+'_root'+str(i),[(x+math.cos(a)*.19*size,y+math.sin(a)*.19*size,z+.005),(x+math.cos(a)*.10*size,y+math.sin(a)*.10*size,z+.025),(x,y,z+.17*size)],tr*.42,bark,6))
    clusters=[]
    if pine:
        for k in range(4):
            zz=z+size*(.45+.17*k);rr=size*(.34-.064*k)
            # Rounded tier silhouette, not hard cone facets.
            for j in range(4):
                a=j*math.pi/2+k*.7;clusters.append((x+rr*.32*math.cos(a),y+rr*.32*math.sin(a),zz,rr*.78,rr*.7,rr*.67))
    else:
        for i in range(6 if ancient else 5):
            a=i*2*math.pi/(6 if ancient else 5);rr=.27*size
            bx=x+math.cos(a)*rr;by=y+math.sin(a)*rr;bz=z+size*(.73+.12*(i%2))
            objs.append(tube(name+'_branch'+str(i),[(x,y,z+.43*size),(x+(bx-x)*.6,y+(by-y)*.6,bz-.15*size),(bx,by,bz)],tr*.55,bark,7))
            clusters.append((bx,by,bz,.29*size,.25*size,.235*size))
        clusters.append((x,y,z+size,.30*size,.27*size,.22*size))
    for i,(cx,cy,cz,sx,sy,sz) in enumerate(clusters):
        m=[leaf,leaflight,leafdark][i%3 if pine else i%2]
        objs.append(sphere(name+'_crown'+str(i),(cx,cy,cz),(sx,sy,sz),m,12,8))
        # Broad overlapping leaf scales enrich the silhouette without particle geometry.
        for k in range(7 if not pine else 2):
            a=k*2.399+i;v=.25+.65*r.random();rad=math.sqrt(1-v*v)
            pos=(cx+sx*rad*math.cos(a),cy+sy*rad*math.sin(a),cz+sz*v)
            o=leafshape(name+f'_leaf{i}_{k}',pos,.058*size,.038*size,leaflight if k%3==0 else m,rz=a,tilt=.18);objs.append(o)
    if ancient:
        for i in range(3):
            a=3.5+i*1.15;hx=x+math.cos(a)*.4*size;hy=y+math.sin(a)*.4*size;hz=z+.75*size
            objs.append(tube(name+'_hangingCord'+str(i),[(hx,hy,hz+.08),(hx,hy,hz-.40)],.004,bark,4));objs.extend(lantern((hx,hy,hz-.53),.50,name+'_light'+str(i)))
    return objs

def island():
    objs=[];r=random.Random(4)
    # Rounded concentric strata, irregular rim and stable dressing across stages.
    for name,loc,scale,material in [('IslandEarth',(0,0,-.23),(.92,.73,.25),earth),('MossCap',(0,0,-.01),(.94,.74,.10),moss),('LowerStone',(.03,.015,-.39),(.66,.52,.20),slate)]:objs.append(sphere(name,loc,scale,material,40,22))
    for i in range(17):
        a=2*math.pi*i/17;xx=.80*math.cos(a);yy=.62*math.sin(a)
        objs.append(sphere('MossRim'+str(i),(xx,yy,-.018),(.18,.14,.07),moss if i%3 else leaflight,14,10))
    for i in range(10):
        a=2*math.pi*i/10+.2;xx=.77*math.cos(a);yy=.59*math.sin(a)
        o=sphere('Rock'+str(i),(xx,yy,-.10-r.random()*.07),(.11+r.random()*.06,.10,.09),slate,12,8);o.rotation_euler=(r.random()*.3,r.random()*.4,r.random());objs.append(o)
    for i in range(3):objs.append(sphere('PathStone'+str(i),(.11-i*.10,-.40-i*.07,.044),(.14,.085,.03),slate,16,10))
    for i in range(8):
        a=2*math.pi*i/8;xx=.67*math.cos(a);yy=.51*math.sin(a)
        # Grass is a tiny broad-leaf rosette, never hair/alpha cards.
        for j in range(3):
            o=leafshape(f'Grass{i}_{j}',(xx+(j-1)*.022,yy,.062+j*.01),.065,.017,leafdark if i%2 else leaflight,rz=a+j*.7,tilt=.9);objs.append(o)
    for i,(xx,yy) in enumerate([(-.6,-.2),(-.53,-.24),(.6,.18)]):
        zz=.055;objs.append(cylinder('MushroomStem'+str(i),(xx,yy,zz+.045),.017,.09,cream,12))
        objs.append(sphere('MushroomCap'+str(i),(xx,yy,zz+.09),(.068,.06,.035),coral,20,12))
        for j in range(3):a=j*2*math.pi/3;objs.append(sphere(f'MushroomSpot{i}_{j}',(xx+.032*math.cos(a),yy+.027*math.sin(a),zz+.12),(.010,.008,.003),cream,8,6))
    for i in range(5):
        xx=-.4+i*.17;yy=-.50+(i%2)*.06
        objs.append(cylinder('FlowerStem'+str(i),(xx,yy,.084),.005,.10,leafdark,8))
        for j in range(5):
            a=j*2*math.pi/5;objs.append(sphere(f'Flower{i}_{j}',(xx+.025*math.cos(a),yy+.025*math.sin(a),.136),(.019,.018,.009),cream,8,6))
        objs.append(sphere('FlowerCenter'+str(i),(xx,yy,.145),(.014,.014,.009),glass,10,6))
    return objs

if __name__=='__main__':
    reset();materials();props=cup();export(ROOT/'props/water_cup.usdz',props);count=triangles(props);studio(target=(0,0,.065),distance=.5,ortho=.24);render(ROOT/'previews/water_cup.png')
    reset();materials();props=lantern();export(ROOT/'props/lantern.usdz',props);lampcount=triangles(props);studio(target=(0,0,.145),distance=.8,ortho=.4);render(ROOT/'previews/lantern.png')
    records=[]
    for stage,name in enumerate(NAMES):
        reset();materials();random.seed(42);parts=island();groups=[]
        ground=group('island',parts);groups.append(ground)
        lamp=lantern((.51,-.27,.045),.85);parts+=lamp;groups.append(group('home_lantern',lamp,(.51,-.27,.045)))
        if stage<3:
            sprout=seedling(stage);parts+=sprout;groups.append(group('hero_growth',sprout,(0,.12,.035)))
        else:
            size=[0,0,0,.65,.92,1.02,1.07,1.24][stage]
            hero=tree('Hero',(0,.14,.045),size,ancient=stage==7);parts+=hero;groups.append(group('hero_growth',hero,(0,.14,.045)))
        if stage>=5:
            for i,pos in enumerate([(-.52,.12,.035),(.47,.29,.035)]):
                tr=tree('Companion'+str(i),pos,.54+(stage-5)*.075,pine=stage>=6);parts+=tr;groups.append(group('companion_'+str(i),tr,pos))
        if stage>=6:
            for i,pos in enumerate([(-.27,.48,.02),(.12,.51,.02)]):
                tr=tree('Backdrop'+str(i),pos,.62+(stage-6)*.06,pine=True);parts+=tr;groups.append(group('backdrop_'+str(i),tr,pos))
        file=f'stage_{stage}_{name}';count_stage=triangles(parts)
        if count_stage>56000:
            # Spend the budget on silhouette and hero props; reduce only tiny foliage details.
            foliage=[o for o in parts if '_crown' in o.name or '_leaf' in o.name]
            foliage_tri=triangles(foliage);ratio=max(.2,(55000-(count_stage-foliage_tri))/foliage_tri)
            for o in foliage:
                select([o]);mod=o.modifiers.new('Foliage runtime budget','DECIMATE');mod.ratio=ratio;bpy.ops.object.modifier_apply(modifier=mod.name)
            count_stage=triangles(parts)
        if count_stage>=60000:raise RuntimeError(f'{name} exceeds budget: {count_stage}')
        # One mesh per growth group keeps entity/draw submission overhead small.
        for root in groups:
            children=[o for o in list(root.children) if o.type=='MESH']
            if children:
                select(children);bpy.ops.object.join();bpy.context.object.name=root.name+'_mesh'
        parts=[o for o in bpy.context.scene.objects if o.type=='MESH']
        export(ROOT/f'world/{file}.usdz',groups+parts)
        cam=studio(target=(0,0,.43),distance=4,ortho=2.85);cam.location=(2.6,-4,2.65);cam.rotation_euler=(Vector((0,0,.43))-cam.location).to_track_quat('-Z','Y').to_euler()
        bpy.context.scene.render.resolution_x=1000;bpy.context.scene.render.resolution_y=900
        if '--final-only' not in sys.argv or stage>=6:render(ROOT/f'previews/{file}.png')
        records.append({'index':stage,'name':name,'file':file+'.usdz','triangles':count_stage,'preview':'../previews/'+file+'.png','pieces':[{'name':o.name,'translation':[o.location.x,o.location.z,-o.location.y],'scale':[1,1,1],'growthPivot':'localOrigin'} for o in groups]})
        print('WORLD_STAGE',name,count_stage)
    (ROOT/'world/layouts.json').write_text(json.dumps({'schemaVersion':1,'strategy':'completeStagesWithStableGroups','upAxis':'Y','stages':records,'transition':{'durationSeconds':1.2,'method':'crossfadeOrReveal','persistentPieces':['island','home_lantern'],'growingPieces':['hero_growth','companion_0','companion_1','backdrop_0','backdrop_1']}},indent=2)+'\n')
    (ROOT/'reports/world.json').write_text(json.dumps({'stages':records,'props':{'water_cup':count,'lantern':lampcount}},indent=2)+'\n')
