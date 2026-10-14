import AppKit
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let review = root.appendingPathComponent("app/MokuVisual/screenshots/review")
func image(_ path: String) -> CGImage { let url = root.appendingPathComponent(path); let source = CGImageSourceCreateWithURL(url as CFURL, nil)!; return CGImageSourceCreateImageAtIndex(source, 0, nil)! }
func alphaCrop(_ image: CGImage) -> CGImage {
    let w=image.width,h=image.height; var bytes=[UInt8](repeating:0,count:w*h*4)
    let context=CGContext(data:&bytes,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
    var x0=w,y0=h,x1=0,y1=0
    for y in 0..<h { for x in 0..<w where bytes[(y*w+x)*4+3]>32 { x0=min(x0,x);y0=min(y0,y);x1=max(x1,x);y1=max(y1,y) } }
    return image.cropping(to:CGRect(x:x0,y:y0,width:max(1,x1-x0+1),height:max(1,y1-y0+1))) ?? image
}
func sheet(width:Int,height:Int,output:String,draw:(CGContext)->Void) {
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    let graphics=NSGraphicsContext(bitmapImageRep:bitmap)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=graphics
    let c=graphics.cgContext;c.setFillColor(NSColor(red:0.94,green:0.92,blue:0.87,alpha:1).cgColor);c.fill(CGRect(x:0,y:0,width:width,height:height));draw(c)
    NSGraphicsContext.restoreGraphicsState();try! bitmap.representation(using:.png,properties:[:])!.write(to:review.appendingPathComponent(output))
}
func label(_ text:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat=15) { (text as NSString).draw(at:CGPoint(x:x,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:.medium),.foregroundColor:NSColor(red:0.23,green:0.29,blue:0.23,alpha:1)]) }
func fit(_ image:CGImage,_ box:CGRect,_ context:CGContext) { let scale=min(box.width/CGFloat(image.width),box.height/CGFloat(image.height)); let w=CGFloat(image.width)*scale,h=CGFloat(image.height)*scale;context.draw(image,in:CGRect(x:box.midX-w/2,y:box.minY,width:w,height:h)) }
sheet(width:840,height:340,output:"color-check.png") { context in
    label("COLOR CHECK · 120 pt @2× · unretouched captures",24,307,14)
    let runtime=alphaCrop(image("app/MokuVisual/screenshots/review/mood-content.png"))
    let art=alphaCrop(image("assets/previews/character_front.png"))
    let concept=image("assets/concept/character_sheet.png").cropping(to:CGRect(x:153,y:15,width:320,height:334))!
    for (i,im) in [runtime,art,concept].enumerated() { fit(im,CGRect(x:CGFloat(i)*280+20,y:48,width:240,height:240),context) }
    label("In-app RealityKit",75,18);label("Blender preview",365,18);label("Concept reference",635,18)
}
let moods=["content","happy","proud","curious","concerned","disappointed","annoyed","sleepy"]
sheet(width:1080,height:660,output:"moods-grid.png") { context in
    label("MOKU · ALL EIGHT MOODS · 120 pt @2×",26,620,18)
    for (i,mood) in moods.enumerated() { let x=CGFloat(i%4)*270,y=CGFloat(1-i/4)*290+40
        fit(alphaCrop(image("app/MokuVisual/screenshots/review/mood-\(mood).png")),CGRect(x:x+15,y:y+20,width:240,height:240),context);label(mood.capitalized,x+95,y)
    }
}
