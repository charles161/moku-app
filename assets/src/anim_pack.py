from pathlib import Path
from PIL import Image,ImageDraw,ImageFont
import json,subprocess,shutil,math
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'previews/anim-v2'
font=lambda n:ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',n)
# One fixed image scale for every frame: v0 rest is 120 pixels high on this sheet.
base=Image.open(OUT/'ears_lift/000.png').convert('RGBA');bbox=base.getchannel('A').getbbox();scale=120/(bbox[3]-bbox[1]);size=round(256*scale)
def strip(name,paths,indices=None):
 if not paths:return
 chosen=indices if indices is not None else [round(i*(len(paths)-1)/7) for i in range(8)]
 im=Image.new('RGB',(len(chosen)*200,245),'#EFE9DE');d=ImageDraw.Draw(im);d.text((14,10),name.replace('_',' '),font=font(19),fill='#483B2C')
 for n,i in enumerate(chosen):
  a=Image.open(paths[i]).convert('RGBA').resize((size,size),Image.Resampling.LANCZOS);im.paste(a,(n*200+(200-size)//2,34),a);d.text((n*200+14,220),f'{i/(len(paths)-1):.2f}',font=font(12),fill='#635947')
 im.save(OUT/(name+'-strip.png'));return im
records=json.loads((ROOT/'reports/anim-v2-frames.json').read_text()) if (ROOT/'reports/anim-v2-frames.json').exists() else []
strips=[]
for row in records:
 name=row['name'];paths=sorted((OUT/name).glob('*.png'))
 # Show the three raised/impact pairs explicitly; uniform samples alias the quick taps.
 phases=[0,.23/2.4,.34/2.4,.78/2.4,.89/2.4,1.33/2.4,1.44/2.4,1] if name=='build_hammer' else None
 im=strip(name,paths,[round(p*(len(paths)-1)) for p in phases] if phases else None)
 if im:strips.append(im)
 # Encode actual rendered frame sequence, matted onto ivory. Repeat loops three times.
 dest=OUT/(name+'.mp4')
 filt='color=c=0xEFE9DE:s=256x256:r=24[bg];[bg][0:v]overlay=shortest=1,scale=512:512:flags=lanczos,format=yuv420p[review]'
 cmd=['ffmpeg','-y','-loglevel','error','-framerate',str(row['fps']),'-i',str(OUT/name/'%03d.png'),'-filter_complex',filt,'-map','[review]','-frames:v',str(round(row['duration']*24)),'-r','24','-c:v','libx264','-crf','18','-movflags','+faststart',str(dest)]
 subprocess.run(cmd,check=True)
 if row['loop']:
  one=OUT/(name+'-onecycle.mp4');dest.replace(one)
  subprocess.run(['ffmpeg','-y','-loglevel','error','-stream_loop','2','-i',str(one),'-c','copy','-movflags','+faststart',str(dest)],check=True);one.unlink()
for name in ['ears_lift','ear_antenna_L','ear_antenna_R','blink']:
 paths=sorted((OUT/name).glob('*.png'));strip(name,paths,list(range(0,len(paths),2)) if len(paths)>9 else list(range(len(paths))))
for alias,target in {'walk_cycle':'hop_cycle','stand_up':'sit_up_tall','sit_down':'settle_down'}.items():
 for suffix in ['.mp4','-strip.png']:
  if (OUT/(target+suffix)).exists():shutil.copyfile(OUT/(target+suffix),OUT/(alias+suffix))
for group in range(math.ceil(len(strips)/5)):
 page=Image.new('RGB',(1600,245*len(strips[group*5:group*5+5])),'#EFE9DE')
 for row,im in enumerate(strips[group*5:group*5+5]):page.paste(im,(0,row*245))
 page.save(OUT/f'review-{group+1}.jpg',quality=92)
html='<html><meta charset="utf-8"><title>Moku motion v2</title><style>body{background:#efe9de;color:#483b2c;font:16px system-ui;margin:32px}img{width:100%;max-width:1600px}video{width:360px}section{margin:32px 0}</style><h1>Motion v2 · 120 pt fixed-scale strips</h1><p>Actual Blender render frames from the same pose samples as the exported USDZ. Native import validation is separate.</p>'
html+='<section><h2>Ear paths and blink closure</h2><p>Native capture uses RealityRenderer; the three path strips below are authoring frames. Read ear_transitions.json for phase routing.</p><img src="native-controls.jpg">'
for name in ['ears_lift','ear_antenna_L','ear_antenna_R','blink']:html+=f'<img src="{name}-strip.png">'
html+='</section>'
for row in records:
 n=row['name'];html+=f'<section><h2>{n}</h2><img src="{n}-strip.png"><video controls loop muted playsinline src="{n}.mp4"></video><img style="width:256px" src="{n}-profile.png"></section>'
(OUT/'index.html').write_text(html+'</html>')
print('PACKED',len(records),'clips')

# Native control sheet is separate from authoring proof and refreshed from actual captures.
native=OUT/'native-controls'
if native.exists():
 im=Image.new('RGB',(1800,800),'#EFE9DE');d=ImageDraw.Draw(im)
 for row,kind in enumerate(['blink','ears_lift','ear_antenna_L','ear_antenna_R']):
  for col,i in enumerate(range(0,17,2)):
   a=Image.open(native/f'{kind}-{i:02d}.png').convert('RGBA');a.thumbnail((190,180));im.paste(a,(col*200,row*200+20),a);d.text((col*200+8,row*200),f'{kind} {i/16:.2f}',font=font(12),fill='#483B2C')
 im.save(OUT/'native-controls.jpg',quality=95)
