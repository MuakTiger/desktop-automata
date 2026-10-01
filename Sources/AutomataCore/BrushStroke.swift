import CoreGraphics
import Foundation

/// One brush dab, painted into the grid immediately (before the next step):
/// `life_stamp` on the GPU, `RGBLife.stamp(_:into:)` on the CPU.
///
/// Cells within `radius` of the center are inside: `dx² + dy² <= r² + r`
/// (distance < r + ½). The disk is clipped at the grid edges (no wrap).
public struct Stamp: Equatable, Sendable {
    public enum Kind: UInt32, Sendable {
        /// Pointer-move spray: a sparse dab in the stamp's hue.
        case trail = 0
        /// Click burst: a dense multi-channel disk with a solid rim in the stamp's hue.
        case burst = 1
    }

    /// At most this many stamps are applied per rendered frame.
    public static let maxPerFrame = 64
    /// Hue steps in the trail cycle R, RG, G, GB, B, BR.
    public static let hueStepCount: UInt32 = 6

    public var x: Int32
    public var y: Int32
    public var radius: Int32
    public var kind: Kind
    /// Hue step (0..<6) in the cycle R, RG, G, GB, B, BR. Rule-neutral: each
    /// rule maps it to its own paint (RGB Life: `RGBLife.mask(forHueStep:)`).
    public var value: UInt32
    /// Seeds the stamp's spray pattern via `CellHash`.
    public var seed: UInt32

    public init(x: Int32, y: Int32, radius: Int32, kind: Kind, value: UInt32, seed: UInt32) {
        self.x = x
        self.y = y
        self.radius = radius
        self.kind = kind
        self.value = value
        self.seed = seed
    }

    /// Whether the cell at offset (`dx`, `dy`) from the center is inside.
    public func covers(dx: Int, dy: Int) -> Bool {
        let r = Int(radius)
        return dx * dx + dy * dy <= r * r + r
    }
}

/// Turns pointer positions (continuous grid cells) into stamps: trail dabs
/// interpolated along the path so fast moves leave no gaps, and a burst on click.
public struct BrushStroke: Sendable {
    public static let trailRadius: Int32 = 2
    public static let burstRadius: Int32 = 16
    /// Cells between consecutive trail stamps (the trail radius).
    public static let spacing = Double(trailRadius)
    /// Seconds per hue step; the full R -> RG -> G -> GB -> B -> BR cycle takes 6x this.
    public static let hueStepSeconds = 0.4

    /// Where the last trail stamp landed; nil when the pen is up.
    public private(set) var lastStamp: SIMD2<Double>?
    private var serial: UInt32 = 0
    private var strokeSeed: UInt32 = 0

    public init() {}

    /// Hue step for wall time `time` (seconds).
    public static func hueStep(at time: Double) -> UInt32 {
        let steps = (time / hueStepSeconds).rounded(.down)
        let wrapped = steps.truncatingRemainder(dividingBy: Double(Stamp.hueStepCount))
        return UInt32(wrapped < 0 ? wrapped + Double(Stamp.hueStepCount) : wrapped)
    }

    /// Stamps for one frame. `position` is the pointer in continuous cell
    /// coordinates, or nil when the pointer is not over visible desktop (lifts
    /// the pen, so the next stroke does not connect). `clicked` is the left
    /// button's rising edge this frame. Returns at most `limit` stamps.
    ///
    /// Trail stamps are spaced exactly `spacing` apart along the path; a move
    /// too long for the budget spreads `limit` stamps evenly over it instead.
    public mutating func update(
        position: SIMD2<Double>?, clicked: Bool, time: Double, limit: Int = Stamp.maxPerFrame
    ) -> [Stamp] {
        guard let position else {
            lastStamp = nil
            return []
        }
        let hue = Self.hueStep(at: time)
        var stamps: [Stamp] = []
        if clicked, limit > 0 {
            stamps.append(makeStamp(at: position, radius: Self.burstRadius, kind: .burst, hue: hue))
        }
        let budget = limit - stamps.count
        guard budget > 0 else { return stamps }
        guard let last = lastStamp else {
            // New stroke: one spray pattern for all its trail stamps, so their
            // overlaps keep the trail's density instead of crowding it solid.
            serial &+= 1
            strokeSeed = CellHash.lowbias32(serial)
            stamps.append(makeStamp(at: position, radius: Self.trailRadius, kind: .trail, hue: hue))
            lastStamp = position
            return stamps
        }
        let delta = position - last
        let length = (delta * delta).sum().squareRoot()
        let count = Int(length / Self.spacing)
        guard count > 0 else { return stamps }
        let step = count > budget ? length / Double(budget) : Self.spacing
        let n = min(count, budget)
        for k in 1...n {
            let point = last + delta * (Double(k) * step / length)
            stamps.append(makeStamp(at: point, radius: Self.trailRadius, kind: .trail, hue: hue))
        }
        lastStamp = count > budget ? position : last + delta * (Double(n) * step / length)
        return stamps
    }

    /// Trail stamps share their stroke's seed; each burst gets a fresh one.
    private mutating func makeStamp(at point: SIMD2<Double>, radius: Int32, kind: Stamp.Kind, hue: UInt32) -> Stamp {
        if kind == .burst { serial &+= 1 }
        return Stamp(
            x: Int32(point.x.rounded(.down)), y: Int32(point.y.rounded(.down)),
            radius: radius, kind: kind, value: hue,
            seed: kind == .burst ? CellHash.lowbias32(serial) : strokeSeed
        )
    }
}

/// Rising-edge detector for the left mouse button, fed once per frame with
/// `NSEvent.pressedMouseButtons` (bit 0 = left). Other buttons are ignored.
public struct ClickDetector: Sendable {
    public static let leftButtonMask = 1
    private var wasDown = false

    public init() {}

    /// True on the frame the left button goes down.
    public mutating func update(pressedButtons: Int) -> Bool {
        let down = pressedButtons & Self.leftButtonMask != 0
        defer { wasDown = down }
        return down && !wasDown
    }
}

/// Debug input (`DA_DEMO_STROKE=1`): a synthetic pointer drawing a diagonal
/// stroke from the top-left toward the bottom-right of a screen, then a click
/// burst on the right, at 60 frames per second. Never touches the real cursor.
public enum DemoStroke {
    public struct Sample: Equatable, Sendable {
        /// Pointer in Cocoa screen coordinates; nil = not over the desktop (pen up).
        public var point: CGPoint?
        public var clicked: Bool
        /// Seconds since the demo started.
        public var time: Double
    }

    public static let framesPerSecond = 60.0
    /// Long enough for one full hue cycle along the stroke.
    public static let strokeFrames = 150
    public static let holdFrames = 12

    /// One sample per frame for a screen with Cocoa frame `frame`.
    public static func samples(in frame: CGRect) -> [Sample] {
        func point(_ fx: Double, _ fyFromTop: Double) -> CGPoint {
            CGPoint(x: Double(frame.minX) + fx * Double(frame.width), y: Double(frame.maxY) - fyFromTop * Double(frame.height))
        }
        var samples: [Sample] = []
        for i in 0..<strokeFrames {
            let t = Double(i) / Double(strokeFrames - 1)
            samples.append(Sample(point: point(0.08 + 0.52 * t, 0.12 + 0.76 * t), clicked: false, time: Double(i) / framesPerSecond))
        }
        // Pen up, so the jump to the click point draws no connecting trail.
        samples.append(Sample(point: nil, clicked: false, time: Double(samples.count) / framesPerSecond))
        let burst = point(0.8, 0.4)
        samples.append(Sample(point: burst, clicked: true, time: Double(samples.count) / framesPerSecond))
        for _ in 0..<holdFrames {
            samples.append(Sample(point: burst, clicked: false, time: Double(samples.count) / framesPerSecond))
        }
        return samples
    }

    /// The demo's stamps, one array per frame, for `grid`.
    public static func stampFrames(on grid: ScreenGrid) -> [[Stamp]] {
        var brush = BrushStroke()
        return samples(in: grid.frame).map { sample in
            brush.update(position: sample.point.flatMap(grid.position(of:)), clicked: sample.clicked, time: sample.time)
        }
    }
}
