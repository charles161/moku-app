#!/usr/bin/env python3
"""Lay out unretouched runtime captures at a shared 120 pt scale, @2x."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import json, sys
root = Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).resolve().parents[1] / 'screenshots/review/v1-p0'
moods = ['content','happy','proud','curious','concerned','disappointed','annoyed','sleepy']
order = ['curious','disappointed','happy','annoyed','content','sleepy','concerned','proud']
font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 24)
small = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 19)
def source(name): return Image.open(root / (name + '.png')).convert('RGBA')
bounds = [source('usual-'+m).getchannel('A').point(lambda p: 255 if p>32 else 0).getbbox() for m in moods]
box = (min(b[0] for b in bounds),min(b[1] for b in bounds),max(b[2] for b in bounds),max(b[3] for b in bounds))
scale = 240/(box[3]-box[1])
def figure(name, silhouette=False):
 im = source(name).crop(box)
 if silhouette:
  alpha = im.getchannel('A').point(lambda p:255 if p>32 else 0)
  im = Image.new('RGBA',im.size,(0,0,0,255)); im.putalpha(alpha)
 return im.resize((round(im.width*scale),240),Image.Resampling.LANCZOS)
def grid(filename, dark=False, silhouette=False, numbered=True):
 bg = '#252B2B' if dark else '#F6F2E9'; fg = '#F6F2E9' if dark else '#364035'
 im=Image.new('RGBA',(1120,690),bg); d=ImageDraw.Draw(im)
 d.text((24,20),'MOKU · 120 pt maximum figure · shared scale @2×',fill=fg,font=font)
 for i,mood in enumerate(order):
  f=figure('usual-'+mood,silhouette);x=i%4*280+(280-f.width)//2;y=i//4*305+70
  im.alpha_composite(f,(x,y));d.text((i%4*280+126,y+246),str(i+1) if numbered else mood,fill=fg,font=font)
 im.convert('RGB').save(root/filename)
grid('stranger-light.png');grid('stranger-dark.png',True);grid('silhouettes.png',silhouette=True)
im=Image.new('RGBA',(2240,710),'#F6F2E9');d=ImageDraw.Draw(im)
d.text((24,15),'Front / usual gaze · unretouched runtime frames · shared 120 pt scale @2×',fill='#364035',font=font)
for row,view in enumerate(['front','usual']):
 for i,m in enumerate(moods):
  f=figure(view+'-'+m);im.alpha_composite(f,(i*280+(280-f.width)//2,row*320+60))
  d.text((i*280+55,row*320+306),m,fill='#364035',font=small)
im.convert('RGB').save(root/'front-and-usual.png')
def strip(filename, names, labels, height=380):
 im=Image.new('RGBA',(len(names)*330,height),'#F6F2E9');d=ImageDraw.Draw(im)
 for i,(name,label) in enumerate(zip(names,labels)):
  f=source(name);f.thumbnail((330,height-45),Image.Resampling.LANCZOS)
  im.alpha_composite(f,(i*330+(330-f.width)//2,0));d.text((i*330+15,height-35),label,fill='#364035',font=small)
 im.convert('RGB').save(root/filename)
strip('gaze-and-smile.png',['gaze-work','gaze-hold','gaze-user','front-happy'],['Watching the work','Holding the work','Looking at you','Happy'])
strip('lantern-arc.png',['lantern-'+s for s in ['focused','noticing','concerned','longDrift','away','carried']],['Focused','Noticing','Concerned','Long drift','Away','Carried'])
strip('drag-drop-throw.png',['picked-up','flung','landed'],['Picked up','Thrown','Landed upright'])
strip('return-beat.png',['return-full-'+s for s in ['arrival','happy','nod','settled']],['Arrival','Happy','Nod','Back to work'])
(root/'stranger-key.json').write_text(json.dumps({str(i+1):m for i,m in enumerate(order)},indent=2)+'\n')
(root/'README.md').write_text('''# Moku v1 P0 review

Open `index.html`. These are offscreen captures from the signed demo, using bundled SPEC v3 art. The real Moku.app was not touched.

- `stranger-light.png`, `stranger-dark.png`: numbered mood test, identical registration and scale, maximum figure height 120 pt at @2x. View at half pixel dimensions on a Retina display; browser gallery does that automatically. Use the key only after answering.
- `silhouettes.png`: the same eight poses filled black from their captured alpha. Target: six distinct silhouettes.
- `front-and-usual.png`, `gaze-and-smile.png`: expression and gaze comparisons.
- `lantern-arc.png`, `return-beat.png`, `drag-drop-throw.png`: settled lantern states, sampled return poses, and real rig pickup/flight/landing poses. Composites include the actual cached renderer and CA layer model values. Manpu uses a representative frame; sparks/animation interpolation require live manual review.
- `manual-control.png`: shared panel with recordable work-state and return controls.
- `checks.json`: held work target, lap/cross transitions, carry/home return, persisted drop and redirected travel evidence.

The five-person test is pending Charles's review. Ask each person to name the eight moods on light and dark desktops. Targets: 4/5 for happy, curious, concerned, disappointed, annoyed, sleepy; 3/5 for content and proud. Ask whether the happy and viewer-facing content poses smile at them (4/5). No human recognition scores are claimed here. Proud is the least certain semantic label.

Physical mouse gestures across apps, multi-display hardware changes, and Spaces need Charles's occupied-desktop review; the stage paths and input recognizer were exercised offscreen with timestamped input and automated tests.
''')
files=['stranger-light.png','stranger-dark.png','silhouettes.png','front-and-usual.png','gaze-and-smile.png','lantern-arc.png','return-beat.png','drag-drop-throw.png','manual-control.png','world-dropdown.png']
html='<!doctype html><meta charset="utf-8"><title>Moku · P0 review</title><style>body{background:#eee9df;color:#354035;font:15px system-ui;margin:32px}img{max-width:100%;height:auto;display:block}figure{margin:30px 0}figcaption{margin:8px 0}a{color:inherit}</style><h1>Moku · P0 review</h1><p>Offscreen runtime captures. <a href="README.md">Review notes and pending human checks</a>.</p>'
for name in files:
 w,h=Image.open(root/name).size
 html+=f'<figure><figcaption>{name}</figcaption><img src="{name}" width="{w//2}" height="{h//2}"></figure>'
(root/'index.html').write_text(html)
