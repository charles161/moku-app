import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from common import *
bpy.ops.wm.open_mainfile(filepath=str(ROOT/'src/world_v2.blend'))
cam=studio(target=(0,0,.54),distance=3,ortho=1.5);scene=bpy.context.scene;scene.render.resolution_x=512;scene.render.resolution_y=512;scene.cycles.samples=24
for name in ['round_felt','pine','birch','blossom','autumn_maple','sapling']:
 o=bpy.data.objects['tree_'+name];o.hide_render=False;o.hide_set(False);render(ROOT/f'previews/world-v2/tree_{name}.png');o.hide_render=True;o.hide_set(True)
