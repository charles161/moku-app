#!/usr/bin/env python3
"""Lay out unretouched, fixed-crop frames from the scripted stage captures."""
import json, math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
root = Path(__file__).resolve().parents[1] / 'screenshots/review/v1-p0-fix'
font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 18)
small = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 14)
sets = {name: json.loads((root/f'drift-{name}/drift-check.json').read_text()) for name in ['before', 'after']}
# Same alpha union and scale for both sequences: never recenter individual poses.
bounds = None
for name, data in sets.items():
 for frame in data['frames']:
  image = Image.open(root/f'drift-{name}'/frame['file']).convert('RGBA')
  b = image.getbbox()
  bounds = b if bounds is None else tuple(f(a,c) for f,a,c in zip([min,min,max,max],bounds,b))
bounds = (bounds[0]-12,bounds[1]-12,bounds[2]+12,bounds[3]+12)
def sheet(filename, moments, title):
 w,h=250*len(moments),670
 out=Image.new('RGB',(w,h),'#eeeeee'); d=ImageDraw.Draw(out)
 d.text((16,10),title,fill='#333333',font=font)
 for row,(name,data) in enumerate(sets.items()):
  y=50+row*305
  d.text((16,y),name.title() + (' — abrupt entry / turn-away' if name=='before' else ' — continuous mood / eyes first'),font=font,fill='#333333')
  for col,t in enumerate(moments):
   frame=min(data['frames'],key=lambda f:abs(f['seconds']-t))
   image=Image.open(root/f'drift-{name}'/frame['file']).convert('RGBA').crop(bounds)
   image.thumbnail((240,240),Image.Resampling.LANCZOS)
   x=col*250+(250-image.width)//2
   out.paste(image,(x,y+28),image)
   d.text((col*250+10,y+270),f"{frame['seconds']:.2f}s · {frame['state']['displayedMood']}",font=small,fill='#333333')
 out.save(root/filename)
sheet('drift-focus-strip.png',[0,1.25,1.5,2.5,4.5,5.25,6.5,8.5],'Same known-feed verdict at 0s, grace 1s; scripted disappointed tier at 5s. Fixed crop/scale, about 120 pt @2x.')
sheet('drift-return-strip.png',[8.5,9.25,9.5,9.75,10.5,11.5,12.5,13.75],'Same full return at 9s. Before: fast pose + 6 pt hop. After: happy in 0.6s + 2.5 pt eased hop, content in 2.4s.')
metrics={}
for name,data in sets.items():
 rows=[f for f in data['frames'] if 1.5<=f['seconds']<=8.9]
 speeds=[]
 for a,b in zip(rows,rows[1:]):
  q=a['state']['headRotation'];r=b['state']['headRotation']
  dot=min(1,abs(sum(x*y for x,y in zip(q,r))))
  speeds.append(2*math.acos(dot)*180/math.pi/(b['seconds']-a['seconds']))
 metrics[name]={'maxSampledDriftHeadDegreesPerSec':max(speeds),'firstAnnoyedBlendFrameSec':data['firstAnnoyedBlendFrameSec'],'firstUserGlanceFrameSec':data['firstUserGlanceFrameSec'],'captureCount':len(data['frames'])}
metrics['after']['allTransitionSilhouettesPass']=all(f['silhouettePass'] for f in sets['after']['frames'])
metrics['after']['clips']=sets['after']['frames'][-1]['state']['clips']
(root/'drift-comparison.json').write_text(json.dumps(metrics,indent=2)+'\n')
print(json.dumps(metrics,indent=2))
