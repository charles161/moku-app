import Foundation
import AppKit
import RealityKit
import Metal
import ImageIO
import UniformTypeIdentifiers
@main struct ControlProbe {
 @MainActor static func main() async throws {
  let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("assets")
  let imported=try await Entity(contentsOf:root.appendingPathComponent("character/moku_bunny.usdz"))
  let source=imported.findEntity(named:"Rig") as! ModelEntity;let model=source.model!
  let driver=try FacialMorphs(mesh:model.mesh,materials:model.materials,transform:source.transformMatrix(relativeTo:nil))
  let rig=ModelEntity(mesh:driver.mesh,materials:model.materials);rig.transform.matrix=source.transformMatrix(relativeTo:nil);rig.jointTransforms=source.jointTransforms;rig.components.remove(BlendShapeWeightsComponent.self)
  let renderer=try RealityRenderer();let camera=PerspectiveCamera();camera.camera.fieldOfViewInDegrees=35;camera.look(at:[0,0.60,0],from:[0.30,0.90,3],relativeTo:nil)
  renderer.cameraSettings.colorBackground = .color(CGColor(red:0,green:0,blue:0,alpha:0));renderer.cameraSettings.isToneMappingEnabled=true
  let lights:[DirectionalLight]=[([-2,3,4],1800),([2,1,2],1100),([0,2,-2],1400)].map { pos,power in
   let l=DirectionalLight();l.light.intensity=Float(power);l.look(at:[0,0.5,0],from:SIMD3<Float>(Float(pos[0]),Float(pos[1]),Float(pos[2])),relativeTo:nil);return l
  }
  renderer.entities.append(contentsOf:[rig,camera]+lights);renderer.activeCamera=camera
  let size=384;let device=MTLCreateSystemDefaultDevice()!;let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:size,height:size,mipmapped:false);desc.usage=[.renderTarget,.shaderRead];desc.storageMode = .shared
  let texture=device.makeTexture(descriptor:desc)!;let output=try RealityRenderer.CameraOutput(.singleProjection(colorTexture:texture));let folder=root.appendingPathComponent("previews/anim-v2/native-controls");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  let doc=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("character/ear_transitions.json"))) as! [String:Any];let paths=doc["paths"] as! [[String:Any]]
  var records:[[String:Any]]=[]
  for kind in ["blink","ears_lift","ear_antenna_L","ear_antenna_R"] {
   for step in 0...16 {
    let phase=Float(step)/16;var weights:[String:Float]=["blink_L":0.18,"blink_R":0.18,"smile":0.3]
    if kind=="blink" {weights["blink_L"]=phase;weights["blink_R"]=phase}
    else {
     let keys=paths.first{$0["target"] as? String==kind}!["keyposes"] as! [[String:Any]];let segments=keys.count-1;let f=phase*Float(segments);let i=min(segments-1,Int(f));let t=f-Float(i)
     for (key,value) in keys[i]["blendShapes"] as! [String:NSNumber] {weights[key]=value.floatValue*(1-t)}
     for (key,value) in keys[i+1]["blendShapes"] as! [String:NSNumber] {weights[key]=value.floatValue*t}
    }
    try driver.apply(weights,gaze:.zero,noticesUser:false,to:rig)
    for _ in 0..<3 {try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
     do {try renderer.updateAndRender(deltaTime:1/30,cameraOutput:output,onComplete:{_ in c.resume()})}catch{c.resume(throwing:error)}
    }}
    var bytes=[UInt8](repeating:0,count:size*size*4);texture.getBytes(&bytes,bytesPerRow:size*4,from:MTLRegionMake2D(0,0,size,size),mipmapLevel:0)
    let provider=CGDataProvider(data:Data(bytes) as CFData)!;let image=CGImage(width:size,height:size,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:size*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
    let file=folder.appendingPathComponent(String(format:"%@-%02d.png",kind,step));let dest=CGImageDestinationCreateWithURL(file as CFURL,UTType.png.identifier as CFString,1,nil)!;CGImageDestinationAddImage(dest,image,nil);guard CGImageDestinationFinalize(dest) else {fatalError("PNG write failed")}
    records.append(["control":kind,"phase":phase,"rendered":true])
   }
  }
  try JSONSerialization.data(withJSONObject:["renderer":"RealityRenderer","frames":records],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("reports/controls-realitykit.json"));print("PASS native controls: \(records.count) frames")
 }
}
