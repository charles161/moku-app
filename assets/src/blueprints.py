"""Layered paper blueprints, with one vector path group per runtime unit."""
from pathlib import Path
from PIL import Image,ImageDraw,ImageFont
import json,math
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'world/blueprints';OUT.mkdir(exist_ok=True)
data=json.loads((ROOT/'world/layouts.json').read_text());W,H=1024,768
font=lambda n:ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',n)
ink='#315560';pending='#B2C0B8'
def rotate(v,q):
 x,y,z,w=q;a,b,c=v
 tx=2*(y*c-z*b);ty=2*(z*a-x*c);tz=2*(x*b-y*a)
 return [a+w*tx+y*tz-z*ty,b+w*ty+z*tx-x*tz,c+w*tz+x*ty-y*tx]
def project(slot):
 verts=[];t=slot['translation'];s=slot['scale'];q=slot['rotationQuaternion']
 # Plant prototypes are ground-pivot miniatures, unlike normalized construction cubes.
 dimensions,center=({'unit_flower':([.136,.188,.136],[0,.09,0]),'unit_carrot':([.10,.14,.062],[0,.055,0])}.get(slot['asset'],([1,1,1],[0,0,0])))
 for x,y,z in [(-.5,-.5,-.5),(.5,-.5,-.5),(.5,-.5,.5),(-.5,-.5,.5),(-.5,.5,-.5),(.5,.5,-.5),(.5,.5,.5),(-.5,.5,.5)]:
  p=rotate([(x*dimensions[0]+center[0])*s[0],(y*dimensions[1]+center[1])*s[1],(z*dimensions[2]+center[2])*s[2]],q);p=[p[i]+t[i] for i in range(3)]
  verts.append([round(490+(p[0]-.57*p[2])*192,2),round(530-p[1]*176+(p[2]+.36*p[0])*65,2)])
 edges=[(0,1),(1,2),(2,3),(3,0),(4,5),(5,6),(6,7),(7,4),(0,4),(1,5),(2,6),(3,7)]
 return [[verts[a],verts[b]] for a,b in edges]
for pr in data['projects']:
 name=pr['id'];paper=Image.new('RGBA',(W,H),(0,0,0,0));d=ImageDraw.Draw(paper)
 d.rounded_rectangle((8,8,W-8,H-8),24,fill='#F2E9D4')
 for x in range(42,W-30,32):d.line((x,100,x,H-88),fill='#DFDFD0',width=1)
 for y in range(114,H-80,32):d.line((40,y,W-40,y),fill='#DFDFD0',width=1)
 d.text((50,36),"MOKU'S HOME",font=font(22),fill=ink);d.text((W-310,35),f'{pr["index"]+1:02d} / {name.upper()}',font=font(25),fill=ink)
 d.line((44,86,W-44,86),fill=ink,width=2)
 d.text((50,H-59),'ONE SMALL PIECE AT A TIME',font=font(18),fill=ink)
 paper.save(OUT/f'{name}_paper.png')
 # The whole-house silhouette stays pending even at zero hours: a visible plan.
 outline=[((275,530),(275,285)),((275,285),(505,125)),((505,125),(745,285)),((745,285),(745,530)),((745,530),(275,530))]
 for a,b in outline:d.line((*a,*b),fill='#CDD4C9',width=4)
 paper.save(OUT/f'{name}_paper.png')
 paths=[]
 for sl in pr['slots']:
  lines=project(sl);paths.append({'index':sl['index'],'id':sl['id'],'polylines':lines})
 # Previous construction gives context, current project owns separate replaceable strokes.
 context=Image.new('RGBA',(W,H),(0,0,0,0));dc=ImageDraw.Draw(context)
 for prev in data['projects'][:pr['index']]:
  for sl in prev['slots']:
   for line in project(sl):dc.line([tuple(pt) for pt in line],fill='#A9B7AD',width=2)
 context.save(OUT/f'{name}_context.png')
 for label,color,width in [('pending',pending,2),('inked',ink,4)]:
  layer=Image.new('RGBA',(W,H),(0,0,0,0));dl=ImageDraw.Draw(layer)
  for unit in paths:
   for line in unit['polylines']:dl.line([tuple(pt) for pt in line],fill=color,width=width)
  layer.save(OUT/f'{name}_{label}.png')
 (OUT/f'{name}.json').write_text(json.dumps({'canvasPixels':[W,H],'origin':'topLeft','units':paths,'inkColor':ink,'pendingColor':pending,'strokePixels':4,'composition':'paper + context + pending + inked paths with index < completedUnits; pending must remain under inked, not alongside opaque white rectangles.'},indent=2)+'\n')
 # Half-complete example; runtime can draw any exact count from the paths.
 comp=Image.alpha_composite(paper,context);comp=Image.alpha_composite(comp,Image.open(OUT/f'{name}_pending.png'));dc=ImageDraw.Draw(comp)
 for unit in paths[:max(1,pr['unitCount']//2)]:
  for line in unit['polylines']:dc.line([tuple(pt) for pt in line],fill=ink,width=4)
 dc.text((W-260,H-60),f'{pr["unitCount"]//2} / {pr["unitCount"]} pieces',font=font(20),fill=ink)
 comp.save(OUT/f'{name}_example.png')
print('BLUEPRINTS',len(data['projects']),'projects; all unit vectors and separate RGBA layers')
