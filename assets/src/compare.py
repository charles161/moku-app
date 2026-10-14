"""Deterministic review contact sheet. Original artwork remains untouched."""
from PIL import Image, ImageDraw, ImageFont
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
font='/System/Library/Fonts/Supplemental/Arial.ttf'
def f(n):return ImageFont.truetype(font,n)
def opaque_thumb(path,height):
 im=Image.open(path).convert('RGBA');box=im.getchannel('A').getbbox();im=im.crop(box);im.thumbnail((height*2,height),Image.Resampling.LANCZOS);return im
sheet=Image.open(ROOT/'concept/character_sheet.png').convert('RGBA')
# Selected full-body cells from the immutable concept sheet, reviewed visually.
refs=[sheet.crop((151,20,460,352)),sheet.crop((475,20,728,352))]
canvas=Image.new('RGB',(1240,760),'#f3ece0');d=ImageDraw.Draw(canvas)
d.text((35,24),'Moku • concept fidelity review',font=f(27),fill='#463b30')
d.text((35,62),'Top: 120 pt at 2×. Bottom: 120 px at 1×. Transparent renders cropped to visible bounds.',font=f(17),fill='#726657')
labels=['Concept · front','Model · front','Concept · ¾','Model · ¾']
ims=[refs[0],opaque_thumb(ROOT/'previews/character_front.png',400),refs[1],opaque_thumb(ROOT/'previews/character.png',400)]
for i,(im,label) in enumerate(zip(ims,labels)):
 thumb=im.copy();thumb.thumbnail((280,240),Image.Resampling.LANCZOS);x=25+i*305
 canvas.paste(thumb,(x+(280-thumb.width)//2,130),thumb)
 d.text((x+20,385),label,font=f(19),fill='#463b30')
 thumb=im.copy();thumb.thumbnail((160,120),Image.Resampling.LANCZOS);canvas.paste(thumb,(x+(280-thumb.width)//2,470),thumb)
 d.text((x+70,615),'120 px',font=f(16),fill='#726657')
d.text((35,690),'Check: head/body proportion • lop-ear frame • eye placement • felt surface • paw pads',font=f(20),fill='#463b30')
canvas.save(ROOT/'previews/compare_sheet.png')
