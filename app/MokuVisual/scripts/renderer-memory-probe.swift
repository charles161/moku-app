import Foundation
import CoreGraphics

import RealityKit
import Metal

@main struct RendererMemoryProbe {
    @MainActor static func memory(_ phase: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        if status == KERN_SUCCESS { print("\(phase): resident \(Double(info.resident_size)/1048576), physical \(Double(info.phys_footprint)/1048576) MiB") }
    }
    @MainActor static func main() async throws {
        memory("before renderer")
        let renderer = try RealityRenderer()
        let camera = PerspectiveCamera()
        renderer.entities.append(camera); renderer.activeCamera = camera
        renderer.cameraSettings.colorBackground = .color(CGColor(red:0,green:0,blue:0,alpha:0))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:320,height:320,mipmapped:false)
        descriptor.usage = [.renderTarget,.shaderRead]; descriptor.storageMode = .shared
        let texture = MTLCreateSystemDefaultDevice()!.makeTexture(descriptor:descriptor)!
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture:texture))
        memory("before empty frame")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do { try renderer.updateAndRender(deltaTime:1/30,cameraOutput:output,onComplete:{ _ in continuation.resume() }) }
            catch { continuation.resume(throwing:error) }
        }
        memory("after empty frame")
        try await Task.sleep(for:.seconds(15))
        memory("settled")
    }
}
