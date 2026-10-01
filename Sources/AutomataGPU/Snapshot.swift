import AutomataCore
import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Offscreen debug render (the app's `DA_SNAPSHOT` mode): seeds a grid sized
/// for a view of `viewSize` points, runs `generations` generations, draws one
/// frame at `scale` pixels per point exactly like the desktop window would, and
/// writes it as a PNG.
public enum Snapshot {
    public static func writePNG(
        to url: URL,
        device: MTLDevice,
        settings: Settings,
        viewSize: CGSize,
        scale: CGFloat,
        generations: Int,
        seed: UInt32,
        stampFrames: [[Stamp]] = []
    ) throws {
        let renderer = try Renderer(
            device: device,
            generationsPerSecond: settings.speed.generationsPerSecond,
            cellPoints: settings.cellSize.points,
            rule: settings.rule,
            palette: settings.palette,
            style: settings.style
        )
        let image = try renderer.renderOffscreen(
            viewSize: viewSize, scale: scale, generations: generations, seed: seed, stampFrames: stampFrames
        )
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw GPUError.snapshotFailed("cannot create \(url.path)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw GPUError.snapshotFailed("cannot write \(url.path)")
        }
    }
}

extension Renderer {
    /// Generations before a snapshot whose frames feed the glow trail.
    static let snapshotTrailGenerations = 20

    /// Renders one frame offscreen after `generations` steps from `seed`, with
    /// the hue drift at its starting point. Then plays `stampFrames` as 60 fps
    /// frames through the live frame path (stamps first, then `SimClock` steps
    /// unless paused) before drawing.
    func renderOffscreen(
        viewSize: CGSize, scale: CGFloat, generations: Int, seed: UInt32, stampFrames: [[Stamp]] = []
    ) throws -> CGImage {
        resizeIfNeeded(for: viewSize)
        guard let simulation else { throw GPUError.snapshotFailed("no simulation for \(viewSize)") }
        reset(seed: seed)
        hueTime = 0

        let width = max(Int((viewSize.width * scale).rounded()), 1)
        let height = max(Int((viewSize.height * scale).rounded()), 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.colorPixelFormat, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        let bytesPerRow = width * 4
        guard
            let target = device.makeTexture(descriptor: descriptor),
            let buffer = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { throw GPUError.allocationFailed("snapshot \(width)x\(height)") }

        // The last `trailGenerations` generations also play their in-between
        // frames through the trail (as the live view at this speed would), so
        // Glow shows tails. The state is identical in every style.
        let generations = max(generations, 0)
        let framesPerGeneration = max(Self.framesPerSecond / max(generationsPerSecond, 1), 1)
        for index in 0..<generations {
            simulation.encodeStep(into: commandBuffer)
            if index >= generations - Self.snapshotTrailGenerations {
                for _ in 0..<framesPerGeneration { encodeColors(simulation, into: commandBuffer) }
            }
        }
        for stamps in stampFrames {
            addStamps(stamps)
            advanceFrame(simulation, elapsed: 1.0 / Double(Self.framesPerSecond), into: commandBuffer)
            encodeColors(simulation, into: commandBuffer)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard
            encodeFrame(simulation, pass: pass, drawableSize: CGSize(width: width, height: height), into: commandBuffer),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw GPUError.snapshotFailed("encoding failed") }
        blit.copy(
            from: target, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer, destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw GPUError.snapshotFailed("GPU error: \(String(describing: commandBuffer.error))")
        }

        let data = Data(bytes: buffer.contents(), count: bytesPerRow * height)
        guard
            let provider = CGDataProvider(data: data as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let image = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: colorSpace,
                // bgra8Unorm: B, G, R, X in memory.
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
                ),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        else { throw GPUError.snapshotFailed("cannot build image") }
        return image
    }
}
