"""Tetsu's face, as pixel art: the LED matrix behind its visor and every frame it can show (next-wave.md §7).

The app draws the display (PixelFace.swift) from character/tetsu/pixel_face.json, which this writes: the matrix
(columns, rows, where it sits on the visor), the palette, and the eye frames as ASCII art, one per expression and
blink step, drawn for the eye on the viewer's left and mirrored for the other. `#` is a dot at full brightness, `+`
half, `-` a quarter, `.` off. The face weights every companion shares pick a frame (blink_L at 0.7 is the "narrow"
step, brows_angry is the cross eyes in amber, eyes_dot the sleepy dots with a "z"), so a change is always a whole
frame: crisp, with no in-between.

Run on its own to write the JSON and a review sheet of every frame (previews/tetsu/pixel-face.png).
"""
import json,math
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
COLS,ROWS=30,16                      # the matrix: a dot every PITCH metres on the visor, centred on it
PITCH=.0122
# The texture covers the whole visor (so its UVs stay inside 0…1): TEXTURE cells of PITCH, the matrix at ORIGIN in it.
TEXTURE=(36,24);ORIGIN=(3,4)
EYES=((9,7),(20,7))                  # each eye's centre (column, row from the top), viewer's left then right
MOUTH=(14.5,12.5)
ZED=(25,3)
PROMPT,CURSOR=(3,12),(8.5,14.5)      # the ask's ">_" low on the left of the matrix: the prompt, the cursor after it

# Each eye frame is drawn for the viewer's left eye and centred on EYES (an even width centres between columns).
FRAMES={
 'open':['+####+','######','######','######','######','######','######','+####+'],
 'wide':['.#####.','#######','#######','#######','#######','#######','#######','#######','.#####.'],
 'half':['+####+','######','######','+####+'],
 'narrow':['+#####+','#######'],
 'line':['+######+'],
 'happy':['..###..','.#####.','##...##','#.....#'],
 'proud':['######','######','######','######','+####+'],
 'concerned':['...##.','.#####','######','######','######','######','+####+'],
 'sad':['....##','..####','######','######','+####+'],
 'sad_half':['...+##','+#####','+####+'],
 'angry':['##....','####..','######','######','+####+'],
 'angry_half':['##+...','#####+','+####+'],
 'dot':['##','##'],
 'heart':['.##.##.','#######','#######','.#####.','..###..','...#...'],
 'off':['.'],
}
# Where each frame's rows sit: 'centre' on the eye's centre row, 'bottom' with its last row on the open eye's last.
ANCHOR={'proud':'bottom','sad':'bottom','sad_half':'bottom','angry':'bottom','angry_half':'bottom','concerned':'bottom','dot':'low','happy':'centre'}
GLYPHS={
 'z':['#####','...#.','..#..','.#...','#####'],
 'z_small':['####','..#.','.#..','####'],
 'mouth_smile':['#....#','.####.'],
 'mouth_o':['.#.','#.#','.#.'],
 # Mouths for moments the eyes alone don't carry: let down (a frown under sad eyes), a pout or pressed lips (a flat
 # line), a huff when cross (a wavy line), and the ask's prompt: a ">" and a cursor that blinks, waiting for you.
 'mouth_frown':['.####.','#....#'],
 'mouth_flat':['#####'],
 'mouth_huff':['.#.#.#.','#.#.#.#'],
 'prompt':['#..','.#.','..#','.#.','#..'],
 'cursor':['####','####'],
}
PALETTE={'content':[.30,.92,1.0],'cross':[1.0,.58,.10],'heart':[1.0,.34,.46],'sleepy':[.30,.92,1.0]}
DISPLAY={'cellPixels':8,'dotSize':[6,5],'offLevel':.07,'glow':.42,'scanline':.55}

def data():
 return {'schemaVersion':1,'about':'Tetsu\'s LED face: tetsu_pixels.py writes it, PixelFace.swift draws it.','columns':COLS,'rows':ROWS,'pitchMetres':PITCH,
  'eyes':[list(e) for e in EYES],'mouth':list(MOUTH),'zed':list(ZED),'prompt':list(PROMPT),'cursor':list(CURSOR),'frames':FRAMES,'anchors':ANCHOR,'glyphs':GLYPHS,'palette':PALETTE,
  'spinner':{'centre':[14.5,7.5],'radius':5.2,'dots':12,'tail':6},'display':DISPLAY,
  'texture':{'columns':TEXTURE[0],'rows':TEXTURE[1],'matrixOrigin':list(ORIGIN)}}

def write(directory):
 (Path(directory)/'pixel_face.json').write_text(json.dumps(data(),indent=1)+'\n')

def brushed_normal(path):
 """Tetsu's brushed-metal normal map (character/tetsu/brushed_normal.png): fine tileable streaks along U. The shells'
 UVs run round each part, so it reads as turned, machined metal."""
 from PIL import Image
 import random
 rnd=random.Random(7);n=256
 waves=[(rnd.randint(8,90),rnd.random()*6.283,rnd.random()) for _ in range(40)]
 rows=[sum(a*math.sin(2*math.pi*f*y/n+p) for f,p,a in waves) for y in range(n)]
 lo,hi=min(rows),max(rows);rows=[(r-lo)/(hi-lo) for r in rows]
 img=Image.new('RGB',(n,n));px=img.load()
 for y in range(n):
  for x in range(n):
   # A streak's height varies a little along its length so it isn't a perfect stripe.
   dy=(rows[(y+1)%n]-rows[y-1])*(.8+.2*math.sin(2*math.pi*(x*3+y*7)/n))
   ny=-dy*.9;l=math.sqrt(ny*ny+1);px[x,y]=(128,int((ny/l*.5+.5)*255),int((1/l*.5+.5)*255))
 img.save(path)

def sheet(path):
 """Every eye frame and glyph on a dark matrix, large: the art itself, for review."""
 from PIL import Image,ImageDraw
 names=list(FRAMES)+list(GLYPHS);cell=10;pad=2;w=14;h=12
 cols=6;rows=math.ceil(len(names)/cols)
 img=Image.new('RGB',(cols*w*cell+(cols+1)*pad*cell,rows*(h+2)*cell+pad*cell),(8,10,12));d=ImageDraw.Draw(img)
 for i,name in enumerate(names):
  art=FRAMES.get(name) or GLYPHS[name];ox=(i%cols)*(w+pad)*cell+pad*cell;oy=(i//cols)*(h+2)*cell+pad*cell
  d.text((ox,oy-cell*1.6+cell),name,fill=(170,190,200))
  for r in range(h):
   for c in range(w):
    ch='.'
    rr=r-(h-len(art))//2;cc=c-(w-len(art[0]))//2
    if 0<=rr<len(art) and 0<=cc<len(art[0]):ch=art[rr][cc]
    level={'#':1,'+':.5,'-':.25}.get(ch,.07);col=tuple(int(255*min(1,v*level+.02)) for v in PALETTE['content'])
    d.rectangle([ox+c*cell+1,oy+cell+r*cell+2,ox+c*cell+cell-2,oy+cell+r*cell+cell-3],fill=col)
 img.save(path)

if __name__=='__main__':
 write(ROOT/'character/tetsu');brushed_normal(ROOT/'character/tetsu/brushed_normal.png');(ROOT/'previews/tetsu').mkdir(parents=True,exist_ok=True);sheet(ROOT/'previews/tetsu/pixel-face.png')
 print('wrote pixel_face.json, brushed_normal.png and previews/tetsu/pixel-face.png')
