"""Tetsu's hologram (next-wave.md §2): today's rocket as a small translucent projection, one picture per stage of the
day's home (the pad, the gantry, the hull, fins & nose, launch-ready), drawn as glowing cyan line art with scanlines.
The app shows the one for today's stage over Tetsu's head when a piece lands (RobotTalents.swift, Hologram).

Writes assets/world/tetsu/hologram/stage-<1…5>.png and a review strip, previews/tetsu/hologram-stages.png.
"""
import math
from pathlib import Path
from PIL import Image,ImageDraw,ImageFilter

ROOT=Path(__file__).resolve().parents[1]
W,H,S=160,200,4                     # the picture, drawn at S times and scaled down for clean lines
CYAN=(40,200,235)

def stage(n):
 img=Image.new('L',(W*S,H*S),0);d=ImageDraw.Draw(img)
 def P(x,y):return (x*S,y*S)
 def line(pts,w=1.6,v=255):d.line([P(*p) for p in pts],fill=v,width=int(w*S),joint='curve')
 def ellipse(cx,cy,rx,ry,w=1.6,v=255):d.ellipse([P(cx-rx,cy-ry),P(cx+rx,cy+ry)],outline=v,width=int(w*S))
 # 1 The pad: the launch ring, its hazard stripes, the chalk circle.
 ellipse(80,184,64,9,1.2,150)
 ellipse(80,181,46,7,1.8)
 ellipse(80,180,26,4,1.2,190)
 for k in range(12):
  a=2*math.pi*k/12;x,y=80+46*math.cos(a),181+7*math.sin(a)
  if math.sin(a)>-.2:line([(x-2,y),(x+2,y)],2.4,230)
 if n>=2:
  # 2 The gantry: a lattice tower at the left with its crew walkway reaching toward the rocket.
  for x in (20,38):line([(x,182),(x,62)],1.4)
  for y in range(176,66,-14):line([(20,y),(38,y-14)],.9,170);line([(38,y),(20,y-14)],.9,170);line([(20,y),(38,y)],.9,200)
  line([(18,62),(40,62)],1.6)
  line([(38,104),(60,104)],1.4);line([(38,110),(60,110)],.9,170)
 if n>=3:
  # 3 The hull: the body with its round hatch, two portholes and the bands.
  line([(64,174),(64,96),(96,96),(96,174)],1.8)
  line([(64,174),(96,174)],1.4)
  for y in (112,150):line([(64,y),(96,y)],1.0,190)
  ellipse(80,124,5,5,1.3);ellipse(80,138,5,5,1.3)
  ellipse(80,162,6,6,1.0,180)
 if n>=4:
  # 4 Fins & nose: the nose cone, the side fins and the back fin's edge.
  pts=[]
  for k in range(21):
   t=k/20;y=96-58*t;x=16*math.cos(t*math.pi/2)**.9;pts.append((80-x,y))
  line(pts+[(80+x,y) for x,y in [(80-p[0],p[1]) for p in reversed(pts)]],1.8)
  line([(64,148),(50,176),(64,172)],1.6);line([(96,148),(110,176),(96,172)],1.6);line([(80,152),(80,178)],1.2,200)
 if n>=5:
  # 5 Launch-ready: the beacon on the gantry, the flag, the countdown light, lit portholes, a breath of steam.
  ellipse(29,56,3,3,2.2);line([(29,53),(29,40)],1.0,200);line([(29,40),(41,44),(29,48)],1.2,220)
  d.ellipse([P(76,120),P(84,128)],fill=200);d.ellipse([P(76,134),P(84,142)],fill=200)
  for k,(x,y,r) in enumerate([(66,186,5),(58,183,4),(96,186,5),(104,183,4)]):ellipse(x,y,r,r*.6,1.0,140)
  for x,y in [(122,60),(132,90),(116,30)]:line([(x-3,y),(x+3,y)],1.0,200);line([(x,y-3),(x,y+3)],1.0,200)
 lines=img.resize((W,H),Image.LANCZOS)
 glow=lines.filter(ImageFilter.GaussianBlur(3.2))
 alpha=Image.eval(Image.merge('L',[lines]),lambda v:v)
 out=Image.new('RGBA',(W,H),(0,0,0,0));px=out.load();lp=lines.load();gp=glow.load()
 for y in range(H):
  scan=.55 if y%3==2 else 1.0                      # scanlines
  for x in range(W):
   v=min(255,lp[x,y]+gp[x,y]*1.3)*scan
   if v<2:continue
   px[x,y]=(CYAN[0],CYAN[1],CYAN[2],int(min(255,v*.9)))
 return out

if __name__=='__main__':
 folder=ROOT/'world/tetsu/hologram';folder.mkdir(parents=True,exist_ok=True)
 strip=Image.new('RGBA',(W*5+60,H+20),(16,22,28,255))
 for n in range(1,6):
  img=stage(n);img.save(folder/f'stage-{n}.png');strip.alpha_composite(img,(10+(W+10)*(n-1),10))
 (ROOT/'previews/tetsu').mkdir(parents=True,exist_ok=True);strip.save(ROOT/'previews/tetsu/hologram-stages.png')
 print('wrote world/tetsu/hologram/stage-1…5.png')
