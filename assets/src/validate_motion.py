import sys,json,math
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from common import *
import motion_v2 as motion
import numpy as np
bpy.ops.wm.open_mainfile(filepath=str(ROOT/'src/moku_character.blend'));rig=bpy.data.objects['Rig'];mesh=bpy.data.objects['Plush'];motion.bind(rig,mesh)
def state():
 return np.array([v for b in rig.pose.bones for v in (*b.location,*b.rotation_euler,*b.scale)]+[k.value for k in mesh.data.shape_keys.key_blocks],dtype=float)
requested=set(sys.argv[sys.argv.index('--')+1:]) if '--' in sys.argv else set()
previous=json.loads((ROOT/'reports/motion-v2-validation.json').read_text()) if requested else {}
motion.pose('idle_breathe',0,4);rest=state();reports=[] if not requested else [r for r in previous['clips'] if r['name'] not in requested]
transitions={'stand_up','sit_up_tall','sit_down','settle_down','hop_turn','fold_arms','unfold_arms','cross_arms','uncross_arms'}
held={'disappointed_hold','annoyed_hold','sleep_loop','carry_lantern','build_hammer','tea_sit'}
for name,duration,loop in motion.CLIPS:
 if requested and name not in requested:continue
 duration=round(duration*24)/24;frames=round(duration*24);samples=[]
 for f in range(frames+1):
  motion.pose(name,f/24,duration);s=state();assert np.isfinite(s).all();samples.append(s)
 start,end=samples[0],samples[-1];delta=float(np.abs(end-start).max())
 if loop:assert delta<1e-6,(name,'loop discontinuity',delta)
 if name not in transitions|held:assert np.abs(start-rest).max()<1e-6 and np.abs(end-rest).max()<1e-6,(name,'not seated rest')
 canonical=motion.ALIASES.get(name,name)
 if canonical in ['hop_cycle','hop_start','hop_stop']:
  for phase in [0,.16,.28,.73,.9,1]:
   motion.pose(name,phase*duration,duration)
   for side in ['L','R']:
    assert Vector(rig.pose.bones['leg_'+side].rotation_euler).length<1e-7 and Vector(rig.pose.bones['foot_'+side].rotation_euler).length<1e-7,(name,phase)
 if name in motion.ALIASES:
  for f,s in enumerate(samples):
   motion.pose(canonical,f/24,duration);assert np.abs(state()-s).max()<1e-7,(name,'alias differs')
 reports.append({'name':name,'samples':frames+1,'finite':True,'loopEndpointMaxAbsDelta':delta if loop else None,'seatedEndpoints':name not in transitions|held,'aliasExact':name in motion.ALIASES})
# Ear volume: adjacent keys retain at least 90% of authored ring half-width.
keys=mesh.data.shape_keys.key_blocks;groups={g.name:g.index for g in mesh.vertex_groups};basis=keys['Basis']
checks=[]
for path in ([] if requested else motion.EAR_PATHS['paths']):
 for side in ['L','R']:
  indices=[v.index for v in mesh.data.vertices if any(g.group==groups['part_ear_'+side] for g in v.groups)]
  for n in range(65):
   phase=n/64;motion.neutral();motion.ear_lift(phase,path['target'])
   weights={k.name:k.value for k in keys if k.value};verts=[]
   for i in indices[:620]:
    v=basis.data[i].co.copy()
    for k,w in weights.items():v+=(keys[k].data[i].co-basis.data[i].co)*w
    verts.append(v)
   ratios=[]
   for ring in range(2,29):
    width=(verts[ring*20]-verts[ring*20+10]).length
    expected=2*(.078*math.sin(math.pi*ring/30)**.40+.0008);ratios.append(width/expected)
   checks.append(min(ratios))
if requested:checks=[previous['minimumIntermediateEarWidthRatio']]
assert min(checks)>.90,min(checks)
(ROOT/'reports/motion-v2-validation.json').write_text(json.dumps({'clips':reports,'minimumIntermediateEarWidthRatio':min(checks),'earSamples':previous.get('earSamples',len(checks)),'planting':'Both leg and foot joints remain at rest throughout each planted phase. Runtime horizontal motion must follow published flight-only curve.'},indent=2)+'\n')
print('PASS',len(reports),'sampled clips; loops, seated endpoints, aliases, planted hind feet; ear min width ratio',min(checks))
