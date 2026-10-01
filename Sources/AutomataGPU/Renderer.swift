import AutomataCore
import Metal
import MetalKit
import QuartzCore

/// MTKView delegate: steps the selected automaton on the GPU at a fixed generation rate
/// (via `SimClock`), colorizes it every frame and draws it at the display
/// frame rate.
///
/// Main thread only: MTKView calls `draw(in:)` on the main thread, and the
/// control methods are called from the status menu.
public final class Renderer: NSObject, MTKViewDelegate {
    public static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm
    public static let framesPerSecond = 60
    public static let maxStepsPerFrame = 4
    /// Pixel style draws gridlines once cells are at least this many points.
    public static let minGridlineCellPoints = 6

    public let device: MTLDevice
    /// Internal so tests can read back on the same queue the controls encode on.
    let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private let renderPipeline: MTLRenderPipelineState
    private let glowPipeline: MTLRenderPipelineState
    /// Glow trail + bloom. The trail updates every frame in both styles so a
    /// switch to Glow shows current tails at once.
    let bloom: BloomPass

    public private(set) var simulation: LifeSimulation?
    private var clock: SimClock
    private var lastFrameTime: CFTimeInterval?

    /// When true the simulation holds still (and so does the hue drift); the view keeps drawing.
    public var isPaused = false

    public var generationsPerSecond: Int {
        get { clock.generationsPerSecond }
        set { clock.generationsPerSecond = newValue }
    }

    /// Cell edge length in points. Changing it rebuilds the state, color and
    /// trail textures for the last view size and reseeds.
    public var cellPoints: Int {
        didSet {
            guard cellPoints != oldValue, let lastViewSize else { return }
            rebuild(for: lastViewSize)
        }
    }

    /// View size (points) the grid was last sized for.
    public private(set) var lastViewSize: CGSize?

    /// Generations stepped since launch (never reset; the HUD diffs it for actual gen/s).
    public private(set) var totalSteps: UInt64 = 0

    /// Latest GPU population count (`Automaton.population` of the rule) and the
    /// generation it was taken at, delivered by a command-buffer completed
    /// handler a frame or so late. Nil until the first count after a (re)build.
    public private(set) var population: (count: Int, generation: UInt32)?

    /// Frames between population counts (60 fps / 15 = 4 Hz, the HUD's refresh rate).
    static let populationInterval = 15
    private var framesUntilPopulation = 0
    /// Shared buffers the population kernel writes; one is in flight at most per frame.
    private var populationBuffers: [MTLBuffer] = []
    private var freePopulationBuffers: [MTLBuffer] = []
    /// Bumped on every rebuild so late counts from an old grid are dropped.
    private var populationEpoch = 0

    /// Automaton rule. Changing it reseeds the grid with a fresh random seed
    /// (generation back to 0).
    public var rule: AutomatonRule {
        didSet {
            guard rule != oldValue else { return }
            simulation?.rule = rule
            pendingStamps.removeAll()
            // The population definition changed with the rule.
            population = nil
            populationEpoch += 1
            framesUntilPopulation = 0
            randomReset()
        }
    }

    /// Cosine palette live cells are colored with; takes effect on the next frame.
    public var palette: Palette

    /// Pixel style: crisp cells, gridlines (cells >= 6 pt) and one-generation death afterimages.
    /// Glow style: fading trails plus a bloom halo, no gridlines. Takes effect on
    /// the next frame without touching the simulation.
    public var style: RenderStyle

    /// Seconds of global hue drift. Advances with wall time while the simulation plays.
    var hueTime: Double = 0

    /// Called at the start of every drawn frame with the frame's media time,
    /// before pending stamps and steps are encoded (the app polls the pointer here).
    public var onFrame: ((CFTimeInterval) -> Void)?

    /// Stamps painted at the start of the next frame, before its steps.
    private var pendingStamps: [Stamp] = []

    public init(
        device: MTLDevice,
        generationsPerSecond: Int,
        cellPoints: Int,
        rule: AutomatonRule = .rgbLife,
        palette: Palette = .neon,
        style: RenderStyle = .pixel
    ) throws {
        guard let queue = device.makeCommandQueue() else {
            throw GPUError.allocationFailed("command queue")
        }
        self.device = device
        self.commandQueue = queue
        self.library = try ShaderSource.makeLibrary(device: device)

        guard
            let vertex = library.makeFunction(name: "fullscreen_vertex"),
            let fragment = library.makeFunction(name: "life_fragment")
        else { throw GPUError.missingFunction("fullscreen_vertex/life_fragment") }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = Self.colorPixelFormat
        self.renderPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard let glowFragment = library.makeFunction(name: "glow_fragment") else {
            throw GPUError.missingFunction("glow_fragment")
        }
        descriptor.fragmentFunction = glowFragment
        self.glowPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        self.bloom = try BloomPass(device: device, library: library)

        self.clock = SimClock(generationsPerSecond: generationsPerSecond, maxStepsPerFrame: Self.maxStepsPerFrame)
        self.cellPoints = cellPoints
        self.rule = rule
        self.palette = palette
        self.style = style
        super.init()
    }

    /// Configures `view` for this renderer, makes it the view's delegate, and
    /// seeds a grid sized to the view.
    public func attach(to view: MTKView) {
        view.device = device
        view.colorPixelFormat = Self.colorPixelFormat
        view.framebufferOnly = true
        view.preferredFramesPerSecond = Self.framesPerSecond
        view.enableSetNeedsDisplay = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = self
        resizeIfNeeded(for: view.bounds.size)
    }

    // MARK: Controls

    /// Queues exactly one generation, whether or not the simulation is paused.
    public func stepOnce() {
        run { simulation, commandBuffer in simulation.encodeStep(into: commandBuffer) }
    }

    /// Reseeds the grid for `rule` with a fresh random seed.
    public func randomReset() {
        reset(seed: .random(in: .min ... .max))
    }

    /// Reseeds the grid for `rule` deterministically from `seed`.
    public func reset(seed: UInt32) {
        run { simulation, commandBuffer in simulation.encodeSeed(seed, into: commandBuffer) }
    }

    /// Empties the grid.
    public func clear() {
        run { simulation, commandBuffer in simulation.encodeClear(into: commandBuffer) }
    }

    /// Queues `stamps` (grid cell coordinates) for the next frame. They are
    /// painted immediately in that frame, before any step, so they show even
    /// while paused or between generations. At most `Stamp.maxPerFrame` per frame.
    public func addStamps(_ stamps: [Stamp]) {
        pendingStamps += stamps
    }

    // MARK: MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        // Clamped so a resume after Off/sleep/lock doesn't snap the hue forward.
        let elapsed = min(lastFrameTime.map { now - $0 } ?? 0, 0.25)
        lastFrameTime = now

        resizeIfNeeded(for: view.bounds.size)
        onFrame?(now)
        guard
            let simulation,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        advanceFrame(simulation, elapsed: elapsed, into: commandBuffer)
        encodePopulationIfDue(simulation, into: commandBuffer)

        let drawableSize = view.drawableSize
        if
            drawableSize.width > 0, drawableSize.height > 0,
            let pass = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            encodeFrame(simulation, pass: pass, drawableSize: drawableSize, into: commandBuffer)
        {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    // MARK: Internal

    /// Grid dimensions for a view of `size` points: whole cells, at least 1x1.
    static func gridSize(for size: CGSize, cellPoints: Int) -> (width: Int, height: Int) {
        ScreenGrid.gridSize(for: size, cellPoints: cellPoints)
    }

    /// One frame of simulation work: paints the pending stamps (capped at
    /// `Stamp.maxPerFrame`) into the current state, then, unless paused, steps
    /// as many generations as `SimClock` allows and advances the hue drift.
    func advanceFrame(_ simulation: LifeSimulation, elapsed: Double, into commandBuffer: MTLCommandBuffer) {
        if !pendingStamps.isEmpty {
            simulation.encodeStamps(Array(pendingStamps.prefix(Stamp.maxPerFrame)), into: commandBuffer)
            pendingStamps.removeAll(keepingCapacity: true)
        }
        if !isPaused {
            for _ in 0..<clock.advance(by: elapsed) {
                simulation.encodeStep(into: commandBuffer)
                totalSteps &+= 1
            }
            hueTime += elapsed
        }
    }

    /// Gridline width in pixels: 1 in Pixel style with cells of at least
    /// `minGridlineCellPoints`, otherwise 0 (no gridlines).
    static func gridLineWidth(style: RenderStyle, cellPoints: Int) -> Float {
        style == .pixel && cellPoints >= minGridlineCellPoints ? 1 : 0
    }

    /// Afterimage brightness for channels that just died: on in Pixel style only.
    static func afterimage(style: RenderStyle) -> Float {
        style == .pixel ? LifeColoring.afterimage : 0
    }

    /// Reallocates and reseeds the simulation when the grid dimensions change.
    func resizeIfNeeded(for viewSize: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        let size = Self.gridSize(for: viewSize, cellPoints: cellPoints)
        if let simulation, simulation.width == size.width, simulation.height == size.height {
            lastViewSize = viewSize
            return
        }
        rebuild(for: viewSize)
    }

    /// Always reallocates the state, color and trail textures for `viewSize`
    /// points at the current `cellPoints` and reseeds (cell size or screen
    /// change). Ignored for an empty size.
    public func rebuild(for viewSize: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        lastViewSize = viewSize
        let size = Self.gridSize(for: viewSize, cellPoints: cellPoints)
        // Queued stamps were mapped to the old grid; counts in flight belong to it too.
        pendingStamps.removeAll()
        population = nil
        populationEpoch += 1
        framesUntilPopulation = 0
        bloom.resetTrail()
        do {
            simulation = try LifeSimulation(device: device, library: library, width: size.width, height: size.height, rule: rule)
            randomReset()
        } catch {
            NSLog("DesktopAutomata: failed to create %@ simulation: %@", "\(size.width)x\(size.height)", "\(error)")
            simulation = nil
        }
    }

    /// Every `populationInterval` frames, counts the population of the frame's
    /// final state into a free shared buffer. The completed handler hands the
    /// count back on the main queue, so the CPU never waits on the GPU; if
    /// all buffers are still in flight the count is skipped this time.
    func encodePopulationIfDue(_ simulation: LifeSimulation, into commandBuffer: MTLCommandBuffer) {
        if framesUntilPopulation > 0 {
            framesUntilPopulation -= 1
            return
        }
        if freePopulationBuffers.isEmpty, populationBuffers.count < 3,
           let buffer = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared) {
            populationBuffers.append(buffer)
            freePopulationBuffers.append(buffer)
        }
        guard let buffer = freePopulationBuffers.popLast() else { return }
        framesUntilPopulation = Self.populationInterval - 1
        simulation.encodePopulation(into: buffer, commandBuffer: commandBuffer)
        let generation = simulation.generation
        let epoch = populationEpoch
        commandBuffer.addCompletedHandler { [weak self] completed in
            let ok = completed.status == .completed
            let count = Int(buffer.contents().load(as: UInt32.self))
            DispatchQueue.main.async {
                guard let self else { return }
                self.freePopulationBuffers.append(buffer)
                if ok, epoch == self.populationEpoch {
                    self.population = (count, generation)
                }
            }
        }
    }

    /// Colorizes the current generation and folds it into the glow trail.
    /// Returns the trail texture (nil if it could not be made).
    @discardableResult
    func encodeColors(_ simulation: LifeSimulation, into commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        simulation.encodeColorize(
            palette: palette.cosine,
            drift: LifeColoring.hueDrift(seconds: hueTime),
            afterimage: Self.afterimage(style: style),
            into: commandBuffer
        )
        return bloom.encodeTrail(current: simulation.colorTexture, into: commandBuffer)
    }

    /// Colorizes the current generation, updates the trail and draws it in
    /// `style`, stretched over `drawableSize` pixels, into `pass`. Returns false
    /// if no render encoder could be made.
    func encodeFrame(
        _ simulation: LifeSimulation,
        pass: MTLRenderPassDescriptor,
        drawableSize: CGSize,
        into commandBuffer: MTLCommandBuffer
    ) -> Bool {
        let trail = encodeColors(simulation, into: commandBuffer)
        if style == .glow, let trail,
           let halo = bloom.encodeBloom(
               drawableSize: drawableSize,
               cellPixels: Float(drawableSize.width) / Float(simulation.width),
               into: commandBuffer
           ) {
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
            var params = GlowParams(
                cellsPerPixel: SIMD2(
                    Float(simulation.width) / Float(drawableSize.width),
                    Float(simulation.height) / Float(drawableSize.height)
                ),
                gridSize: SIMD2(UInt32(simulation.width), UInt32(simulation.height)),
                invDrawableSize: SIMD2(1 / Float(drawableSize.width), 1 / Float(drawableSize.height)),
                bloomStrength: BloomPass.bloomStrength
            )
            encoder.setRenderPipelineState(glowPipeline)
            encoder.setFragmentTexture(trail, index: 0)
            encoder.setFragmentTexture(halo, index: 1)
            encoder.setFragmentBytes(&params, length: MemoryLayout<GlowParams>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            return true
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var params = RenderParams(
            cellsPerPixel: SIMD2(
                Float(simulation.width) / Float(drawableSize.width),
                Float(simulation.height) / Float(drawableSize.height)
            ),
            gridSize: SIMD2(UInt32(simulation.width), UInt32(simulation.height)),
            gridLineWidth: Self.gridLineWidth(style: style, cellPoints: cellPoints)
        )
        encoder.setRenderPipelineState(renderPipeline)
        encoder.setFragmentTexture(simulation.colorTexture, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<RenderParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    // MARK: Private

    private func run(_ encode: (LifeSimulation, MTLCommandBuffer) -> Void) {
        guard let simulation, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        encode(simulation, commandBuffer)
        commandBuffer.commit()
    }
}

/// Mirrors `RenderParams` in `ShaderSource.metal`.
struct RenderParams {
    var cellsPerPixel: SIMD2<Float>
    var gridSize: SIMD2<UInt32>
    var gridLineWidth: Float
}
