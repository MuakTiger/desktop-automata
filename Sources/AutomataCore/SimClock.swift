/// Fixed-rate simulation clock driven by a variable render frame rate.
///
/// Each frame, `advance(by:)` adds elapsed time to an accumulator measured in
/// generations and returns how many whole generations to step. At most
/// `maxStepsPerFrame` are returned; any larger backlog (a stalled frame, a long
/// pause of the render loop) is dropped instead of being replayed in a burst.
public struct SimClock: Equatable, Sendable {
    public var generationsPerSecond: Int
    public let maxStepsPerFrame: Int
    /// Fractional generations carried over to the next frame (always in 0..<1
    /// after `advance(by:)`).
    public private(set) var accumulator: Double = 0

    public init(generationsPerSecond: Int, maxStepsPerFrame: Int = 4) {
        precondition(maxStepsPerFrame > 0)
        self.generationsPerSecond = generationsPerSecond
        self.maxStepsPerFrame = maxStepsPerFrame
    }

    /// Advances by `seconds` of wall time; returns the generations to step now.
    public mutating func advance(by seconds: Double) -> Int {
        guard seconds > 0, generationsPerSecond > 0 else { return 0 }
        accumulator += seconds * Double(generationsPerSecond)
        let whole = accumulator.rounded(.down)
        accumulator -= whole
        return whole >= Double(maxStepsPerFrame) ? maxStepsPerFrame : Int(whole)
    }

    /// Drops any partially accumulated generation.
    public mutating func reset() {
        accumulator = 0
    }
}
