import Foundation
import AppKit
import RealityKit
import Metal
import ImageIO
import UniformTypeIdentifiers

@main struct FaceAtlasProbe {
 @MainActor static func main() async throws {
  let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("assets")
  let imported=try await Entity(contentsOf:root.appendingPathComponent("character/moku_bunny.usdz"))
  guard let sourceRig=imported.findEntity(named:"Rig") as? ModelEntity,let model=sourceRig.model else {fatalError("Rig missing")}
  let decalIndex=model.materials.firstIndex { ($0 as? PhysicallyBasedMaterial)?.name?.replacingOccurrences(of:" ",with:"_")=="Face_decals" }!
  let driver=try FacialMorphs(mesh:model.mesh,materials:model.materials,transform:sourceRig.transformMatrix(relativeTo:nil))
  let rig=ModelEntity(mesh:driver.mesh,materials:model.materials);rig.name="Rig";rig.transform.matrix=sourceRig.transformMatrix(relativeTo:nil);rig.jointTransforms=sourceRig.jointTransforms
  let runtimeRoot=Entity();runtimeRoot.addChild(rig)
  rig.components.remove(BlendShapeWeightsComponent.self)
  let atlas=try await TextureResource(contentsOf:root.appendingPathComponent("character/face_atlas.png"),options:.init(semantic:.color))
  let opacity=try await TextureResource(contentsOf:root.appendingPathComponent("character/face_atlas_opacity.png"),options:.init(semantic:.scalar))
  let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("character/face_atlas.json"))) as! [String:Any]
  let cells=manifest["cells"] as! [[String:Any]]
  let data=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("character/moods.json"))) as! [String:Any]
  let moods=data["moods"] as! [String:[String:Any]]
  let rest=rig.jointTransforms
  let renderer=try RealityRenderer();let camera=PerspectiveCamera();camera.camera.fieldOfViewInDegrees=35
  camera.look(at:[0,0.60,0],from:[0.30,0.90,3.0],relativeTo:nil)
  renderer.cameraSettings.colorBackground = .color(CGColor(red:0,green:0,blue:0,alpha:0));renderer.cameraSettings.isToneMappingEnabled=true
  let lights:[DirectionalLight]=[([-2,3,4],1800),([2,1,2],1100),([0,2,-2],1400)].map { position,intensity in
   let l=DirectionalLight();l.light.intensity=Float(intensity);l.look(at:[0,0.5,0],from:SIMD3<Float>(Float(position[0]),Float(position[1]),Float(position[2])),relativeTo:nil);return l
  }
  renderer.entities.append(contentsOf:[runtimeRoot,camera]+lights);renderer.activeCamera=camera
  let size=512;let device=MTLCreateSystemDefaultDevice()!;let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:size,height:size,mipmapped:false);desc.usage=[.renderTarget,.shaderRead];desc.storageMode = .shared
  let texture=device.makeTexture(descriptor:desc)!;let output=try RealityRenderer.CameraOutput(.singleProjection(colorTexture:texture))
  let raw=CommandLine.arguments.contains("--raw");let shell=CommandLine.arguments.contains("--shell");let folder=root.appendingPathComponent(raw ? "previews/realitykit-raw" : shell ? "previews/realitykit-shell" : "previews/realitykit-decals");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  var records:[[String:Any]]=[]
  for name in ["content","happy","proud","curious","concerned","disappointed","annoyed","sleepy"] {
   let cell=cells.first{$0["name"] as? String == name}!;let pose=moods[name]!
   var weights=(pose["blendShapes"] as! [String:NSNumber]).mapValues{$0.floatValue}
   for key in ["face_decals","eye_hidden_L","eye_hidden_R"] {weights[key]=0}
   for (key,value) in cell["morphs"] as! [String:NSNumber] {weights[key]=value.floatValue}
   if !raw {try driver.apply(weights,gaze:.zero,noticesUser:false,to:rig)}
   var materials=rig.model!.materials;var found=false
   for i in materials.indices {
    if var material=materials[i] as? PhysicallyBasedMaterial,i==decalIndex && !raw {
     material.baseColor = .init(tint:.white,texture:.init(atlas));material.opacityThreshold=0.5
     material.blending = .transparent(opacity:.init(scale:1,texture:.init(opacity)))
     material.textureCoordinateTransform.scale=[0.25,0.25]
     let offset=cell["uvOffset"] as! [Double];material.textureCoordinateTransform.offset=[Float(offset[0]),Float(offset[1])]
     if shell {material.baseColor = .init(tint:.green);material.blending = .opaque;material.opacityThreshold=0}
     materials[i]=material;found=true
    }
   }
   guard found || raw else {fatalError("Face decal material missing")};rig.model!.materials=materials
   let offsets=pose["jointEulerDegrees"] as! [String:[Double]];var joints=rest
   for (i,path) in rig.jointNames.enumerated() {
    let name=String(path.split(separator:"/").last!);let angles=offsets[name] ?? [0,0,0]
    joints[i].rotation=rest[i].rotation * simd_quatf(angle:Float(angles[0]) * .pi/180,axis:[1,0,0]) * simd_quatf(angle:Float(angles[1]) * .pi/180,axis:[0,1,0]) * simd_quatf(angle:Float(angles[2]) * .pi/180,axis:[0,0,1])
   }
   rig.jointTransforms=raw ? rest : joints
   for _ in 0..<3 {
    try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
     do {try renderer.updateAndRender(deltaTime:1/30,cameraOutput:output,onComplete:{_ in c.resume()})}catch{c.resume(throwing:error)}
    }
   }
   var bytes=[UInt8](repeating:0,count:size*size*4);texture.getBytes(&bytes,bytesPerRow:size*4,from:MTLRegionMake2D(0,0,size,size),mipmapLevel:0)
   let provider=CGDataProvider(data:Data(bytes) as CFData)!
   let image=CGImage(width:size,height:size,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:size*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
   let file=folder.appendingPathComponent(name+".png");let dest=CGImageDestinationCreateWithURL(file as CFURL,UTType.png.identifier as CFString,1,nil)!;CGImageDestinationAddImage(dest,image,nil);guard CGImageDestinationFinalize(dest) else {fatalError("PNG write failed")}
   records.append(["mood":name,"atlasCell":cell["index"]!,"uvOffset":cell["uvOffset"]!,"rendered":true]);print("Rendered native atlas cell \(name)")
  }
  let report:[String:Any]=["renderer":"RealityRenderer","shellMaterial":"Face_decals","opacityThreshold":0.5,"opacityAtlas":"character/face_atlas_opacity.png","materialSlotCachedBeforeMutation":true,"textureCoordinateTransformScale":[0.25,0.25],"frames":records,"note":"Offscreen actual imported rig. Authored morph adapter hides original facial geometry and poses body. Atlas selection uses native PBR texture transforms; no per-cell textures substituted."]
  try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent(raw ? "reports/face-raw-realitykit.json" : shell ? "reports/face-shell-realitykit.json" : "reports/face-atlas-realitykit.json"))
 }
}
