"""Optional blank paper name tag, held low enough to keep the face readable."""
import sys,math,json
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from common import *
from mathutils import Matrix
bpy.ops.wm.open_mainfile(filepath=str(ROOT/'src/moku_character.blend'))
import motion_v2 as motion
rig=bpy.data.objects['Rig'];mesh=bpy.data.objects['Plush'];motion.bind(rig,mesh);motion.neutral();motion.mood('content')
for side,sign in [('L',1),('R',-1)]:motion.arm(side,(-sign*.12,-.19,-.09),.82)
motion.rot('head',z=-3);bpy.context.view_layer.update()
cream=mat('Name tag cotton paper',(.92,.84,.66),.96);cocoa=mat('Name tag ink',(.20,.12,.07),.94)
bpy.ops.mesh.primitive_cube_add(size=1,location=(0,0,0));tag=bpy.context.object;tag.scale=(.29,.009,.115);bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
mod=tag.modifiers.new('Soft paper corners','BEVEL');mod.width=.008;mod.segments=3;bpy.ops.object.modifier_apply(modifier=mod.name);finish(tag,'NameTag',cream)
line=tube('Write your name',[(-.103,-.007,-.025),(.103,-.007,-.025)],.0017,cocoa,4)
select([tag,line]);bpy.ops.object.join();tag=bpy.context.object;tag.name='NameTag';export(ROOT/'props/name_tag.usdz',[tag])
scene=bpy.context.scene;from compositor_camera import configure
configure(scene)
base=Vector((0,-.276,.294));tag.location=base
hand=rig.matrix_world @ rig.pose.bones['hand_R'].matrix;conversion=Matrix.Rotation(-math.pi/2,4,'X');attachment=hand.inverted() @ Matrix.Translation(base) @ conversion.inverted()
record={'file':'../props/name_tag.usdz','joint':'hand_R','wrapperLocalMatrixColumnMajor':[attachment[r][c] for c in range(4) for r in range(4)],'instructions':'Apply nameTagHold joint pose, then attach this wrapper to hand_R. The tag stays below the chin; text goes on its front (-Y authoring / +Z runtime) paper face. Do not scale the rig to fit the tag.'}
path=ROOT/'character/prop_attachments.json';data=json.loads(path.read_text());data['name_tag_hold']=record;path.write_text(json.dumps(data,indent=2)+'\n')
weights={k.name:k.value for k in mesh.data.shape_keys.key_blocks if k.value};joints={b.name:[math.degrees(a) for a in b.rotation_euler] for b in rig.pose.bones if Vector(b.rotation_euler).length>1e-5}
(ROOT/'onboarding').mkdir(exist_ok=True)
manifest={'schemaVersion':1,'hello':{'clip':'hello_wave','file':'character/anims/hello_wave.usdz','preview':'previews/poses/hello_wave.png','durationSeconds':3,'reduceMotion':'crossfade content to happy; no hop'},'nameTagHold':{'optional':True,'blendShapes':weights,'jointEulerDegrees':joints,'attachment':'character/prop_attachments.json#name_tag_hold','preview':'previews/onboarding/name-tag-hold.png','paperTextAreaModelUnits':{'center':[0,0,.007],'size':[.22,.065],'frontNormal':[0,0,1]},'text':'Empty by design; use the person’s entered name, or keep the optional prop hidden. Do not bake personal names into shared assets.'}}
(ROOT/'onboarding/manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
render(ROOT/'previews/onboarding/name-tag-hold.png')
rig.hide_render=True;mesh.hide_render=True;tag.location=(0,0,0);cam=scene.camera;cam.location=(.03,-1,.06);cam.rotation_euler=(Vector((0,0,0))-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.ortho_scale=.38;scene.render.resolution_x=768;scene.render.resolution_y=384;render(ROOT/'previews/onboarding/name-tag.png')
print('ONBOARDING_READY hello_wave + blank name tag + held pose and hand_R attachment')
