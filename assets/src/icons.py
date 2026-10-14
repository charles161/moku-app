"""Deterministic monochrome menu templates and simple vector celebration sprites."""
from PIL import Image, ImageDraw
from pathlib import Path
import math,subprocess
ROOT=Path(__file__).resolve().parents[1]
names=['seed','sprout','sapling','youngTree','tree','grove','forest','ancientForest']
S=8
for stage,name in enumerate(names):
 im=Image.new('RGBA',(18*S,18*S));d=ImageDraw.Draw(im)
 def line(points,w=1.3):d.line([(x*S,y*S) for x,y in points],fill='black',width=round(w*S),joint='curve')
 def ell(box):d.ellipse(tuple(round(x*S) for x in box),fill='black')
 def tree(x,y,r,h):
  ell((x-r,y-r,x+r,y+r));line([(x,y),(x,y+h)],1.7)
 def pine(x,y,w,h):
  d.polygon([(x*S,y*S),((x-w)*S,(y+h*.75)*S),((x+w)*S,(y+h*.75)*S)],fill='black');line([(x,y+h*.6),(x,y+h)],1.2)
 if stage==0:
  ell((5.8,6.6,12.2,14));d.arc((5.7*S,7*S,12.7*S,16*S),185,270,fill=(0,0,0,0),width=round(S*.9))
 elif stage in [1,2]:
  line([(9,15),(9,8 if stage==1 else 4)])
  ell((2.5,5.0 if stage==1 else 3.2,8.8,9.3 if stage==1 else 7.4));ell((9,3 if stage==1 else 1.5,15.3,7.6 if stage==1 else 5.9))
  if stage==2:ell((4,9,9,12));ell((9,7.7,14,10.7))
 elif stage==3:tree(9,7.1,4.2,8)
 elif stage==4:
  tree(9,7,5.6,8);ell((4,4,9,9));ell((9,3,14,8))
 elif stage==5:
  tree(4.7,9,3.1,6);tree(12.9,9,3.1,6);tree(8.9,5.3,3.8,9.7)
 elif stage==6:
  pine(4.2,5,3.2,10);pine(13.5,5,3.1,10);pine(8.8,1.5,4.0,13.5)
 else:
  ell((1.5,2.5,16.5,9));line([(9,7),(9,15)],2.4);line([(9,10),(5,7)],1.8);line([(9,10),(13,7)],1.8)
  line([(5.2,9),(5.2,11.4)],.85);ell((4.35,11,6,13));line([(12.8,8.5),(12.8,10.5)],.85);ell((12,10.5,13.7,12.5))
 if stage>=1:line([(4.5,15.5),(13.5,15.5)],1)
 for scale in [1,2]:im.resize((18*scale,18*scale),Image.Resampling.LANCZOS).save(ROOT/f'icons/stage_{stage}_{name}{"@2x" if scale==2 else ""}.png')
# Sprites have intrinsic colors; use alpha blending, not additive emission.
for name in ['petal','confetti']:
 im=Image.new('RGBA',(256,256));d=ImageDraw.Draw(im)
 if name=='petal':
  pts=[]
  for i in range(101):
   a=i/100*math.pi*2;r=math.sin(a/2);pts.append((128+72*math.sin(a)*r,28+193*math.sin(a/2)**2))
  d.polygon(pts,fill=(241,174,157,255));d.line([(128,62),(116,125),(128,202)],fill=(255,209,190,200),width=7)
 else:
  d.rounded_rectangle((64,36,183,219),radius=13,fill=(239,189,87,255));d.polygon([(64,36),(183,36),(183,74),(64,185)],fill=(250,218,149,255))
 im.resize((128,128),Image.Resampling.LANCZOS).save(ROOT/f'props/{name}.png')
# Generate a standard macOS iconset only once the rendered master is available.
master=ROOT/'icons/AppIcon.png'
if master.exists():
 folder=ROOT/'icons/AppIcon.iconset';folder.mkdir(exist_ok=True);im=Image.open(master)
 for size in [16,32,128,256,512]:
  for scale in [1,2]:im.resize((size*scale,size*scale),Image.Resampling.LANCZOS).save(folder/f'icon_{size}x{size}{"@2x" if scale==2 else ""}.png')
 subprocess.run(['iconutil','-c','icns',str(folder),'-o',str(ROOT/'icons/AppIcon.icns')],check=True)
