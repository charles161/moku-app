from pathlib import Path
import json,hashlib
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]
clips=json.loads((ROOT/'character/animations.json').read_text())['clips'];moods=json.loads((ROOT/'character/moods.json').read_text())['moods'];stages=json.loads((ROOT/'world/layouts.json').read_text())['stages']
assert len(clips)==34 and len(moods)==8 and len(stages)==8
required=['SPEC.md','concept/character_sheet.png','concept/forest_stages.png','concept/material_board.png','character/moku_bunny.usdz','character/prop_attachments.json','runtime/materials.json','runtime/studio.json','icons/AppIcon.png','icons/AppIcon.icns','props/water_cup.usdz','props/lantern.usdz','props/petal.png','props/confetti.png','previews/compare_sheet.png','previews/moods-before-after.png','previews/micro-expressions.png','symbols/manifest.json','character/face_atlas.json','character/face_atlas.png','character/face_atlas_opacity.png','lantern/manifest.json','previews/lantern-states.png','previews/moods_v1_realitykit.png','previews/paws-v1.png','previews/face-atlas-review.png','previews/crossed-arms-fit.png','runtime/MokuFaceAtlas.swift','reports/face-atlas-realitykit.json','previews/moods_v1.png','previews/moods_v1_silhouette.png','previews/stranger-test-light.png','previews/stranger-test-dark.png','reports/v0-ear-rest.json','previews/index.html','previews/compositor.json']
required += ['character/'+c['file'] for c in clips]+['previews/poses/'+c['name']+'.png' for c in clips]+['previews/moods/'+m+'.png' for m in moods]
for stage in stages:
 stem=f"stage_{stage['index']}_{stage['name']}";required += ['world/'+stem+'.usdz','previews/'+stem+'.png','icons/'+stem+'.png','icons/'+stem+'@2x.png']
symbols=json.loads((ROOT/'symbols/manifest.json').read_text())
assert len(symbols['sprites'])==11
for sprite in symbols['sprites']:
 for variant in [sprite,*sprite['densities'].values()]:
  for field in ['sheet','still']:
   rel='symbols/'+variant[field];required.append(rel);im=Image.open(ROOT/rel);assert im.mode=='RGBA' and im.getchannel('A').getextrema()[0]==0,rel
  tile=variant.get('frameSizePixels',sprite['frameSizePixels']);assert Image.open(ROOT/'symbols'/variant['sheet']).size==(tile[0]*6,tile[1])
assert json.loads((ROOT/'reports/v0-ear-rest.json').read_text())['restoredExactly']
lantern=json.loads((ROOT/'lantern/manifest.json').read_text())
for state in lantern['states']:
 for density,files in state['files'].items():
  for field in ['body','flame','composite']:
   rel='lantern/'+files[field];required.append(rel);im=Image.open(ROOT/rel);assert im.mode=='RGBA' and im.size==tuple(files['sizePixels']) and im.getchannel('A').getextrema()[0]==0,rel
for density in ['2x','3x']:required.append('lantern/'+lantern['spark'][density])
atlas=json.loads((ROOT/'character/face_atlas.json').read_text());assert len(atlas['cells'])==16
assert Image.open(ROOT/atlas['atlasPath']).size==(2048,2048)
assert Image.open(ROOT/atlas['opacityAtlasPath']).size==(2048,2048)
assert set(['LOP','LIFT','ANTENNA_L','ANTENNA_R','FORWARD','CURTAIN','PINNED','MELT'])==set(json.loads((ROOT/'character/moods.json').read_text())['earPoses'])
assert all(name in json.loads((ROOT/'character/moods.json').read_text())['bodyPoses'] for name in ['lean_in','slump','chest_out','paws_lap','arms_crossed','three_quarter'])
assert 'carry_lantern' in json.loads((ROOT/'character/prop_attachments.json').read_text())
assert len(json.loads((ROOT/'reports/face-atlas-realitykit.json').read_text())['frames'])==8
layout=json.loads((ROOT/'world/layouts.json').read_text());assert layout['schemaVersion']==2
assert len(layout['projects'])==7 and sum(p['unitCount'] for p in layout['projects'])==1000
assert len(layout['treeSlots'])==200 and len(layout['pathSlots'])==200
assert len({s['asset'] for s in layout['treeSlots']})==6
assert all(s['index']==i and s['focusHoursRequired']==i+1 for i,s in enumerate(layout['treeSlots']))
assert all(len(p['slots'])==p['unitCount'] for p in layout['projects'])
for item in layout['kit']:
 required.append('world/'+item['file']);assert item['triangles']<6000,item
for pr in layout['projects']:
 required.append('world/blueprints/'+pr['id']+'.json')
 for layer in ['paper','context','pending','inked','example']:required.append('world/blueprints/'+pr['id']+'_'+layer+'.png')
for hours in [0,1,3,5,20,25,100,120]:required.append(f'previews/world-v2/focus_{hours:03d}h.png')
for name in ['home-hours-review.jpg','popover-370.png','house-stages.jpg','tree-species.jpg','forest-prefixes.jpg']:required.append('previews/world-v2/'+name)
for clip in clips:
 for suffix in ['.mp4','-strip.png']:required.append('previews/anim-v2/'+clip['name']+suffix)
required+=['character/ear_transitions.json','reports/motion-v2-validation.json','reports/controls-realitykit.json','previews/anim-v2/index.html','props/name_tag.usdz','props/hammer.usdz','onboarding/manifest.json','previews/onboarding/name-tag-hold.png','previews/onboarding/name-tag.png','reports/brief4-self-check.md','reports/brief4-validation.json']
control=json.loads((ROOT/'reports/controls-realitykit.json').read_text());assert len(control['frames'])==68
required.append('reports/prop-clearance.json')
clearance=json.loads((ROOT/'reports/prop-clearance.json').read_text());assert clearance['passed'] and clearance['samples']==59 and clearance['surfaceIntersections']==0
motion=json.loads((ROOT/'reports/motion-v2-validation.json').read_text());assert len(motion['clips'])==34 and motion['minimumIntermediateEarWidthRatio']>.90
paths=json.loads((ROOT/'character/ear_transitions.json').read_text());assert paths['shapeRevision']==3 and all(len(p['keyposes'])==17 for p in paths['paths'])
for p in required:assert (ROOT/p).is_file() and (ROOT/p).stat().st_size>0,p
assert Image.open(ROOT/'icons/AppIcon.png').size==(1024,1024)
reports=json.loads((ROOT/'reports/realitykit-all.json').read_text());audit=json.loads((ROOT/'reports/usd-audit.json').read_text())
assert len(reports)==len(list(ROOT.rglob('*.usdz'))) and all(r['loaded'] for r in reports)
assert len(audit)==len(reports)
expected=json.loads((ROOT/'reports/character.json').read_text())['blendShapes']
assert len(expected)==80
assert set(['blink_L','blink_R','eyes_happy','eyes_wide','brows_up','brows_concern','brows_angry','smile','frown','mouth_open','pout','cheeks_puff']).issubset(expected)
for report in reports:
 if '/character/' in report['file']:
  rigs=[m for m in report['models'] if m.get('jointCount')==21]
  assert len(rigs)==1,report['file']
  description=rigs[0].get('blendShapeDescription','')
  assert all(name in description for name in expected),(report['file'],description)
for c in clips:
 r=next(r for r in audit if r['file']=='character/'+c['file'])
 a=next(a for a in r['animations'] if a['name']==c['name'])
 assert a['rotationSamples']>1 and a['blendSamples']>1 and abs(a['duration']-c['duration'])<.001,c
 assert any(c['name']+'[' in name for report in reports if report['file'].endswith('/'+c['file']) for name in report['animations']),c
 imported=next(report for report in reports if report['file'].endswith('/'+c['file']))
 for kind in ['joints','face']:
  tracks=[a for a in imported['animationDetails'] if a['kind']==kind and '/Armature/'+c['name']+'[' in a['name']]
  assert tracks and all(abs(a['duration']-c['duration'])<1e-5 for a in tracks),('native clip duration',c['name'],kind,tracks)
for material in json.loads((ROOT/'runtime/materials.json').read_text())['materials']:
 for field in ['normalMapPath','baseColorTexturePath']:
  if material.get(field):assert (ROOT/material[field]).is_file(),material
preview=json.loads((ROOT/'previews/manifest.json').read_text());assert not preview['edgeContact']
for p in (ROOT/'character').glob('*.png'):
 im=Image.open(p);assert max(im.size)<=2048,p
report={'passed':True,'usdzFilesLoaded':len(reports),'clips':len(clips),'moods':len(moods),'worldStages':len(stages),'homeProjects':7,'treeSlots':200,'kitAssets':len(layout['kit']),'characterTriangles':next(r['triangles'] for r in audit if r['file']=='character/moku_bunny.usdz'),'maxWorldTriangles':max(s['triangles'] for s in stages),'transparentImagesChecked':len(preview['entries']),'requiredFilesChecked':len(required),'symbolSets':len(symbols['sprites']),'faceAtlasCells':16,'lanternStates':3,'humanRecognitionTest':'pending, not claimed','sha256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in required}}
(ROOT/'reports/acceptance.json').write_text(json.dumps(report,indent=2)+'\n')
print('PASS',len(required),'required files;',len(reports),'RealityKit loads; 34 clips; 8 moods; 8 stages; image dimensions, framing and budgets')
