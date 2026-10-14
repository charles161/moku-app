from pathlib import Path
from PIL import Image,ImageDraw,ImageFont
import json,math
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'previews/world-v2';layout=json.loads((ROOT/'world/layouts.json').read_text())
font=lambda n:ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',n)
colors={'ink':'#3A4839','sub':'#63705F','bg':'#EEEADC'}
cards=[]
for hours in [0,3,25,120]:
 r=next(r for r in layout['homePreviews'] if r['name']==f'focus_{hours:03d}h');im=Image.new('RGB',(740,840),colors['bg']);d=ImageDraw.Draw(im)
 d.text((30,24),f'{hours} hours · {hours} trees',font=font(30),fill=colors['ink']);d.text((30,65),r['project'].replace('_',' ').title()+f' · {r["completedUnits"]} of {r["unitCount"]} pieces',font=font(22),fill=colors['sub'])
 scene=Image.open(OUT/f'focus_{hours:03d}h.png').convert('RGBA').resize((740,666),Image.Resampling.LANCZOS);im.paste(scene,(0,70),scene)
 bp=Image.open(ROOT/f'world/blueprints/progress_{hours:03d}h.png').convert('RGBA').resize((272,204),Image.Resampling.LANCZOS);im.paste(bp,(30,591),bp)
 d.text((329,693),'Every focused minute',font=font(22),fill=colors['ink']);d.text((329,724),"builds Moku's home.",font=font(22),fill=colors['ink']);d.text((329,766),f'Return stones shown: {r["exampleReturns"]} (fixture)',font=font(15),fill=colors['sub'])
 im.save(OUT/f'card_{hours:03d}h.png');cards.append(im)
review=Image.new('RGB',(1480,1680),colors['bg'])
for i,im in enumerate(cards):review.paste(im,((i%2)*740,(i//2)*840))
review.save(OUT/'home-hours-review.jpg',quality=94)
# Native 370pt-size review, including readable flat blueprints.
small=Image.new('RGB',(1480,420),colors['bg'])
for i,im in enumerate(cards):small.paste(im.resize((370,420),Image.Resampling.LANCZOS),(i*370,0))
small.save(OUT/'popover-370.png')
for label,paths,cols in [('house-stages',sorted(OUT.glob('home_stage_*.png')),4),('tree-species',sorted(OUT.glob('tree_*.png')),3),('forest-prefixes',[OUT/f'focus_{h:03d}h.png' for h in [1,5,20,100]],4)]:
 cell=360;out=Image.new('RGB',(cols*cell,math.ceil(len(paths)/cols)*(cell+35)),colors['bg']);d=ImageDraw.Draw(out)
 for i,p in enumerate(paths):
  a=Image.open(p).convert('RGBA');a.thumbnail((cell,cell));x=(i%cols)*cell;y=(i//cols)*(cell+35);out.paste(a,(x+(cell-a.width)//2,y),a);d.text((x+12,y+cell),p.stem.replace('_',' '),font=font(17),fill=colors['ink'])
 out.save(OUT/(label+'.jpg'),quality=94)
print('WORLD_REVIEW four hours, eight stages, six species, four planting prefixes')
