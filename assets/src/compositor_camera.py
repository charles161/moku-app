from pathlib import Path
import json
import bpy
from mathutils import Vector
from bpy_extras.object_utils import world_to_camera_view
ROOT=Path(__file__).resolve().parents[1]
def configure(scene):
 cam=scene.camera;cam.location=(.55,-3,1.0);cam.rotation_euler=(Vector((0,0,.65))-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.ortho_scale=1.92
 scene.render.resolution_x=768;scene.render.resolution_y=768;scene.render.resolution_percentage=100;bpy.context.view_layer.update()
 def px(point):
  p=world_to_camera_view(scene,cam,Vector(point));return [round(p.x*768,3),round((1-p.y)*768,3)]
 data={'schemaVersion':2,'cameraRevision':2,'orthographicScale':1.92,'cameraTarget':[0,0,.65],'canvasPixels':[768,768],'format':'RGBA PNG','alpha':'straight in PNG; let NSImage/CoreGraphics convert as required','coordinates':'top-left pixel origin; bounds use exclusive right/bottom','sharedCamera':True,'groundAnchorPx':px((0,0,0)),'neutralHeadAnchorPx':px((0,0,.59)),'moodPath':'previews/moods/<mood>.png','posePath':'previews/poses/<clip>.png','poseFrames':1,'notes':['Use the shared ground anchor when crossfading moods.','Clip poses are representative stills; use USDZ for actual skeletal motion.','All PNGs reserve room for ears and gesture motion; do not fit each to independently cropped bounds.']}
 (ROOT/'previews/compositor.json').write_text(json.dumps(data,indent=2)+'\n')
if __name__=='__main__':
 bpy.ops.wm.open_mainfile(filepath=str(ROOT/'src/moku_character.blend'));configure(bpy.context.scene)
