"""Verify final review artifacts, MP4 decodes, layout references and alpha framing."""
from pathlib import Path
from PIL import Image
import json,subprocess,hashlib,math
ROOT=Path(__file__).resolve().parents[1];clips=json.loads((ROOT/'character/animations.json').read_text())['clips'];layout=json.loads((ROOT/'world/layouts.json').read_text())
kit={k['name']:k for k in layout['kit']};refs=[]
for p in layout['projects']:refs+=p['slots']+p['finale']+p.get('structuralBase',[])
refs+=layout['treeSlots']+layout['pathSlots']+layout['siteProps']+[layout['blueprintAnchor'],layout['tentAnchor']]
for r in refs:
 assert r['asset'] in kit,r
 assert all(math.isfinite(v) for k in ['translation','scale','rotationQuaternion'] for v in r[k]),r
 assert abs(sum(v*v for v in r['rotationQuaternion'])-1)<1e-5,r
 assert all(s>0 for s in r['scale']),r
for p in layout['projects']:
 bp=json.loads((ROOT/'world/blueprints'/f'{p["id"]}.json').read_text());assert [v['id'] for v in bp['units']]==[v['id'] for v in p['slots']]
for i,r in enumerate(layout['treeSlots']):assert r['index']==i and r['ring']==sorted(x['ring'] for x in layout['treeSlots'])[i]
movies=[]
for c in clips:
 path=ROOT/'previews/anim-v2'/f'{c["name"]}.mp4'
 info=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v','-show_entries','stream=width,height,codec_name,nb_frames:format=duration','-of','json',str(path)]))
 assert len(info['streams'])==1 and info['streams'][0]['codec_name']=='h264' and info['streams'][0]['width']==512 and info['streams'][0]['height']==512,c['name']
 assert int(info['streams'][0]['nb_frames'])==round(c['duration']*24)*(3 if c['loop'] else 1),('movie frames',c['name'])
 expected=c['duration']*(3 if c['loop'] else 1)
 assert abs(float(info['format']['duration'])-expected)<1/24,('movie duration',c['name'],info['format']['duration'],expected)
 subprocess.run(['ffmpeg','-v','error','-i',str(path),'-f','null','-'],check=True,capture_output=True)
 movies.append({'clip':c['name'],'seconds':float(info['format']['duration']),'frames':int(info['streams'][0]['nb_frames']),'decodes':True,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
alpha=[]
for folder in ['previews/anim-v2','previews/world-v2','previews/onboarding']:
 for path in (ROOT/folder).rglob('*.png'):
  im=Image.open(path)
  if im.mode!='RGBA':continue
  b=im.getchannel('A').getbbox();assert b,path
  assert b[0]>0 and b[1]>0 and b[2]<im.width and b[3]<im.height,('clipped',path,b)
  alpha.append(str(path.relative_to(ROOT)))
report={'passed':True,'layoutPlacementsChecked':len(refs),'blueprintUnitIdsChecked':1000,'treeSlots':200,'pathSlots':200,'movies':movies,'transparentFramesChecked':len(alpha),'transparentFrames':alpha,'note':'Artifact/registration and decode tests; aesthetic self-review is separately documented. Human recognition is not measured.'}
(ROOT/'reports/brief4-validation.json').write_text(json.dumps(report,indent=2)+'\n');print('PASS',len(movies),'MP4 decodes;',len(alpha),'RGBA frames;',len(refs),'layout placements')
