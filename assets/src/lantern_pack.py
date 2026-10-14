from pathlib import Path
from PIL import Image,ImageDraw,ImageFont
import json,math
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'lantern';states=[]
anchors=json.loads((OUT/'render_anchors.json').read_text())
for name,intensity,color in [('lit',1,'#F3B04E'),('low',.65,'#E6CC98'),('ember',.15,'#D9A25A')]:
 files={}
 for density in [2,3]:
  size=(26*density,34*density);body=Image.open(OUT/f'body_{name}_master.png').resize(size,Image.Resampling.LANCZOS);flame=Image.open(OUT/f'flame_{name}_master.png').resize(size,Image.Resampling.LANCZOS)
  body.save(OUT/f'body_{name}@{density}x.png');flame.save(OUT/f'flame_{name}@{density}x.png')
  complete=Image.alpha_composite(body,flame);complete.save(OUT/f'{name}@{density}x.png')
  files[f'{density}x']={'body':f'body_{name}@{density}x.png','flame':f'flame_{name}@{density}x.png','composite':f'{name}@{density}x.png','sizePixels':list(size)}
 states.append({'name':name,'intensity':intensity,'flameColorSRGB':color,'files':files})
# A tiny original warm spark, no particle-system runtime dependency.
n=192;im=Image.new('RGBA',(n,n));d=ImageDraw.Draw(im);cx=cy=n/2
for radius in range(36,1,-1):
 a=int(45*(1-radius/36)**1.3);d.ellipse((cx-radius,cy-radius,cx+radius,cy+radius),fill=(246,190,98,a))
d.polygon([(96,27),(105,86),(123,96),(105,106),(96,165),(87,106),(69,96),(87,86)],fill='#F3B04E');d.ellipse((90,83,102,109),fill='#FFE7B0');im.save(OUT/'spark_master.png')
for density in [2,3]:im.resize((12*density,12*density),Image.Resampling.LANCZOS).save(OUT/f'spark@{density}x.png')
manifest={'schemaVersion':1,'sourceModel':'props/lantern.usdz','displaySizePoints':[26,34],'alpha':'straight RGBA PNG','layers':'Use body + separate flame at identical bounds, or the composite; do not use both paths together. All states share one camera and pixel registration.','anchorsNormalizedTopLeft':anchors,'states':states,'spark':{'displaySizePoints':[12,12],'2x':'spark@2x.png','3x':'spark@3x.png','visibleGlyphPoints':[3.4,8.6],'colorsSRGB':['#F3B04E','#FFE7B0']},'carryAttachment':'character/prop_attachments.json#carry_lantern','carry':'Hide 2D sprite during live carrying; attach props/lantern.usdz via published hand_R wrapper. Re-show 2D sprite after setting down.','glassMaterialNames':['Amber glow','Amber_glow'],'carryEmission':'Multiply the imported glass emission by the current normalized WorkState intensity, clamped to at least 0.15. Do not switch the carried lantern to full brightness just because it is 3D.','minimumIntensity':.15,'returnFlare':{'peakIntensity':1.4,'riseSeconds':.25,'sparkCount':[3,5],'sparkLifetimeSeconds':1.2,'sparkRisePoints':[20,40]},'glow':{'colorSRGB':'#F6BE62','radiusPoints':22,'groundPoolFocusedPoints':[120,36],'groundPoolFocusedOpacity':.22,'groundPoolFloorOpacity':.03},'faceLight':{'colorSRGB':'#FFC874','radiusPoints':90,'blendMode':'softLight','mask':'current character image alpha'},'reducedMotion':'Crossfade phases over 1 s; no gutter, sparks or motion. Never extinguish the ember.','runtime':'Core Animation sprites/gradients; no per-frame RealityKit rendering for the standing lantern. Runtime owns WorkState timing, gaze/light masks and power checks.'}
(OUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
font='/System/Library/Fonts/Supplemental/Arial.ttf';canvas=Image.new('RGB',(1380,500),'#efe8dc');draw=ImageDraw.Draw(canvas);draw.text((25,20),'Lantern · registered body + flame · 26 × 34 pt',font=ImageFont.truetype(font,26),fill='#51483d')
for i,s in enumerate(states):
 for j,kind in enumerate(['body_','flame_','']):
  a=Image.open(OUT/f"{kind}{s['name']}@3x.png");a=a.resize((156,204),Image.Resampling.NEAREST);x=25+i*450+j*145;y=110;canvas.paste(a,(x,y),a)
 draw.text((45+i*450,350),s['name'],font=ImageFont.truetype(font,22),fill='#51483d')
 # Native @2x visible point-sized composite below the magnified technical views.
 a=Image.open(OUT/f"{s['name']}@2x.png");canvas.paste(a,(80+i*450,392),a)
canvas.save(ROOT/'previews/lantern-states.png')
print('Lantern: three states, independent flame/body, composites @2x/@3x and spark')
