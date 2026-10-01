import Testing
@testable import AutomataCore

@Suite("SimClock")
struct SimClockTests {
    @Test("Steps track generations per second independent of frame rate")
    func stepCount() {
        // Exact binary fractions: 16 gen/s at 64 fps is one step every 4 frames.
        var clock = SimClock(generationsPerSecond: 16)
        let perFrame = (0..<8).map { _ in clock.advance(by: 1.0 / 64) }
        #expect(perFrame == [0, 0, 0, 1, 0, 0, 0, 1])

        var slow = SimClock(generationsPerSecond: 16)
        #expect((0..<64).reduce(0) { total, _ in total + slow.advance(by: 1.0 / 64) } == 16)

        // 10 gen/s at 60 fps for 10 s: 100 steps (floating point may defer the last).
        var tenAt60 = SimClock(generationsPerSecond: 10)
        let total = (0..<600).reduce(0) { sum, _ in sum + tenAt60.advance(by: 1.0 / 60) }
        #expect(total == 99 || total == 100)

        // 60 gen/s at 30 fps: 2 per frame.
        var fast = SimClock(generationsPerSecond: 64)
        #expect(fast.advance(by: 1.0 / 32) == 2)
    }

    @Test("Steps per frame are capped and the backlog is dropped")
    func cap() {
        var clock = SimClock(generationsPerSecond: 64, maxStepsPerFrame: 4)
        #expect(clock.advance(by: 1.0) == 4)
        #expect(clock.accumulator < 1)
        #expect(clock.advance(by: 1.0 / 64) == 1)
        #expect(clock.advance(by: 10) == 4)
    }

    @Test("No steps for zero or negative time, or zero speed")
    func degenerate() {
        var clock = SimClock(generationsPerSecond: 10)
        #expect(clock.advance(by: 0) == 0)
        #expect(clock.advance(by: -5) == 0)
        #expect(clock.accumulator == 0)
        var stopped = SimClock(generationsPerSecond: 0)
        #expect(stopped.advance(by: 1) == 0)
    }

    @Test("Speed changes apply on the next frame; reset drops the fraction")
    func speedChangeAndReset() {
        var clock = SimClock(generationsPerSecond: 2)
        #expect(clock.advance(by: 0.25) == 0)
        #expect(clock.accumulator == 0.5)
        clock.generationsPerSecond = 8
        #expect(clock.advance(by: 0.25) == 2)  // 0.5 + 2.0
        #expect(clock.accumulator == 0.5)
        clock.reset()
        #expect(clock.accumulator == 0)
    }
}
