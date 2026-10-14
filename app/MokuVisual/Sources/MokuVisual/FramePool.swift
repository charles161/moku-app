import CoreGraphics
import Foundation

/// The bytes of Moku's drawn frames, kept and reused. Every frame used to be copied out of a working array into a new
/// 1.6 MB `Data` (more at a bigger size), 30 to 60 times a second while Moku moves: an allocation and a copy a frame,
/// and the allocator held on to the freed blocks (a hundred MB of footprint that came and went with the drawing). Now a
/// frame is read from the GPU straight into a buffer from this pool, the image shows that buffer, and the buffer comes
/// back when the last image of it is let go. Frames the micro-expression cache keeps hold their buffers for good; they
/// don't come back, and the pool makes new ones.
final class FramePool: @unchecked Sendable {
    let byteCount: Int
    /// Buffers kept for the next frames. A frame on screen, the one Core Animation is still copying and the one being
    /// drawn are three; a spare makes four.
    static let kept = 4
    private let lock = NSLock()
    private var free: [UnsafeMutableRawPointer] = []
    private var retired = false

    init(byteCount: Int) { self.byteCount = byteCount }

    func take() -> FrameBuffer {
        lock.lock(); let memory = free.popLast(); lock.unlock()
        return FrameBuffer(pool: self, memory: memory ?? UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16384))
    }

    fileprivate func recycle(_ memory: UnsafeMutableRawPointer) {
        lock.lock(); defer { lock.unlock() }
        if !retired && free.count < Self.kept { free.append(memory) } else { memory.deallocate() }
    }

    /// The render changed size: this pool's buffers are the wrong size, so they go as they come back.
    func retire() {
        lock.lock(); retired = true; let old = free; free = []; lock.unlock()
        old.forEach { $0.deallocate() }
    }

    /// Lets go of the buffers waiting for a frame (the Mac is short of memory); the next frame makes one again.
    func trim() {
        lock.lock(); let old = free; free = []; lock.unlock()
        old.forEach { $0.deallocate() }
    }

    /// Buffers waiting for a frame (diagnostics, tests).
    var idleBuffers: Int { lock.lock(); defer { lock.unlock() }; return free.count }
}

/// One frame's bytes. It goes back to its pool when nothing holds it any more: the stage (for hit testing) and every
/// image made from it.
final class FrameBuffer: @unchecked Sendable {
    let bytes: UnsafeMutableRawPointer
    private let pool: FramePool
    fileprivate init(pool: FramePool, memory: UnsafeMutableRawPointer) { self.pool = pool; bytes = memory }
    deinit { pool.recycle(bytes) }
    var byteCount: Int { pool.byteCount }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let layout = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little)

    /// A square image of the buffer (BGRA, premultiplied). The buffer isn't reused while the image lives.
    func image(side: Int) -> CGImage? {
        let held = Unmanaged.passRetained(self)
        guard let provider = CGDataProvider(dataInfo: held.toOpaque(), data: bytes, size: byteCount, releaseData: { info, _, _ in
            Unmanaged<FrameBuffer>.fromOpaque(info!).release()
        }) else { held.release(); return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: Self.sRGB, bitmapInfo: Self.layout,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The alpha byte of the pixel at (x, y) in a frame `side` pixels square.
    func alpha(x: Int, y: Int, side: Int) -> UInt8 { bytes.load(fromByteOffset: (y * side + x) * 4 + 3, as: UInt8.self) }
}
