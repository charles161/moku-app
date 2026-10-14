import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def item(name,tint,rough,plush=False,base=None):
 return {'name':name,'aliases':[name.replace(' ','_')],'baseTint':tint+[1.0], 'tintColorSpace':'linearSRGB','baseTintMode':'multiplyTexture','baseColorTexturePath':base,'roughness':rough,'metallic':0.0,'specular':0.16 if plush else .5,'sheenColor':[.86,.74,.57] if plush else [0,0,0],'sheenColorSpace':'linearSRGB','sheenRoughness':.8 if plush else 1.0,'normalMapPath':'character/plush_normal.png' if plush else None,'normalMapColorSpace':'raw','normalScale':.48 if plush else 1.0,'normalTiling':[1.0,1.0],'uvOffset':[0.0,0.0],'opacity':1.0,'doubleSided':False}
materials=[item('Ivory woven plush',[1,1,1],.93,True,'character/felt_color.png'),item('Ivory face diffuse blush',[1,1,1],.93,True,'character/ivory_felt_albedo.png'),item('Petal pink velour',[1,1,1],.94,True,'character/petal_felt.png'),item('Warm milk plush',[1,1,1],.93,True,'character/milk_felt.png')]
# The body and the pink share one UV layout at half the head's density: their felt normal repeats eight times.
for m in materials[:4]:
 if m['name'] in ('Ivory woven plush','Petal pink velour'):m['normalMapPath']='character/felt_normal.png'
# Look v2: the cream felt's velvet softer and less yellow; the pink felt's pink (a cream sheen washed it out).
for m in materials[:4]:m['sheenColor']=[.82,.58,.52] if m['name']=='Petal pink velour' else [.92,.84,.73]
# The fuzzy edge (fuzz.py): each shell is its felt with an RGBA texture, the felt's colour and an alpha of fibres.
for felt,fuzz,image in [('Ivory woven plush','Ivory woven fuzz','felt_fuzz'),('Ivory face diffuse blush','Ivory face fuzz','face_fuzz'),('Warm milk plush','Warm milk fuzz','milk_fuzz')]:
 # No sheen or specular on the shell: RealityKit keeps them at full strength however see-through a surface is.
 m=dict(next(x for x in materials if x['name']==felt));m.update(name=fuzz,aliases=[fuzz.replace(' ','_')],baseColorTexturePath=f'character/{image}.png',sheenColor=[0,0,0],specular=0.0);materials.append(m)
materials+=[item('Cocoa glass eyes',[1,1,1],.23,base='character/eye_ring.png'),item('Deep cocoa pupil',[1,1,1],.19,base='character/eye_iris.png'),item('Softbox catchlights',[1,.94,.8],.25),item('Espresso embroidery',[.105,.042,.023],.95),item('Rose nose',[.43,.16,.14],.77)]
blush=item('Expression blush',[1,1,1],1,base='character/expression_blush.png');blush.update({'opacityMode':'textureAlpha','preserveImportedOpacity':True,'alphaMode':'blend','opacityTexturePath':'character/expression_blush.png','alphaChannel':'a','alphaCutoff':None});materials.append(blush)
materials.extend([item('Petal mouth interior',[.578,.202,.202],.92),item('Soft pink tongue',[.791,.367,.352],.93)])
face=item('Face decals',[1,1,1],1,base='character/face_decal_blank.png');face.update({'opacityMode':'textureAlpha','preserveImportedOpacity':True,'alphaMode':'cutout','alphaCutoff':.5,'opacityTexturePath':'character/face_decal_blank.png','atlasPath':'character/face_atlas.png','atlasOpacityPath':'character/face_atlas_opacity.png','atlasOpacitySemantic':'scalar','atlasManifestPath':'character/face_atlas.json','optIn':True});materials.append(face)
kitPath=ROOT/'world/kit/materials.json'
if kitPath.exists():
 for entry in json.loads(kitPath.read_text())['materials']:
  m=item(entry['name'],entry['baseTint'][:3],entry['roughness']);m.update(entry);m['aliases']=[entry['name'].replace(' ','_')];materials.append(m)
materials.extend([item('Name tag cotton paper',[.92,.84,.66],.96),item('Name tag ink',[.20,.12,.07],.94)])
# Moku's home: the burrow and the treehouse (assets/src/home_kit.py).
homePath=ROOT/'world/home/materials.json'
if homePath.exists():
 for entry in json.loads(homePath.read_text())['materials']:
  m=item(entry['name'],entry['baseTint'][:3],entry['roughness'],plush=entry['normalMapPath'] is not None);m.update(entry);m['aliases']=[entry['name'].replace(' ','_')];materials.append(m)
materials.extend([item('Walnut bark',[.23,.12,.065],.92),item('Daisy milk',[.95,.86,.63],.85),item('Sage ceramic',[.24,.36,.24],.4),item('Water surface',[.25,.43,.39],.13)])
materials[-1]['metallic']=.15
d={'schemaVersion':1,'assetRoot':'assets','pathResolution':'All texture paths are relative to the assets directory, not this JSON file.','matching':'Exact material name or aliases; preserve unmatched materials.','normalConvention':'OpenGL tangent space +Y, RGB XYZ mapped from -1..1 to 0..1','notes':['Normal texture already bakes four mirrored felt repeats; runtime tiling MUST remain 1x1.','Preserve imported texture coordinates and blend shapes. Apply overrides to a copy of each existing PhysicallyBasedMaterial.','RealityKit PhysicallyBasedMaterial exposes sheen color but not sheen roughness on the installed macOS SDK. Apply sheenColor, keep sheenRoughness as authoring metadata; do not substitute clearcoat.','White baseTint on textured ivory materials preserves baked cream color and blush. Texture color is sRGB; numeric tint values are linear.'],'materials':materials}
(ROOT/'runtime/materials.json').write_text(json.dumps(d,indent=2)+'\n')
