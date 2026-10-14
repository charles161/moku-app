from PIL import Image,ImageDraw,ImageFont
from pathlib import Path
import json,html,math
ROOT=Path(__file__).resolve().parents[1]
FONT='/System/Library/Fonts/Supplemental/Arial.ttf'
def font(n):return ImageFont.truetype(FONT,n)
def sheet(paths,name,title,cols=4,cell=(260,300)):
 rows=math.ceil(len(paths)/cols);im=Image.new('RGB',(cols*cell[0],rows*cell[1]+75),'#f0eadf');d=ImageDraw.Draw(im);d.text((25,22),title,font=font(24),fill='#473f34')
 for i,p in enumerate(paths):
  a=Image.open(p).convert('RGBA');a.thumbnail((cell[0]-18,cell[1]-45),Image.Resampling.LANCZOS);x=(i%cols)*cell[0];y=(i//cols)*cell[1]+70
  im.paste(a,(x+(cell[0]-a.width)//2,y),a);d.text((x+15,y+cell[1]-35),p.stem.replace('_',' '),font=font(16),fill='#514b40')
 im.save(ROOT/f'previews/{name}.png')
groups=[('Moods',sorted((ROOT/'previews/moods').glob('*.png'))),('Micro',sorted((ROOT/'previews/micro').glob('*.png'))),('Native atlas',sorted((ROOT/'previews/realitykit-decals').glob('*.png'))),('Creative gaze',sorted((ROOT/'previews/creative').glob('*.png'))),('Home v2',sorted((ROOT/'previews/world-v2').glob('focus_*.png'))),('Onboarding',sorted((ROOT/'previews/onboarding').glob('*.png'))),('Poses',sorted((ROOT/'previews/poses').glob('*.png'))),('Forest stages',sorted((ROOT/'previews').glob('stage_*.png')))]
for title,paths in groups:sheet(paths,title.lower().replace(' ','_'),title)
# Template icon review at native and Retina sizes on both toolbar tones.
im=Image.new('RGB',(720,260),'#eeeae2');d=ImageDraw.Draw(im);d.text((20,15),'Menu templates · 18 pt',font=font(22),fill='black')
for i,p in enumerate(sorted((ROOT/'icons').glob('stage_*@2x.png'))):
 a=Image.open(p).convert('RGBA');x=30+i*85;im.paste(a,(x,75),a);d.text((x,130),str(i),font=font(16),fill='black')
 d.rounded_rectangle((x-8,178,x+46,233),radius=8,fill='#31382f');white=Image.new('RGBA',a.size,'white');white.putalpha(a.getchannel('A'));im.paste(white,(x,187),white)
im.save(ROOT/'previews/menu_icons.png')
entries=[];issues=[]
paths=[ROOT/'previews/crossed-arms-fit.png',ROOT/'previews/folded-paws-fit.png',ROOT/'previews/character.png',*sorted((ROOT/'previews').glob('character_*.png')),*[p for _,ls in groups for p in ls],ROOT/'previews/water_cup.png',ROOT/'previews/lantern.png',ROOT/'icons/AppIcon.png',*sorted((ROOT/'icons').glob('stage_*.png')),ROOT/'props/petal.png',ROOT/'props/confetti.png']
for p in paths:
 im=Image.open(p);assert im.mode=='RGBA',(p,im.mode);alpha=im.getchannel('A');bbox=alpha.getbbox();assert bbox and alpha.getextrema()[0]==0,(p,'no transparency')
 entry={'path':str(p.relative_to(ROOT)),'width':im.width,'height':im.height,'alphaBounds':list(bbox)}
 if 'moods' in p.parts or 'poses' in p.parts:assert im.size==(768,768),p
 if p.name.startswith('stage_') and 'icons' in p.parts:assert im.size==((36,36) if '@2x' in p.name else (18,18)),p
 if (bbox[0]<=0 or bbox[1]<=0 or bbox[2]>=im.width or bbox[3]>=im.height) and 'icons' not in p.parts:issues.append(str(p.relative_to(ROOT)))
 entries.append(entry)
(ROOT/'previews/manifest.json').write_text(json.dumps({'schemaVersion':1,'entries':entries,'edgeContact':issues},indent=2)+'\n')
assert not issues,('Possible clipped previews',issues)
sections=[('Character', [ROOT/'previews/character.png',ROOT/'previews/compare_sheet.png']),('Expression revision',[ROOT/'previews/moods-before-after.png',ROOT/'previews/moods-unlabelled-120.png',ROOT/'previews/micro-expressions.png',ROOT/'previews/symbols.png',ROOT/'previews/moods_v1.png',ROOT/'previews/moods_v1_silhouette.png',ROOT/'previews/stranger-test-light.png',ROOT/'previews/stranger-test-dark.png',ROOT/'previews/folded-paws-fit.png']),*groups,('V1 P0',[ROOT/'previews/moods_v1_realitykit.png',ROOT/'previews/paws-v1.png',ROOT/'previews/face-atlas-review.png',ROOT/'previews/lantern-states.png',ROOT/'previews/poses/carry_lantern.png']),('Props and icons',[ROOT/'previews/water_cup.png',ROOT/'previews/lantern.png',ROOT/'props/petal.png',ROOT/'props/confetti.png',ROOT/'icons/AppIcon.png',ROOT/'previews/menu_icons.png'])]
body='<p><a href="anim-v2/index.html">Animation v2: all 120 pt strips and MP4s</a> · <a href="world-v2/popover-370.png">Home at 370 pt</a> · <a href="world-v2/house-stages.jpg">Eight home stages</a></p>'
for title,ps in sections:
 body+=f'<h2>{html.escape(title)}</h2><div class="grid">'
 for p in ps:
  rel='../'+str(p.relative_to(ROOT));body+=f'<a href="{rel}"><img src="{rel}" alt="{html.escape(p.stem)}" loading="lazy"><span>{html.escape(p.stem.replace("_"," "))}</span></a>'
 body+='</div>'
page='''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Moku asset review</title><style>body{margin:0 auto;padding:40px 24px;max-width:1240px;background:#f4eee3;color:#343d31;font:16px system-ui}h1{font-size:40px;margin-bottom:8px}h2{margin-top:48px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:18px}.grid a{color:inherit;text-decoration:none;background:#e7e2d6;border-radius:18px;padding:12px}.grid img{width:100%;height:240px;object-fit:contain}span{display:block;padding:8px}a:focus-visible{outline:3px solid #4d7b56}p{line-height:1.6}</style><h1>Moku asset review</h1><p>Production renders, transparent compositor frames, and the 120 pt concept comparison. Click an image for full resolution.<br><a href="../SPEC.md">Asset contract</a> · <a href="manifest.json">Preview manifest</a> · <a href="../runtime/materials.json">Runtime materials</a></p>'''+body+'</html>'
(ROOT/'previews/index.html').write_text(page)
print('PASS',len(entries),'RGBA images; dimensions and framing checked')
