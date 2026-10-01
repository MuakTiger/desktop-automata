import AutomataCore
import Metal

public enum GPUError: Error, CustomStringConvertible {
    case missingFunction(String)
    case allocationFailed(String)
    case snapshotFailed(String)

    public var description: String {
        switch self {
        case .missingFunction(let name): return "MSL function '\(name)' not found"
        case .allocationFailed(let what): return "Failed to allocate \(what)"
        case .snapshotFailed(let why): return "Snapshot failed: \(why)"
        }
    }
}

/// The automaton on the GPU: two `rgba8Uint` state textures used ping-pong,
/// plus a grid-sized `rgba16Float` color/trail texture filled by
/// `encodeColorize`. `rule` selects the kernel branch. State layout matches
/// `AutomataCore.Grid`, and results match `Automaton` (RGB Life, Brian's
/// Brain, Cyclic, RPS) bit-for-bit; colors match `LifeColoring` /
/// `RuleColoring` within float tolerance.
///
/// `encode*` methods only record work into a command buffer; the caller commits.
/// Not thread-safe: encode from one thread (the main thread in the app).
public final class LifeSimulation {
    public static let pixelFormat: MTLPixelFormat = .rgba8Uint
    public static let colorPixelFormat: MTLPixelFormat = .rgba16Float
    private static let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1)

    public let width: Int
    public let height: Int
    /// Generations encoded since the last seed or clear.
    public private(set) var generation: UInt32 = 0
    /// Rule the seed, step, stamp, colorize and population kernels run. Changing
    /// it does not touch the state; reseed afterwards.
    public var rule: AutomatonRule

    private let device: MTLDevice
    private let seedPipeline: MTLComputePipelineState
    private let clearPipeline: MTLComputePipelineState
    private let stepPipeline: MTLComputePipelineState
    private let colorizePipeline: MTLComputePipelineState
    private let stampPipeline: MTLComputePipelineState
    private let populationPipeline: MTLComputePipelineState
    private let textures: [MTLTexture]
    private var current = 0

    /// Texture holding the latest encoded generation.
    public var stateTexture: MTLTexture { textures[current] }

    /// One linear RGBA color per cell, written by `encodeColorize`.
    public let colorTexture: MTLTexture

    /// Textures start zeroed only after `encodeClear` or `encodeSeed`; encode one first.
    public init(
        device: MTLDevice, library: MTLLibrary, width: Int, height: Int, rule: AutomatonRule = .rgbLife
    ) throws {
        precondition(width > 0 && height > 0, "Grid must be at least 1x1")
        self.device = device
        self.rule = rule
        self.width = width
        self.height = height
        seedPipeline = try Self.makePipeline("life_seed", device: device, library: library)
        clearPipeline = try Self.makePipeline("life_clear", device: device, library: library)
        stepPipeline = try Self.makePipeline("life_step", device: device, library: library)
        colorizePipeline = try Self.makePipeline("life_colorize", device: device, library: library)
        stampPipeline = try Self.makePipeline("life_stamp", device: device, library: library)
        populationPipeline = try Self.makePipeline("life_population", device: device, library: library)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        var textures: [MTLTexture] = []
        for i in 0..<2 {
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw GPUError.allocationFailed("state texture \(i) (\(width)x\(height))")
            }
            texture.label = "Life state \(i)"
            textures.append(texture)
        }
        self.textures = textures

        descriptor.pixelFormat = Self.colorPixelFormat
        guard let colorTexture = device.makeTexture(descriptor: descriptor) else {
            throw GPUError.allocationFailed("color texture (\(width)x\(height))")
        }
        colorTexture.label = "Life color"
        self.colorTexture = colorTexture
    }

    /// Reseeds the current texture with `Automaton.seeded(rule, ...)` and resets `generation`.
    public func encodeSeed(_ seed: UInt32, into commandBuffer: MTLCommandBuffer) {
        var params = SeedParams(
            seed: seed,
            threshold: rule == .briansBrain ? BriansBrain.seedThreshold : RGBLife.seedThreshold,
            rule: rule.index,
            states: rule == .cyclic ? CyclicCA.states : RockPaperScissors.speciesCount
        )
        encodeCompute(seedPipeline, into: commandBuffer) { encoder in
            encoder.setTexture(stateTexture, index: 0)
            encoder.setBytes(&params, length: MemoryLayout<SeedParams>.stride, index: 0)
        }
        generation = 0
    }

    /// Empties the current texture.
    public func encodeClear(into commandBuffer: MTLCommandBuffer) {
        encodeCompute(clearPipeline, into: commandBuffer) { encoder in
            encoder.setTexture(stateTexture, index: 0)
        }
        generation = 0
    }

    /// Advances one generation and flips the ping-pong pair.
    public func encodeStep(into commandBuffer: MTLCommandBuffer) {
        let src = textures[current]
        let dst = textures[1 - current]
        var params = StepParams(
            rule: rule.index,
            states: CyclicCA.states,
            threshold: CyclicCA.threshold,
            rpsBase: RockPaperScissors.baseThreshold,
            rpsRange: RockPaperScissors.offsetRange,
            rpsSeed: RockPaperScissors.stepSeed,
            generation: generation
        )
        // One encoder per step keeps each generation's writes ordered before the next read.
        let encoded = encodeCompute(stepPipeline, into: commandBuffer) { encoder in
            encoder.setTexture(src, index: 0)
            encoder.setTexture(dst, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<StepParams>.stride, index: 0)
        }
        guard encoded else { return }
        current = 1 - current
        generation &+= 1
    }

    /// Paints `stamps` (at most `Stamp.maxPerFrame`, extras are dropped) into
    /// the current state like `Automaton.stamp(rule, _:into:)` and flips the ping-pong
    /// pair. Does not advance `generation`.
    public func encodeStamps(_ stamps: [Stamp], into commandBuffer: MTLCommandBuffer) {
        guard !stamps.isEmpty else { return }
        var gpuStamps = stamps.prefix(Stamp.maxPerFrame).map(GPUStamp.init)
        var params = StampParams(
            count: UInt32(gpuStamps.count),
            trailDensity: RGBLife.trailDensity,
            burstDensity: RGBLife.burstDensity,
            ringWidth: RGBLife.burstRingWidth,
            rule: rule.index,
            states: CyclicCA.states
        )
        let src = textures[current]
        let dst = textures[1 - current]
        let encoded = encodeCompute(stampPipeline, into: commandBuffer) { encoder in
            encoder.setTexture(src, index: 0)
            encoder.setTexture(dst, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<StampParams>.stride, index: 0)
            // 64 x 24 B fits setBytes' 4 KB limit and is copied at encode time.
            encoder.setBytes(&gpuStamps, length: MemoryLayout<GPUStamp>.stride * gpuStamps.count, index: 1)
        }
        if encoded { current = 1 - current }
    }

    /// Fills `colorTexture` from the current state with `LifeColoring` (RGB
    /// Life: `palette` at an age-driven position offset by `drift`, birth
    /// flash, and an afterimage of brightness `afterimage` for channels that
    /// just died) or `RuleColoring` for the other rules.
    public func encodeColorize(
        palette: CosinePalette, drift: Float, afterimage: Float, into commandBuffer: MTLCommandBuffer
    ) {
        var params = ColorizeParams(palette: palette, drift: drift, afterimage: afterimage, rule: rule)
        encodeCompute(colorizePipeline, into: commandBuffer) { encoder in
            encoder.setTexture(stateTexture, index: 0)
            encoder.setTexture(colorTexture, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<ColorizeParams>.stride, index: 0)
        }
    }

    /// Writes `Automaton.population(rule, _:)` of the current state as a
    /// `UInt32` at offset 0 of `buffer` (zeroed first) when `commandBuffer` completes.
    public func encodePopulation(into buffer: MTLBuffer, commandBuffer: MTLCommandBuffer) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.fill(buffer: buffer, range: 0..<MemoryLayout<UInt32>.size, value: 0)
        blit.endEncoding()
        var ruleIndex = rule.index
        encodeCompute(populationPipeline, into: commandBuffer) { encoder in
            encoder.setTexture(stateTexture, index: 0)
            encoder.setBytes(&ruleIndex, length: MemoryLayout<UInt32>.size, index: 0)
            encoder.setBuffer(buffer, offset: 0, index: 1)
        }
    }

    /// Counts the population on the GPU and blocks until done. For tests and diagnostics.
    public func population(using queue: MTLCommandQueue) throws -> Int {
        guard
            let buffer = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
            let commandBuffer = queue.makeCommandBuffer()
        else { throw GPUError.allocationFailed("population") }
        encodePopulation(into: buffer, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return Int(buffer.contents().load(as: UInt32.self))
    }

    /// Copies `grid` into the current texture and blocks until it completes.
    /// Resets `generation` to `grid.generation`. For tests.
    func upload(_ grid: Grid, using queue: MTLCommandQueue) throws {
        precondition(grid.width == width && grid.height == height, "Grid size mismatch")
        let bytesPerRow = width * Grid.bytesPerCell
        guard
            let buffer = grid.cells.withUnsafeBytes({ raw in
                device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
            }),
            let commandBuffer = queue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw GPUError.allocationFailed("upload") }
        blit.copy(
            from: buffer, sourceOffset: 0,
            sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: bytesPerRow * height,
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: stateTexture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        generation = grid.generation
    }

    /// Commits a blit of the current texture and blocks until it completes.
    /// Returns bytes in `Grid.cells` layout. For tests and diagnostics.
    public func readback(using queue: MTLCommandQueue) throws -> [UInt8] {
        try readBytes(of: stateTexture, bytesPerPixel: Grid.bytesPerCell, using: queue)
    }

    /// Commits a blit of `colorTexture` and blocks until it completes.
    /// Returns one RGBA color per cell, row-major. For tests and diagnostics.
    public func readbackColor(using queue: MTLCommandQueue) throws -> [SIMD4<Float>] {
        let bytes = try readBytes(of: colorTexture, bytesPerPixel: 8, using: queue)
        return bytes.withUnsafeBytes { raw in
            (0..<(width * height)).map { cell in
                var color = SIMD4<Float>()
                for k in 0..<4 {
                    color[k] = Self.float(fromHalf: raw.loadUnaligned(fromByteOffset: cell * 8 + k * 2, as: UInt16.self))
                }
                return color
            }
        }
    }

    /// IEEE 754 binary16 bits to `Float` (portable; `Float16` is unavailable on Intel Macs).
    static func float(fromHalf bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32(bits >> 10) & 0x1F
        let mantissa = UInt32(bits & 0x3FF)
        switch exponent {
        case 0:  // zero or subnormal
            let magnitude = Float(mantissa) * 0x1p-24
            return sign == 0 ? magnitude : -magnitude
        case 0x1F:  // infinity or NaN
            return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13))
        default:
            return Float(bitPattern: sign | ((exponent + 112) << 23) | (mantissa << 13))
        }
    }

    private func readBytes(of texture: MTLTexture, bytesPerPixel: Int, using queue: MTLCommandQueue) throws -> [UInt8] {
        let bytesPerRow = width * bytesPerPixel
        let length = bytesPerRow * height
        guard
            let buffer = device.makeBuffer(length: length, options: .storageModeShared),
            let commandBuffer = queue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw GPUError.allocationFailed("readback") }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer, destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: length
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let pointer = buffer.contents().bindMemory(to: UInt8.self, capacity: length)
        return Array(UnsafeBufferPointer(start: pointer, count: length))
    }

    /// Returns false (nothing encoded) if no compute encoder could be made.
    @discardableResult
    private func encodeCompute(
        _ pipeline: MTLComputePipelineState,
        into commandBuffer: MTLCommandBuffer,
        bind: (MTLComputeCommandEncoder) -> Void
    ) -> Bool {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(pipeline)
        bind(encoder)
        let size = Self.threadgroupSize
        let groups = MTLSize(
            width: (width + size.width - 1) / size.width,
            height: (height + size.height - 1) / size.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: size)
        encoder.endEncoding()
        return true
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

/// Mirrors `SeedParams` in `ShaderSource.metal`.
struct SeedParams {
    var seed: UInt32
    var threshold: UInt32
    var rule: UInt32
    var states: UInt32
}

/// Mirrors `StepParams` in `ShaderSource.metal`.
struct StepParams {
    var rule: UInt32
    var states: UInt32
    var threshold: UInt32
    var rpsBase: UInt32
    var rpsRange: UInt32
    var rpsSeed: UInt32
    var generation: UInt32
}

/// Mirrors `Stamp` in `ShaderSource.metal` (24-byte stride on both sides).
struct GPUStamp {
    var x: Int32
    var y: Int32
    var radius: Int32
    var kind: UInt32
    var value: UInt32
    var seed: UInt32

    init(_ stamp: Stamp) {
        x = stamp.x
        y = stamp.y
        radius = stamp.radius
        kind = stamp.kind.rawValue
        value = stamp.value
        seed = stamp.seed
    }
}

/// Mirrors `StampParams` in `ShaderSource.metal`.
struct StampParams {
    var count: UInt32
    var trailDensity: UInt32
    var burstDensity: UInt32
    var ringWidth: Int32
    var rule: UInt32
    var states: UInt32
}

/// Mirrors `ColorizeParams` in `ShaderSource.metal` (128-byte stride on both sides).
struct ColorizeParams {
    var a: SIMD4<Float>
    var b: SIMD4<Float>
    var c: SIMD4<Float>
    var d: SIMD4<Float>
    var drift: Float
    var channelSpread: Float
    var ageSpan: Float
    var birthFlash: Float
    var afterimage: Float
    var rule: UInt32
    var states: UInt32
    var spatialSpread: Float
    var fireFlash: Float
    var refractoryBrightness: Float
    var trailLength: Float
    var frontFlash: Float
    var ageDim: Float
    var speciesSpread: Float
    var period: Float
    var speciesTint: Float

    init(palette: CosinePalette, drift: Float, afterimage: Float, rule: AutomatonRule) {
        a = SIMD4(palette.a, 0)
        b = SIMD4(palette.b, 0)
        c = SIMD4(palette.c, 0)
        d = SIMD4(palette.d, 0)
        self.drift = drift
        channelSpread = LifeColoring.channelSpread
        ageSpan = LifeColoring.ageSpan
        birthFlash = LifeColoring.birthFlash
        self.afterimage = afterimage
        self.rule = rule.index
        states = CyclicCA.states
        spatialSpread = RuleColoring.spatialSpread
        fireFlash = RuleColoring.fireFlash
        refractoryBrightness = RuleColoring.refractoryBrightness
        trailLength = RuleColoring.trailLength
        frontFlash = RuleColoring.frontFlash
        ageDim = RuleColoring.ageDim
        speciesSpread = RuleColoring.speciesSpread
        period = CosinePalette.period
        speciesTint = RuleColoring.speciesTint
    }
}
