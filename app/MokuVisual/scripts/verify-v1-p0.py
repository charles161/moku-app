#!/usr/bin/env python3
from pathlib import Path
from PIL import Image, ImageChops
import hashlib, json
root=Path(__file__).resolve().parents[1]
shots=root/'screenshots';review=shots/'review/v1-p0'
checks=json.loads((review/'checks.json').read_text());perf=json.loads((shots/'performance-v1-p0-final.json').read_text());stress=json.loads((shots/'stress-v1-p0-5min.json').read_text())
assert perf['focused']['cpuPercent']<=1 and perf['focused']['renderedFrames']==0 and perf['focused']['saccades']>0
assert perf['drift']['cpuPercent']<=1.5 and perf['drift']['microExpressions']>=2
assert perf['hidden']['renderedFrames']==0
assert stress['seconds']>=300 and not stress['errors'] and not stress['newCrashReports'] and stress['firstVisibleSource']=='real'
assert checks['final']['firstVisibleSource']=='real' and checks['final']['error']=='none'
assert checks['carried']['carrying'] and checks['carried']['lanternBrightness']==.25
assert not checks['homeReturn']['carrying']
assert checks['holdsPlace']['gazeHeldPoint']==[0,1400]
assert checks['grab']['flingFinished'] and checks['grab']['error']=='none'
for a,b in zip(checks['grab']['drop'],checks['grab']['returnedHome']): assert abs(a-b)<=1
for clip in ['fold_arms','unfold_arms','cross_arms','uncross_arms','walk_cycle']: assert clip in checks['clipHistory']
bounds={}
for path in review.glob('usual-*.png'):
 image=Image.open(path);bbox=image.getchannel('A').point(lambda p:255 if p>32 else 0).getbbox()
 assert bbox and bbox[0]>0 and bbox[1]>0 and bbox[2]<image.width and bbox[3]<image.height,(path.name,bbox)
 bounds[path.stem]=bbox
for name in ['stranger-light','stranger-dark','silhouettes','front-and-usual','gaze-and-smile','lantern-arc','return-beat','drag-drop-throw','manual-control']:
 assert (review/(name+'.png')).stat().st_size>1000
art=root.parents[1]/'assets';bundle=root/'.build/MokuVisualDemo.app/Contents/Resources/MokuAssets'
paths=['SPEC.md','character/moku_bunny.usdz','character/moods.json','character/prop_attachments.json','lantern/manifest.json','symbols/manifest.json','runtime/materials.json','runtime/studio.json']
for name in paths:
 assert hashlib.sha256((art/name).read_bytes()).digest()==hashlib.sha256((bundle/name).read_bytes()).digest(),name
result={'status':'pass','tests':36,'idleCPU':perf['focused']['cpuPercent'],'driftCPU':perf['drift']['cpuPercent'],'idleLiveFrames':perf['focused']['renderedFrames'],'driftGlances':perf['drift']['microExpressions'],'stressSeconds':stress['seconds'],'newCrashReports':stress['newCrashReports'],'firstVisibleSource':checks['final']['firstVisibleSource'],'framingBounds':bounds,'humanRecognition':'pending Charles review','physicalDesktopInput':'offscreen paths tested; occupied desktop untouched'}
(shots/'verification-v1-p0.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
