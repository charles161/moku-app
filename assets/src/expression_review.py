from PIL import Image,ImageDraw,ImageFont
from pathlib import Path
import json
ROOT=Path(__file__).resolve().parents[1];P=ROOT/'previews'
FONT='/System/Library/Fonts/Supplemental/Arial.ttf'
def font(n):return ImageFont.truetype(FONT,n)
MOODS=['happy','content','proud','curious','concerned','disappointed','annoyed','sleepy']
# Review-only normalization: visible figure fits a 120 pt square @2x.
# Runtime PNGs retain their full, identically registered 768px canvases.
def specimen(path,size=240):
 a=Image.open(path).convert('RGBA');a=a.crop(a.getchannel('A').getbbox());a.thumbnail((size,size),Image.Resampling.LANCZOS)
 box=Image.new('RGBA',(size,size));box.alpha_composite(a,((size-a.width)//2,size-a.height));return box
canvas=Image.new('RGB',(1120,1260),'#f2ece1');d=ImageDraw.Draw(canvas)
d.text((30,20),'Expression revision · 120 pt figures @2x',font=font(29),fill='#514a40')
d.text((30,65),'120 pt visible figures. Left: v0. Right: revised. No symbol assists.',font=font(20),fill='#71675b')
for i,mood in enumerate(MOODS):
 x=30+(i%2)*550;y=112+(i//2)*282
 d.text((x,y),mood,font=font(22),fill='#514a40')
 for col,folder in enumerate(['moods-before','moods']):
  im=specimen(P/folder/f'{mood}.png')
  canvas.paste(im,(x+col*260,y+30),im)
canvas.save(P/'moods-before-after.png',dpi=(144,144))
# Label-free native 1x view to avoid large-image inspection masking small-size failures.
im=Image.new('RGB',(560,320),'#f2ece1')
for i,mood in enumerate(MOODS):
 a=specimen(P/'moods'/f'{mood}.png',120);im.paste(a,(10+(i%4)*140,10+(i//4)*160),a)
im.save(P/'moods-unlabelled-120.png',dpi=(72,72))
# Each column is a 120pt canvas @2x. Three low weights show onset and continuity.
im=Image.new('RGB',(1090,870),'#f2ece1');d=ImageDraw.Draw(im)
d.text((25,15),'Micro-expressions · content baseline · 120 pt @2x',font=font(26),fill='#514a40')
for c,name in enumerate(['brow_raise_L','brow_raise_R','lips_press','eyes_narrow']):
 d.text((20+c*270,65),name,font=font(20),fill='#514a40')
 for r,w in enumerate([20,35,50]):
  a=specimen(P/'micro'/f'{name}_{w}.png');x=15+c*270;y=92+r*255;im.paste(a,(x,y),a);d.text((x,y+232),f'{w/100:.2f}',font=font(18),fill='#71675b')
im.save(P/'micro-expressions.png',dpi=(144,144))
im=Image.new('RGB',(900,210),'#f2ece1');d=ImageDraw.Draw(im)
for i,name in enumerate(['sparkles','question','sweat','steam','zzz','heart']):
 a=Image.open(ROOT/'symbols'/f'{name}.png').resize((120,120),Image.Resampling.LANCZOS);im.paste(a,(15+150*i,25),a);d.text((15+150*i,160),name,font=font(18),fill='#514a40')
im.save(P/'symbols.png')
print('Wrote before/after, unlabelled 1x, micro-expression and manpu review grids')

# Creative direction acceptance artifacts, with no symbol assistance.
if (P/'creative/happy_front.png').exists():
 board=Image.new('RGB',(1120,1260),'#f2ece1');bd=ImageDraw.Draw(board)
 bd.text((25,20),'Moods v1 · front / usual gaze · 120 pt @2x',font=font(28),fill='#514a40')
 for i,m in enumerate(MOODS):
  x=30+(i%2)*550;y=90+(i//2)*288;bd.text((x,y),m,font=font(21),fill='#514a40')
  for c,v in enumerate(['front','gaze']):
   a=specimen(P/'creative'/f'{m}_{v}.png');board.paste(a,(x+c*260,y+30),a)
 board.save(P/'moods_v1.png',dpi=(144,144))
 sil=Image.new('RGB',(1120,630),'#f2ece1');sd=ImageDraw.Draw(sil);sd.text((20,15),'Silhouettes · 120 pt @2x · no labels',font=font(25),fill='#514a40')
 order=['curious','disappointed','content','happy','annoyed','sleepy','proud','concerned']
 for i,m in enumerate(order):
  a=specimen(P/'creative'/f'{m}_gaze.png');black=Image.new('RGBA',a.size,'#25251f');black.putalpha(a.getchannel('A'));sil.paste(black,(15+(i%4)*280,60+(i//4)*280),black)
 sil.save(P/'moods_v1_silhouette.png',dpi=(144,144))
 for theme,color in [('light','#f1efe9'),('dark','#24282e')]:
  board=Image.new('RGB',(1120,660),color);bd=ImageDraw.Draw(board)
  for i,m in enumerate(order):
   a=specimen(P/'creative'/f'{m}_gaze.png');x=15+(i%4)*280;y=20+(i//4)*310;board.paste(a,(x,y),a);bd.text((x+110,y+250),str(i+1),font=font(22),fill='#8d8984')
  board.save(P/f'stranger-test-{theme}.png',dpi=(144,144))
 (ROOT/'reports/stranger-test-key.json').write_text(json.dumps({'status':'awaiting five independent human participants; no recognition rates claimed','numberToMood':dict(enumerate(order,1)),'display':'144 dpi images: display each 240px specimen at 120 pt, never fit the entire sheet to a narrow viewport','choices':MOODS,'thresholds':{'happy':4,'curious':4,'concerned':4,'disappointed':4,'annoyed':4,'sleepy':4,'content':3,'proud':3}},indent=2)+'\n')
