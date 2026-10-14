import AppKit
import SwiftUI
import MokuKit

@MainActor enum Postcard {
    static func image(summary: TodaySummary,scene: HomeScene) async throws -> NSImage {
        let frame = try await scene.postcardFrame()
        let view = NSHostingView(rootView: PostcardView(summary: summary,frame: frame)); view.frame = CGRect(x: 0,y: 0,width: 900,height: 700)
        let image = try ReviewCapture.view(view)
        return NSImage(cgImage: image,size: CGSize(width: 900,height: 700))
    }
    static func present(summary: TodaySummary,scene: HomeScene,from parent: NSWindow) async {
        guard let image = try? await image(summary: summary,scene: scene) else { return }
        let panel = NSPanel(contentRect: CGRect(x: 0,y: 0,width: 640,height: 540),styleMask: [.titled,.closable],backing: .buffered,defer: false)
        panel.title = "A little postcard"; panel.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: PostcardPreview(image: image,date: summary.date,close: { parent.endSheet(panel); panel.contentView = nil; panel.close() })); panel.contentView = content
        _ = await parent.beginSheet(panel)
    }
}
struct PostcardView: View {
    let summary: TodaySummary; let frame: CGImage?
    var percent: Int { DayHouse.percent(Double(summary.focusedMinutes)) }
    var day: String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: summary.date)?.formatted(.dateTime.weekday(.wide).day().month(.wide)) ?? summary.date
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("THE HOUSE WE BUILT TODAY").font(.system(size: 11,weight: .semibold)).tracking(3); Spacer(); Image(systemName: "house") }.padding(.horizontal,36).padding(.top,32)
            // Framed at the render's own proportions, so the home never ends in a hard edge.
            ZStack { HomeSky(); if let frame { Image(decorative: frame,scale: 2).resizable().scaledToFit() } }
                .frame(width: 470*CGFloat(HomeWorldRenderer.pixels.width)/CGFloat(HomeWorldRenderer.pixels.height),height: 470).clipShape(RoundedRectangle(cornerRadius: 9))
            Text(day).font(.system(size: 24,design: .serif))
            Text(percent >= 100 ? "A whole house, built in \(minutesText(summary.focusedMinutes)) of focus." : "\(percent)% of a house, in \(minutesText(summary.focusedMinutes)) of focus.").font(.system(size: 19,design: .serif))
            Text("Every 10 focused minutes adds a piece; four hours builds the whole house.").font(.system(size: 12)).quiet()
            Spacer(minLength: 15)
        }.frame(width: 900,height: 700).background(paper).foregroundStyle(ink).preferredColorScheme(.light)
    }
}
struct PostcardPreview: View {
    let image: NSImage; let date: String; let close: ()->Void
    @State var error: String?
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: image).resizable().scaledToFit()
            if let error { Text(error).font(.caption).quiet() }
            HStack { Button("Done",action: close); Spacer(); SharePostcard(image: image); Button("Save postcard…") { save() }.keyboardShortcut(.defaultAction) }.padding(.horizontal,12)
        }.padding(20).background(paper)
    }
    func save() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Moku-\(date).png"
        guard panel.runModal() == .OK,let url = panel.url,let tiff = image.tiffRepresentation,let bitmap = NSBitmapImageRep(data: tiff),let data = bitmap.representation(using: .png,properties: [:]) else { return }
        do { try data.write(to: url,options: .atomic) } catch { self.error = "Couldn’t save this postcard. Please try another folder." }
    }
}
struct SharePostcard: NSViewRepresentable {
    let image: NSImage
    func makeNSView(context: Context) -> NSButton { let button = NSButton(title: "Share…",target: context.coordinator,action: #selector(Coordinator.share(_:))); button.bezelStyle = .rounded; return button }
    func updateNSView(_ nsView: NSButton,context: Context) { context.coordinator.image = image }
    func makeCoordinator() -> Coordinator { Coordinator(image) }
    @MainActor final class Coordinator: NSObject { var image: NSImage; init(_ image: NSImage) { self.image = image }; @objc func share(_ sender: NSButton) { NSSharingServicePicker(items: [image]).show(relativeTo: sender.bounds,of: sender,preferredEdge: .minY) } }
}
