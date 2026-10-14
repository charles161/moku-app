"""Small original manpu drawings, supersampled into transparent six-frame atlases."""
from pathlib import Path
from PIL import Image,ImageDraw,ImageFont
import math,json
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'symbols';OUT.mkdir(exist_ok=True)
S=4;SIZE=256
COL={'cocoa':'#4A2E26','cream':'#fff4dc','gold':'#fff4dc','rose':'#d99093','blue':'#fff4dc','cloud':'#fff4dc'}
FONT='/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf'
def poly(d,pts,fill):d.polygon([(round(x*S),round(y*S)) for x,y in pts],fill=fill)
def ellipse(d,box,fill):d.ellipse(tuple(round(v*S) for v in box),fill=fill)
def line(d,pts,fill,width):d.line([(round(x*S),round(y*S)) for x,y in pts],fill=fill,width=round(width*S),joint='curve')
def base(name):
 im=Image.new('RGBA',(SIZE*S,SIZE*S));d=ImageDraw.Draw(im)
 if name=='sparkles':
  for x,y,r in [(109,130,56),(180,65,24),(183,180,18)]:
   pts=[(x,y-r),(x+r*.28,y-r*.28),(x+r,y),(x+r*.28,y+r*.28),(x,y+r),(x-r*.28,y+r*.28),(x-r,y),(x-r*.28,y-r*.28)]
   poly(d,pts,COL['cocoa']);poly(d,[(x+(a-x)*.80,y+(b-y)*.80) for a,b in pts],COL['gold'])
 elif name=='question':
  d.text((128*S,124*S),'?',font=ImageFont.truetype(FONT,177*S),anchor='mm',fill=COL['gold'],stroke_width=5*S,stroke_fill=COL['cocoa'])
 elif name=='sweat':
  pts=[]
  for i in range(121):
   a=2*math.pi*i/120;x=128+42*math.sin(a)*(1-.55*math.cos(a));y=127-77*math.cos(a);pts.append((x,y))
  poly(d,pts,COL['cocoa']);poly(d,[(128+(x-128)*.88,127+(y-127)*.91) for x,y in pts],COL['blue']);line(d,[(109,113),(101,137),(103,150)],COL['cream'],8)
 elif name=='steam':
  for x,y,r in [(86,136,31),(123,117,43),(168,131,35),(145,156,27),(103,157,24)]:ellipse(d,(x-r-4,y-r-4,x+r+4,y+r+4),COL['cocoa'])
  for x,y,r in [(86,136,31),(123,117,43),(168,131,35),(145,156,27),(103,157,24)]:ellipse(d,(x-r,y-r,x+r,y+r),COL['cloud'])
  ellipse(d,(77,192,93,207),COL['cloud']);ellipse(d,(99,179,120,199),COL['cloud'])
  for x,y in [(101,127),(140,114)]:line(d,[(x-6,y+9),(x,y-4),(x+8,y-7)],COL['cream'],5)
 elif name=='zzz':
  for x,y,size in [(82,165,61),(127,120,76),(177,67,91)]:
   d.text((x*S,y*S),'z',font=ImageFont.truetype(FONT,size*S),anchor='mm',fill=COL['blue'],stroke_width=3*S,stroke_fill=COL['cocoa'])
 elif name=='exclamation':
  d.text((128*S,124*S),'!',font=ImageFont.truetype(FONT,177*S),anchor='mm',fill=COL['cream'],stroke_width=5*S,stroke_fill=COL['cocoa'])
 elif name=='bounce':
  for x,flip in [(81,1),(175,-1)]:
   for offset in [0,22]:
    pts=[(x-flip*offset-flip*20*math.sin(math.pi*t/30),67+122*t/30) for t in range(31)]
    line(d,pts,COL['cocoa'],8)
 elif name=='sigh':
  for x,y,r in [(97,137,26),(131,121,35),(166,135,31),(132,154,23)]:ellipse(d,(x-r-4,y-r-4,x+r+4,y+r+4),COL['cocoa'])
  for x,y,r in [(97,137,26),(131,121,35),(166,135,31),(132,154,23)]:ellipse(d,(x-r,y-r,x+r,y+r),COL['cream'])
  poly(d,[(67,143),(39,174),(98,165)],COL['cream'])
 elif name=='pop_vein':
  for pts in [[(82,52),(82,93),(52,93)],[(122,52),(122,93),(160,93)],[(82,137),(82,176),(52,176)],[(122,137),(122,176),(160,176)]]:
   line(d,pts,'#E7A1A1',16)
 elif name=='hmph':
  for pts in [[(63,93),(102,107),(114,125)],[(59,141),(94,141),(112,149)],[(144,120),(158,102),(195,90)],[(145,148),(164,140),(199,143)]]:line(d,pts,COL['cocoa'],8)
 elif name=='heart':
  pts=[]
  for i in range(241):
   a=math.pi*2*i/240;pts.append((128+4.25*16*math.sin(a)**3,122-4.25*(13*math.cos(a)-5*math.cos(2*a)-2*math.cos(3*a)-math.cos(4*a))))
  poly(d,pts,COL['cocoa']);poly(d,[(128+(x-128)*.88,122+(y-122)*.88) for x,y in pts],COL['rose']);ellipse(d,(91,76,103,91),COL['cream'])
 return im.resize((SIZE,SIZE),Image.Resampling.LANCZOS)
records=[]
moods={'sparkles':['happy','proud'],'question':['curious'],'sweat':['concerned'],'steam':['annoyed'],'zzz':['sleepy'],'heart':['pat_reaction'],'bounce':['happy'],'exclamation':['curious'],'sigh':['disappointed'],'pop_vein':['annoyed'],'hmph':['proud','annoyed']}
for name in moods:
 glyph=base(name);atlas=Image.new('RGBA',(SIZE*6,SIZE));scales=[.72,.9,1,.98,.96,.94];alphas=[.35,.85,1,1,.80,.25]
 for i,(scale,alpha) in enumerate(zip(scales,alphas)):
  w=round(SIZE*scale);frame=glyph.resize((w,w),Image.Resampling.LANCZOS);frame.putalpha(frame.getchannel('A').point(lambda x:round(x*alpha)))
  atlas.alpha_composite(frame,(i*SIZE+(SIZE-w)//2,(SIZE-w)//2-round(i*1.5)))
 atlas.save(OUT/f'{name}_sheet.png');glyph.save(OUT/f'{name}.png')
 for density in [2,3]:
  glyph.resize((24*density,24*density),Image.Resampling.LANCZOS).save(OUT/f'{name}@{density}x.png')
  atlas.resize((24*density*6,24*density),Image.Resampling.LANCZOS).save(OUT/f'{name}_sheet@{density}x.png')
 records.append({'name':name,'for':moods[name],'sheet':f'{name}_sheet.png','still':f'{name}.png','frameCount':6,'columns':6,'frameSizePixels':[256,256],'frameDurationSeconds':.12 if name!='zzz' else .22,'loop':False,'pivotNormalized':[.5,.5],'anchor':'head','offsetFromHeadInCanvasNormalized':[-.25,-.13] if name=='question' else [.26,-.19] if name=='sweat' else [.26,-.10],'sizeInCanvasNormalized':.2,'referenceCanvasPoints':120,'displaySizePoints':24,'visibleGlyphSizePoints':[round((glyph.getchannel('A').getbbox()[2]-glyph.getchannel('A').getbbox()[0])/256*24,2),round((glyph.getchannel('A').getbbox()[3]-glyph.getchannel('A').getbbox()[1])/256*24,2)],'densities':{'2x':{'sheet':f'{name}_sheet@2x.png','still':f'{name}@2x.png','frameSizePixels':[48,48]},'3x':{'sheet':f'{name}_sheet@3x.png','still':f'{name}@3x.png','frameSizePixels':[72,72]}},'reducedMotion':{'stillFrame':2,'animate':'opacity only','durationSeconds':.7}})
timing={
 'sparkles':{'happyEntrySeconds':1.2,'proudTwinkleEverySeconds':4,'twinkleSeconds':.7},
 'question':{'durationSeconds':6,'bobPoints':1},
 'exclamation':{'durationSeconds':.4,'then':'question'},
 'sweat':{'slidePoints':3,'slideSeconds':1.2,'thenHold':True},
 'bounce':{'durationSeconds':1.2,'oscillations':2},
 'sigh':{'durationSeconds':1.5,'entryOnly':True},
 'pop_vein':{'pulseScales':[1,1.25,1,1.25,1],'thenHoldOpacity':.8},
 'zzz':{'risePoints':12,'durationSeconds':3,'repeatEverySeconds':4,'staggerSeconds':[0,.5,1]},
 'heart':{'durationSeconds':.7,'trigger':'pat'},
 'hmph':{'durationSeconds':.8,'entryOnly':True},
 'steam':{'durationSeconds':.8,'entryOnly':True,'optionalAlternativeTo':'pop_vein'}}
for record in records:record['creativeTiming']=timing[record['name']]
d={'schemaVersion':1,'alpha':'straight RGBA','coordinates':'top-left origin, +x right, +y down','headAnchorForShared768Preview':json.loads((ROOT/'previews/compositor.json').read_text())['neutralHeadAnchorPx'],'compositorManifest':'previews/compositor.json','placement':'At 120 pt canvas, multiply offsets by 120 pt and add to projected head anchor. For 3D, project the head joint; keep sprites screen-facing. Pivot is center. Do not scale by alpha bounds.','behavior':'Optional sixth expression channel. Follow creativeTiming for brief entry, held or periodically twinkling states; a held sprite is static. Faces/ears carry the mood without symbols. Disappointment emits one sigh then nothing persists. Micro-expressions never trigger manpu. Cancel symbols on speech/travel/hidden state as appropriate; Reduce Motion uses the static glyph.','sprites':records}
(OUT/'manifest.json').write_text(json.dumps(d,indent=2)+'\n')
print('Wrote eleven original manpu atlases and static sprites at master, @2x and @3x')
