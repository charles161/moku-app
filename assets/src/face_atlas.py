"""Original transparent face decals, in physical face coordinates for the skinned shell."""
from pathlib import Path
from PIL import Image,ImageDraw
import json,math
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'character';N=512
COCOA='#4A2E26';PINK='#C97C7C';TONGUE='#E6A3A0'
def point(x,z):return ((x+.27)/.54*N,(.765-z)/.365*N)
def curve(draw,points,width=.015,color=COCOA):
 pts=[]
 for i in range(len(points)-1):
  p0=points[max(0,i-1)];p1=points[i];p2=points[i+1];p3=points[min(len(points)-1,i+2)]
  for j in range(25):
   t=j/24;coords=[.5*((2*p1[a])+(-p0[a]+p2[a])*t+(2*p0[a]-5*p1[a]+4*p2[a]-p3[a])*t*t+(-p0[a]+3*p1[a]-3*p2[a]+p3[a])*t*t*t) for a in range(2)];pts.append(point(*coords))
 w=round(width/.54*N);draw.line(pts,fill=color,width=w,joint='curve')
 for x,y in [pts[0],pts[-1]]:draw.ellipse((x-w/2,y-w/2,x+w/2,y+w/2),fill=color)
def oval(draw,x,z,rx,rz,color):
 a=point(x-rx,z+rz);b=point(x+rx,z-rz);draw.ellipse((*a,*b),fill=color)
def eye(draw,side,kind):
 x=side*.134
 if kind=='happy':curve(draw,[(x-.068,.576),(x,.621),(x+.068,.576)],.021)
 elif kind=='proud':curve(draw,[(x-.065,.589),(x,.565),(x+.065,.589)],.016)
 elif kind=='sleep':curve(draw,[(x-.065,.584),(x,.566),(x+.065,.580)],.015)
def mouth(draw,kind):
 if kind=='open_smile':
  # Flat top, round lower bowl (D rotated into a smile), with a soft pink tongue.
  pts=[point(-.059,.489),point(.059,.489)]
  for j in range(41):
   t=j/40;pts.append(point(.059*math.cos(math.pi*t),.489-.048*math.sin(math.pi*t)))
  draw.polygon(pts,fill=PINK);oval(draw,0,.451,.026,.009,TONGUE)
 elif kind=='smile':curve(draw,[(-.052,.488),(-.025,.474),(0,.480),(.025,.474),(.052,.488)],.015)
 elif kind=='wide':curve(draw,[(-.060,.49),(-.028,.476),(0,.483),(.028,.476),(.060,.49)],.015)
 elif kind=='o':oval(draw,0,.479,.016,.021,COCOA);oval(draw,0,.480,.009,.014,PINK)
 elif kind=='wave':curve(draw,[(-.040,.479),(-.020,.485),(0,.478),(.020,.484),(.040,.478)],.013)
 elif kind=='sad':curve(draw,[(-.039,.466),(0,.484),(.039,.466)],.015)
 elif kind=='pout':curve(draw,[(.024,.49),(-.001,.483),(.017,.474),(-.005,.465),(.022,.459)],.016)
 elif kind=='press':curve(draw,[(-.035,.479),(0,.477),(.035,.479)],.015)
 elif kind=='pff':oval(draw,.018,.478,.023,.015,COCOA);oval(draw,.018,.478,.014,.008,PINK)
def brows(draw,kind):
 if kind=='one':curve(draw,[(.096,.707),(.135,.724),(.18,.711)],.017);return
 for s in [-1,1]:
  if kind=='concern':curve(draw,[(s*.09,.71),(s*.13,.69),(s*.18,.677)],.018)
  elif kind=='sad':curve(draw,[(s*.09,.677),(s*.13,.666),(s*.18,.655)],.017)
  elif kind=='angry':curve(draw,[(s*.09,.626),(s*.135,.65),(s*.18,.667)],.018)
  elif kind=='proud':curve(draw,[(s*.095,.697),(s*.135,.712),(s*.18,.700)],.016)
cells=[('content','smile',None,{}),('happy','open_smile',None,{'L':'happy','R':'happy'}),('proud','wide','proud',{'L':'proud','R':'proud'}),('curious','o','one',{}),('concerned','wave','concern',{}),('disappointed','sad','sad',{}),('annoyed','pout','angry',{}),('sleepy','o',None,{'L':'sleep'}),('smile_at_you','wide',None,{}),('wink','smile',None,{'L':'happy'}),('lip_press','press',None,{}),('small_pout','pout',None,{}),('pff','pff',None,{}),('blink','smile',None,{'L':'sleep','R':'sleep'}),('brow_raise_L','smile','one',{}),('blank',None,None,{})]
atlas=Image.new('RGBA',(2048,2048));records=[]
for i,(name,m,b,eyes) in enumerate(cells):
 im=Image.new('RGBA',(N,N));d=ImageDraw.Draw(im)
 if m:mouth(d,m)
 if b:brows(d,b)
 for side,kind in eyes.items():eye(d,1 if side=='L' else -1,kind)
 col=i%4;row=i//4;atlas.paste(im,(col*N,row*N));im.save(OUT/f'face_{name}.png')
 records.append({'name':name,'index':i,'column':col,'rowFromTop':row,'uvScale':[.25,.25],'uvOffset':[col/4,row/4],'blenderUVOffset':[col/4,1-(row+1)/4],'hideEyes':list(eyes),'morphs':{'face_decals':0 if name=='blank' else 1,**{'eye_hidden_'+side:1 for side in eyes}},'standalone':f'character/face_{name}.png'})
atlas.save(OUT/'face_atlas.png');a=atlas.getchannel('A');Image.merge('RGB',(a,a,a)).save(OUT/'face_atlas_opacity.png');Image.new('RGBA',(4,4)).save(OUT/'face_decal_blank.png')
d={'schemaVersion':1,'atlasPath':'character/face_atlas.png','opacityAtlasPath':'character/face_atlas_opacity.png','opacitySemantic':'scalar','sizePixels':[2048,2048],'cellSizePixels':[512,512],'columns':4,'rows':4,'material':'Face decals','aliases':['Face_decals'],'defaultTexturePath':'character/face_decal_blank.png','defaultMode':'morphs; transparent shell until runtime enables atlas mode','alphaCutoff':.5,'shellOffsetMeters':.0005,'uvCoordinates':'u increases with character +X; v increases with head height. uvOffset is the tested RealityKit imported-mesh transform (rowFromTop/4). blenderUVOffset is the authoring USD bottom-left transform. Do not interchange these values.','enable':'Cache the Face_decals material slot before mutation: imported names can disappear after texture changes. Set the color atlas as base color, separate opacityAtlasPath as PhysicallyBasedMaterial.Opacity scalar texture with scale 1, transparent blending, white tint and opacity threshold 0.5. Base-color alpha alone is insufficient in the tested RealityRenderer path. Set scale/offset from the selected cell. Apply face_decals=1 to hide 3D mouths/brows, and per-eye hidden morphs from this cell. Keep skinned geometry, ear/posture/lid morphs and open-eye joints.','disable':'Restore transparent default texture and face_decals/eye_hidden_L/eye_hidden_R=0; authored mood morphs provide the complete fallback face.','microCells':{'brow_raise_L':{'cell':'brow_raise_L','mirrorU':False},'brow_raise_R':{'cell':'brow_raise_L','mirrorU':True},'lips_press':{'cell':'lip_press'},'pout':{'cell':'small_pout'},'cheek_release':{'cell':'pff'},'slow_blink':{'cell':'blink'},'eyes_narrow':{'mode':'existing open-eye morph'}},'microComposition':'Cells are complete faces, not additive masks. For 0.2–0.5 subtle atlas micros, crossfade cached current/micro face frames at that strength; mirror brow_raise_L in U for the right brow. Retain the full geometry-morph mode where atlas micro compositing is not integrated. Do not hide the original lips and expect lips_press alone to change a painted mouth.','blinkTransitionMilliseconds':60,'cells':records}
(OUT/'face_atlas.json').write_text(json.dumps(d,indent=2)+'\n');print('16-cell 2048px face atlas and manifests generated')
