import sys, math, json
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from common import *
from companion import paths
P=paths()
bpy.ops.wm.open_mainfile(filepath=str(P.blend))
exportOnly='--exports-only' in sys.argv
poseOnly='--poses-only' in sys.argv
requested={v for v in sys.argv[sys.argv.index('--')+1:] if not v.startswith('--')} if '--' in sys.argv else set()
rig=bpy.data.objects['Rig'];mesh=bpy.data.objects['Plush'];scene=bpy.context.scene
scene.render.resolution_x=768;scene.render.resolution_y=768;scene.cycles.samples=32
from compositor_camera import configure
configure(scene)
for b in rig.pose.bones:b.rotation_mode='XYZ'
def attachment_record(key,record):
    path=P.dir/'prop_attachments.json';data=json.loads(path.read_text()) if path.exists() else {'schemaVersion':1};data[key]=record;path.write_text(json.dumps(data,indent=2)+'\n')

from motion_v2 import *
rig=bpy.data.objects['Rig'];mesh=bpy.data.objects['Plush'];bind(rig,mesh)
if not exportOnly and not requested:
 for name in MOODS:
  neutral();mood(name);bpy.context.view_layer.update();render(P.previews/f'moods/{name}.png')
neutral()
clips=CLIPS
records=[] if not requested else [r for r in json.loads((P.dir/'animations.json').read_text())['clips'] if r['name'] not in requested]
for name,duration,loop in clips:
    if requested and name not in requested:continue
    rig.animation_data_clear();mesh.data.shape_keys.animation_data_clear();neutral()
    frames=round(duration*24);scene.frame_start=1;scene.frame_end=frames+1
    if not poseOnly:
        # A species may refilter its whole clip before it's keyed (Tetsu's servo motion): sample every frame first.
        servo=getattr(SP,'servo',None);keys=list(mesh.data.shape_keys.key_blocks)[1:];samples=[]
        if servo:
            for f in range(frames+1):
                scene.frame_set(f+1);pose(name,f/24,frames/24)
                samples.append({**{b.name:(tuple(b.location),tuple(b.rotation_euler),tuple(b.scale)) for b in rig.pose.bones},'__keys':[k.value for k in keys]})
            samples=servo(name,samples,loop)
        for f in range(frames+1):
            scene.frame_set(f+1)
            if servo:
                for b in rig.pose.bones:b.location,b.rotation_euler,b.scale=samples[f][b.name]
                for k,v in zip(keys,samples[f]['__keys']):k.value=v
            else:pose(name,f/24,frames/24)
            for b in rig.pose.bones:
                for prop in ['location','rotation_euler','scale']:b.keyframe_insert(data_path=prop,frame=f+1,group=b.name)
            # The standing pose library has no face: the app keeps the live mood's face while standing.
            if name!='stand_poses':
                for k in keys:k.keyframe_insert(data_path='value',frame=f+1)
        rig.animation_data.action.name=name
        if mesh.data.shape_keys.animation_data:mesh.data.shape_keys.animation_data.action.name=name+'_face'
        scene.frame_set(1);(P.dir/'anims').mkdir(exist_ok=True);export(P.dir/f'anims/{name}.usdz',[rig,mesh],animation=True)
    # Fixed camera and canvas are compositor-compatible. Pose at most readable phase.
    phase=.45 if name not in ['wave','stretch','sleep_loop','stand_up','sit_down'] else .5
    if name in ['stand_up','sit_up_tall']:phase=1
    if name=='sit_down':phase=1
    if name in ['fold_arms','cross_arms']:phase=1
    if name in ['unfold_arms','uncross_arms']:phase=0
    if name in ['build_hammer','tea_sit']:phase=0
    if name=='drink_water':phase=2.4/DRINK_SECONDS  # the cup held up, just before the first sip: its grip is measured here
    if poseOnly:pose(name,round(frames*phase)/24,frames/24)
    else:scene.frame_set(1+round(frames*phase))
    if name=='drink_water':
        import world
        from mathutils import Matrix
        # A companion may hold its own water prop (Tetsu's battery cell): it builds and exports it and
        # says where its anchor sits at this phase. Moku keeps the shared cup.
        custom=getattr(SP,'drink_prop',None)
        if custom:preview_prop,propFile,anchor=custom(P,rig)
        else:world.materials();select([]);preview_prop=world.cup();propFile=P.props+'/water_cup.usdz';anchor=(0,-.31,.355)
        desired=Matrix.Translation(anchor)
        conversion=Matrix.Rotation(-math.pi/2,4,'X')
        attachment=(rig.matrix_world @ rig.pose.bones['hand_R'].matrix).inverted() @ desired @ conversion.inverted()
        attachment_record('drink_water',{'file':propFile,'joint':'hand_R','wrapperLocalMatrixColumnMajor':[attachment[r][c] for c in range(4) for r in range(4)],'instructions':'Attach a wrapper to hand_R joint world pose; set wrapper local matrix from these columns. Add the imported cup root under that wrapper without replacing its authored root transform.','visibleNormalizedTime':[.06,.90]})
        for obj in preview_prop:obj.location+=Vector(anchor)
    if name=='carry_lantern':
        import world
        from mathutils import Matrix
        world.materials();select([]);preview_prop=world.lantern()
        hand=rig.matrix_world @ rig.pose.bones['hand_R'].matrix
        base=hand.translation+Vector((.018,-.045,-.272));desired=Matrix.Translation(base);conversion=Matrix.Rotation(-math.pi/2,4,'X')
        attachment=hand.inverted() @ desired @ conversion.inverted()
        attachment_record('carry_lantern',{'file':P.props+'/lantern.usdz','joint':'hand_R','wrapperLocalMatrixColumnMajor':[attachment[r][c] for c in range(4) for r in range(4)],'instructions':'Same wrapper convention as drink_water. Follow composed hand_R world transform; retain imported lantern root coordinate conversion. Hide the 2D lantern while carrying.','visibleNormalizedTime':[0,1],'holdJointEulerDegrees':{'arm_R':[math.degrees(v) for v in rig.pose.bones['arm_R'].rotation_euler],'hand_R':[math.degrees(v) for v in rig.pose.bones['hand_R'].rotation_euler]},'holdClip':'carry_lantern','handleAnchorAuthoring':[0,0,.272],'baseAuthoringAtPreview':list(base)})
        for obj in preview_prop:obj.location+=base
    if name in ['build_hammer','tea_sit']:
        from life_props import attach_for_preview
        preview_prop=attach_for_preview(name,rig)
    if not exportOnly:render(P.previews/f'poses/{name}.png')
    if name in ['drink_water','carry_lantern','build_hammer','tea_sit']:
        for obj in preview_prop:bpy.data.objects.remove(obj,do_unlink=True)
    records.append({'name':name,'duration':frames/24,'fps':24,'loop':loop,'file':f'anims/{name}.usdz','preview':('../previews' if P.id=='moku' else f'../../previews/{P.id}')+f'/poses/{name}.png','startPose':'standing' if name in ['walk_cycle','sit_down','carry_lantern'] else 'sleeping' if name=='sleep_loop' else 'sitting','endPose':'standing' if name in ['walk_cycle','stand_up','carry_lantern'] else 'sleeping' if name=='sleep_loop' else 'sitting','heldMood':'disappointed' if name in ['fold_arms','disappointed_hold'] else 'annoyed' if name in ['cross_arms','annoyed_hold'] else None,'rootMotion':'vertical' if name in ['hop','celebrate','big_celebrate'] else 'inPlace'})
records.sort(key=lambda r:[c[0] for c in clips].index(r['name']))
for r in records:
 name=r['name'];canonical=ALIASES.get(name,name)
 r['aliasOf']=ALIASES.get(name)
 r['startPose']='tallSeated' if canonical=='settle_down' else 'disappointed' if name in ['unfold_arms','disappointed_hold'] else 'annoyed' if name in ['uncross_arms','annoyed_hold'] else 'sleepingSeated' if name=='sleep_loop' else 'sitting'
 r['endPose']='tallSeated' if canonical=='sit_up_tall' else 'disappointed' if name in ['fold_arms','disappointed_hold'] else 'annoyed' if name in ['cross_arms','annoyed_hold'] else 'sleepingSeated' if name=='sleep_loop' else 'sitting'
 if canonical in ['hop_cycle','hop_start','hop_stop']:
  r.update(strideLength=.26 if canonical=='hop_cycle' else .16,travelAxis='+Z',rootMotion='verticalOnly; horizontal supplied by runtime',travelPhase=[.29,.72],travelCurve='smoothstep(clamp((normalizedTime-0.29)/0.43)); advance only during flight',plantedPhases=[[0,.29],[.72,1]])
 if name=='carry_lantern':r.update(startPose='legacyTallHold',endPose='legacyTallHold',deprecated=True)
 if name in ['build_hammer','tea_sit']:r.update(startPose='hammerReadySeated' if name=='build_hammer' else 'teaHoldSeated',endPose='hammerReadySeated' if name=='build_hammer' else 'teaHoldSeated',sceneOnly=True,propAttachment=name)
 if name=='stand_poses':r.update(poseLibrary=True,startPose='sitting',endPose='standing',samples='frame k is the standing base at s = k / 24 (no face, no mood); the app blends along it')
 if name=='build_hammer':r.update(tapNormalizedTimes=[.34/2.4,.89/2.4,1.44/2.4],tapInstruction='Emit sawdust at these phases; three taps, then a pause. Scale phase by exact duration.')
 if canonical=='hop_turn':r.update(turnDegrees=30,turnAxis='+Y',rootMotion='authoredYaw; no horizontal motion')
 r['earTransitionPath']=P.rel+'/ear_transitions.json'
 if name in {c[0] for c in getattr(SP,'EXTRA_CLIPS',[])}:r['extra']=True
(P.dir/'animations.json').write_text(json.dumps({'schemaVersion':2,'clips':records},indent=2)+'\n')
print('EXPORTED_CLIPS',len(records))
