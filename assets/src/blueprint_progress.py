from pathlib import Path
from PIL import Image,ImageDraw,ImageFont
import json
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'world/blueprints';data=json.loads((ROOT/'world/layouts.json').read_text())
font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',22)
for hours in [0,1,3,5,20,25,100,120]:
 points=hours*60;pr=max((p for p in data['projects'] if p['startPoints']<=points),key=lambda p:p['index']);name=pr['id'];count=min(pr['unitCount'],(points-pr['startPoints'])//10)
 im=Image.open(OUT/f'{name}_paper.png').convert('RGBA')
 for layer in ['context','pending']:im=Image.alpha_composite(im,Image.open(OUT/f'{name}_{layer}.png'))
 d=ImageDraw.Draw(im);vectors=json.loads((OUT/f'{name}.json').read_text())
 for unit in vectors['units'][:count]:
  for line in unit['polylines']:d.line([tuple(pt) for pt in line],fill=vectors['inkColor'],width=4)
 d.text((744,708),f'{count} / {pr["unitCount"]} pieces',font=font,fill=vectors['inkColor']);im.save(OUT/f'progress_{hours:03d}h.png')
