import AutomataCore
import CoreGraphics
import Metal
import Testing
@testable import AutomataGPU

private let hasMetal = MTLCreateSystemDefaultDevice() != nil

@Suite("Bloom pass", .enabled(if: hasMetal, "No Metal device"))
struct BloomPassTests {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pass: BloomPass

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        pass = try BloomPass(device: device, library: ShaderSource.makeLibrary(device: device))
    }

    /// Grid-sized float color texture with `cells` set to `value` (RGB).
    private func colors(width: Int, height: Int, cells: [(Int, Int)], value: SIMD3<Float>) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var data = [Float](repeating: 0, count: width * height * 4)
        for (x, y) in cells {
            let i = (y * width + x) * 4
            data[i] = value.x; data[i + 1] = value.y; data[i + 2] = value.z; data[i + 3] = 1
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: data, bytesPerRow: width * 16
        )
        return texture
    }

    /// RGB of an `rgba16Float` texture, row-major.
    private func read(_ texture: MTLTexture) throws -> [SIMD3<Float>] {
        let bytesPerRow = texture.width * 8
        let length = bytesPerRow * texture.height
        let buffer = try #require(device.makeBuffer(length: length, options: .storageModeShared))
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: length
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let raw = UnsafeRawBufferPointer(start: buffer.contents(), count: length)
        return (0..<(texture.width * texture.height)).map { i in
            SIMD3(
                LifeSimulation.float(fromHalf: raw.loadUnaligned(fromByteOffset: i * 8, as: UInt16.self)),
                LifeSimulation.float(fromHalf: raw.loadUnaligned(fromByteOffset: i * 8 + 2, as: UInt16.self)),
                LifeSimulation.float(fromHalf: raw.loadUnaligned(fromByteOffset: i * 8 + 4, as: UInt16.self))
            )
        }
    }

    @Test("GPU trail matches GlowTrail frame by frame and fades to 0")
    func trailParity() throws {
        let lit = try colors(width: 9, height: 7, cells: [(4, 3)], value: SIMD3(1.5, 0.6, 0.02))
        let dark = try colors(width: 9, height: 7, cells: [], value: .zero)
        var expected = SIMD3<Float>(1.5, 0.6, 0.02)
        for frame in 0..<120 {
            let commandBuffer = try #require(queue.makeCommandBuffer())
            let trail = try #require(pass.encodeTrail(current: frame == 0 ? lit : dark, into: commandBuffer))
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if frame > 0 { expected = GlowTrail.update(previous: expected, current: .zero) }
            let pixels = try read(trail)
            let got = pixels[3 * 9 + 4]
            for k in 0..<3 {
                // Half precision drifts slightly; the cutoff can land one frame apart.
                #expect(abs(got[k] - expected[k]) < max(expected[k] * 0.02, GlowTrail.cutoff * 1.1),
                        "frame \(frame) channel \(k): \(got[k]) vs \(expected[k])")
            }
            #expect(pixels.enumerated().allSatisfy { $0.offset == 3 * 9 + 4 || $0.element == .zero })
        }
        #expect(expected == .zero)
    }

    @Test("Bloom encodes at half resolution with a halo", arguments: [(64, 48), (333, 177), (1280, 720)])
    func bloomSmoke(size: (Int, Int)) throws {
        let (width, height) = size
        // A 6-pixel grid with one lit cell in the middle.
        let gridWidth = max(width / 6, 1), gridHeight = max(height / 6, 1)
        let source = try colors(
            width: gridWidth, height: gridHeight, cells: [(gridWidth / 2, gridHeight / 2)], value: SIMD3(1, 0.2, 0.8)
        )
        let commandBuffer = try #require(queue.makeCommandBuffer())
        pass.resetTrail()
        try #require(pass.encodeTrail(current: source, into: commandBuffer) != nil)
        let halo = try #require(pass.encodeBloom(
            drawableSize: CGSize(width: width, height: height), cellPixels: 6, into: commandBuffer
        ))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        #expect(halo.width == (width + 1) / 2 && halo.height == (height + 1) / 2)

        let pixels = try read(halo)
        let peak = pixels.map(\.x).max() ?? 0
        #expect(peak > 0.05)
        // Halo reaches about two cells (6 half pixels) beyond the cell center.
        let cx = Int((Float(gridWidth / 2) + 0.5) / Float(gridWidth) * Float(halo.width))
        let cy = Int((Float(gridHeight / 2) + 0.5) / Float(gridHeight) * Float(halo.height))
        let side = pixels[cy * halo.width + min(cx + 6, halo.width - 1)]
        #expect(side.x > 0.01 && side.x < peak)
        // Hue is kept: red > blue > green, as in the source.
        let center = pixels[cy * halo.width + cx]
        #expect(center.x > center.z && center.z > center.y)
        if width >= 333 {
            #expect(pixels[0].x < 0.001)  // far corner stays dark
        }
    }
}
