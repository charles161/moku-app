"""Opt-in atlas material setup shared by Blender proof renders."""
from pathlib import Path
import json,bpy
ROOT=Path(__file__).resolve().parents[1]
DATA=json.loads((ROOT/'character/face_atlas.json').read_text())
def apply(name):
 cell=next(c for c in DATA['cells'] if c['name']==name);mesh=bpy.data.objects['Plush'];mat=bpy.data.materials['Face decals']
 node=next(n for n in mat.node_tree.nodes if n.type=='TEX_IMAGE');node.image=bpy.data.images.load(str(ROOT/'character/face_atlas.png'),check_existing=True)
 mapping=mat.node_tree.nodes.get('AtlasMapping')
 if mapping is None:
  mapping=mat.node_tree.nodes.new('ShaderNodeMapping');mapping.name='AtlasMapping';uv=mat.node_tree.nodes.new('ShaderNodeTexCoord');mat.node_tree.links.new(uv.outputs['UV'],mapping.inputs['Vector']);mat.node_tree.links.new(mapping.outputs['Vector'],node.inputs['Vector'])
 mapping.inputs['Scale'].default_value=(.25,.25,1);mapping.inputs['Location'].default_value=(*cell['blenderUVOffset'],0)
 for key in ['face_decals','eye_hidden_L','eye_hidden_R']:mesh.data.shape_keys.key_blocks[key].value=cell['morphs'].get(key,0)
 bpy.context.view_layer.update()
 return cell
