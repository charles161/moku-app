import AppKit
import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "app/MokuVisual/screenshots/review")
func source(_ name: String) -> CGImage {
    let s = CGImageSourceCreateWithURL(directory.appendingPathComponent(name).appendingPathExtension("png") as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(s, 0, nil)!
}
func label(_ text: String, x: CGFloat, y: CGFloat, color: NSColor = .darkGray, size: CGFloat = 14) {
    (text as NSString).draw(at: CGPoint(x:x,y:y), withAttributes: [.font:NSFont.systemFont(ofSize:size,weight:.medium),.foregroundColor:color])
}
func sheet(_ name: String, width: Int, height: Int, draw: (CGContext)->Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    let graphics = NSGraphicsContext(bitmapImageRep:rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
    draw(graphics.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using:.png,properties:[:])!.write(to: directory.appendingPathComponent(name))
}
sheet("gaze-compare.png", width: 660, height: 690) { c in
    c.setFillColor(NSColor(red:0.96,green:0.95,blue:0.92,alpha:1).cgColor);c.fill(CGRect(x:0,y:0,width:660,height:690))
    label("WORK / YOU · 120 pt @2× · unretouched runtime captures",x:24,y:654)
    for row in 0..<2 {
        let y = CGFloat(row * 315)
        if row == 0 { c.setFillColor(NSColor(red:0.13,green:0.16,blue:0.16,alpha:1).cgColor);c.fill(CGRect(x:0,y:0,width:660,height:315)) }
        for (i,name) in ["gaze-work","gaze-user"].enumerated() {
            let x = CGFloat(i * 330 + 45)
            c.draw(source(name),in:CGRect(x:x,y:y+42,width:240,height:240))
            label(i == 0 ? "Watching your work" : "Looking at you",x:x+28,y:y+17,color:row == 0 ? .white : .darkGray)
        }
    }
}
sheet("hover-compare.png",width:960,height:320) { c in
    c.setFillColor(NSColor(red:0.96,green:0.95,blue:0.92,alpha:1).cgColor);c.fill(CGRect(x:0,y:0,width:960,height:320))
    for (i,name) in ["gaze-user","hover-delight","hover-released"].enumerated() {
        let x = CGFloat(i*320+40);c.draw(source(name),in:CGRect(x:x,y:50,width:240,height:240))
        label(["Before","After body dwell","Released → current mood"][i],x:x+20,y:20)
    }
}
