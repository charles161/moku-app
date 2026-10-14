"""Compare actual mesh vertices, weights and bind matrices to the preserved v0 blend."""
import bpy,json,zipfile,tempfile
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
def snapshot(path):
 bpy.ops.wm.open_mainfile(filepath=str(path));mesh=bpy.data.objects['Plush'];rig=bpy.data.objects['Rig'];result={}
 for side in ['L','R']:
  tag=mesh.vertex_groups['part_ear_'+side].index
  ids=[v.index for v in mesh.data.vertices if any(g.group==tag for g in v.groups)]
  result[side]={'positions':np.array([list(mesh.data.shape_keys.key_blocks['Basis'].data[i].co) for i in ids]),'weights':np.array([[next((g.weight for g in mesh.data.vertices[i].groups if mesh.vertex_groups[g.group].name=='ear_'+side+'_'+seg),0) for seg in ['01','02']] for i in ids]),'binds':np.array([list(map(list,rig.data.bones['ear_'+side+'_'+seg].matrix_local)) for seg in ['01','02']])}
 return result
with tempfile.TemporaryDirectory() as temp:
 z=zipfile.ZipFile(ROOT/'src/history/brief1-character-source.zip');old=Path(temp)/'moku_character.blend';old.write_bytes(z.read('moku_character.blend'));a=snapshot(old)
b=snapshot(ROOT/'src/moku_character.blend');report={'source':'src/history/brief1-character-source.zip:moku_character.blend','restoredExactly':True,'ears':{}}
for side in ['L','R']:
 report['ears'][side]={}
 for key in ['positions','weights','binds']:
  assert a[side][key].shape==b[side][key].shape,(side,key)
  delta=float(np.max(np.abs(a[side][key]-b[side][key])));assert delta==0,(side,key,delta)
  report['ears'][side][key+'MaxAbsoluteDelta']=delta
 report['ears'][side]['vertices']=len(a[side]['positions'])
(ROOT/'reports/v0-ear-rest.json').write_text(json.dumps(report,indent=2)+'\n');print('PASS: both v0 ears have bit-identical base vertices, skin weights and rest joint matrices')
