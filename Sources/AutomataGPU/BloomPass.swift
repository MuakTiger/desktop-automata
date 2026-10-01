import AutomataCore
import CoreGraphics
import Metal
import MetalPerformanceShaders

/// Glow style GPU work: a persistent grid-sized `rgba16Float` trail
/// (`GlowTrail`, updated every rendered frame) and its bloom, a half
/// resolution copy blurred with `MPSImageGaussianBlur`.
///
/// Textures are (re)made lazily when the grid or drawable size changes.
/// Main thread only, like `Renderer`.
public final class BloomPass {
    public static let pixelFormat: MTLPixelFormat = .rgba16Float
    /// Halo brightness added to the trail in the final composite.
    public static let bloomStrength: Float = 1.0
    /// Gaussian sigma in cells (converted to half-resolution pixels per frame).
    public static let sigmaCells: Float = 1.25
    /// Sigma limits in half-resolution pixels.
    public static let sigmaRange: ClosedRange<Float> = 1.5...32
    private static let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1)

    private let device: MTLDevice
    private let trailPipeline: MTLComputePipelineState
    private let downsamplePipeline: MTLComputePipelineState

    /// Ping-pong pair; `trails[current]` holds the latest frame.
    private var trails: [MTLTexture] = []
    private var current = 0
    /// The next trail update ignores the (uninitialized) previous texture.
    private var trailNeedsReset = true

    private var halfSource: MTLTexture?
    private var halfBlurred: MTLTexture?
    private var blur: MPSImageGaussianBlur?

    /// Latest trail, or nil before the first `encodeTrail`.
    public var trailTexture: MTLTexture? { trails.isEmpty ? nil : trails[current] }

    /// Half-resolution blurred trail from the latest `encodeBloom`.
    public var bloomTexture: MTLTexture? { halfBlurred }

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        trailPipeline = try Self.makePipeline("glow_trail", device: device, library: library)
        downsamplePipeline = try Self.makePipeline("glow_downsample", device: device, library: library)
    }

    /// Half of `size` rounded up, at least 1x1.
    static func halfSize(of size: CGSize) -> (width: Int, height: Int) {
        (max((Int(size.width) + 1) / 2, 1), max((Int(size.height) + 1) / 2, 1))
    }

    /// Blur sigma in half-resolution pixels for cells `cellPixels` drawable pixels wide.
    static func sigma(cellPixels: Float) -> Float {
        min(max(cellPixels / 2 * sigmaCells, sigmaRange.lowerBound), sigmaRange.upperBound)
    }

    /// Starts the trail over from the next frame's colors.
    func resetTrail() {
        trailNeedsReset = true
    }

    /// `trail = max(trail * GlowTrail.decay, current)` for the grid-sized
    /// `current` colors. Reallocates (and resets) the trail if the size changed.
    /// Returns the new trail texture, or nil if allocation or encoding failed.
    @discardableResult
    func encodeTrail(current colors: MTLTexture, into commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        if trails.first.map({ $0.width != colors.width || $0.height != colors.height }) ?? true {
            trails = []
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: Self.pixelFormat, width: colors.width, height: colors.height, mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            for i in 0..<2 {
                guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
                texture.label = "Glow trail \(i)"
                trails.append(texture)
            }
            current = 0
            trailNeedsReset = true
        }
        let previous = trails[current]
        let next = trails[1 - current]
        var params = TrailParams(decay: trailNeedsReset ? 0 : GlowTrail.decay, cutoff: GlowTrail.cutoff)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(trailPipeline)
        encoder.setTexture(colors, index: 0)
        encoder.setTexture(previous, index: 1)
        encoder.setTexture(next, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<TrailParams>.stride, index: 0)
        dispatch(encoder, width: next.width, height: next.height)
        encoder.endEncoding()
        current = 1 - current
        trailNeedsReset = false
        return next
    }

    /// Downsamples the latest trail to half of `drawableSize` and blurs it.
    /// Reallocates the half-resolution textures if the size changed.
    /// Returns the blurred texture, or nil with no trail or on failure.
    @discardableResult
    func encodeBloom(drawableSize: CGSize, cellPixels: Float, into commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let trail = trailTexture else { return nil }
        let (width, height) = Self.halfSize(of: drawableSize)
        if halfSource?.width != width || halfSource?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            halfSource = device.makeTexture(descriptor: descriptor)
            halfBlurred = device.makeTexture(descriptor: descriptor)
            halfSource?.label = "Bloom source"
            halfBlurred?.label = "Bloom blurred"
        }
        let sigma = Self.sigma(cellPixels: cellPixels)
        if blur?.sigma != sigma {
            let kernel = MPSImageGaussianBlur(device: device, sigma: sigma)
            kernel.edgeMode = .clamp
            blur = kernel
        }
        guard
            let halfSource, let halfBlurred, let blur,
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }
        encoder.setComputePipelineState(downsamplePipeline)
        encoder.setTexture(trail, index: 0)
        encoder.setTexture(halfSource, index: 1)
        dispatch(encoder, width: width, height: height)
        encoder.endEncoding()
        blur.encode(commandBuffer: commandBuffer, sourceTexture: halfSource, destinationTexture: halfBlurred)
        return halfBlurred
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, width: Int, height: Int) {
        let size = Self.threadgroupSize
        let groups = MTLSize(
            width: (width + size.width - 1) / size.width,
            height: (height + size.height - 1) / size.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: size)
    }

    private static func makePipeline(
        _ name: String, device: MTLDevice, library: MTLLibrary
    ) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw GPUError.missingFunction(name)
        }
        return try device.makeComputePipelineState(function: function)
    }
}

/// Mirrors `TrailParams` in `ShaderSource.metal`.
struct TrailParams {
    var decay: Float
    var cutoff: Float
}

/// Mirrors `GlowParams` in `ShaderSource.metal`.
struct GlowParams {
    var cellsPerPixel: SIMD2<Float>
    var gridSize: SIMD2<UInt32>
    var invDrawableSize: SIMD2<Float>
    var bloomStrength: Float
}
