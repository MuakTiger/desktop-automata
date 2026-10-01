import AutomataCore
import Testing

@Suite("Glow trail")
struct GlowTrailTests {
    @Test("Decay is a per-frame constant in 0.90...0.95")
    func decayRange() {
        #expect((0.90...0.95).contains(GlowTrail.decay))
    }

    @Test("Live cells show at full color: max(prev * decay, cur)")
    func takesMax() {
        #expect(GlowTrail.update(previous: 0, current: 0.7) == 0.7)
        #expect(GlowTrail.update(previous: 1, current: 0.5) == GlowTrail.decay)
        #expect(GlowTrail.update(previous: 0.5, current: 1) == 1)
        let rgb = GlowTrail.update(previous: SIMD3(1, 0, 0.2), current: SIMD3(0, 0.8, 0.9))
        #expect(rgb == SIMD3(GlowTrail.decay, 0.8, 0.9))
    }

    @Test("A dead cell fades geometrically and reaches exactly 0")
    func fadesToZero() {
        var value: Float = 3  // channels add like light, so trails can exceed 1
        var frames = 0
        var previous = value
        while value > 0 {
            value = GlowTrail.update(previous: value, current: 0)
            frames += 1
            #expect(value < previous)
            if value > 0 { #expect(abs(value - previous * GlowTrail.decay) < 1e-6) }
            previous = value
            #expect(frames < 200)
            if frames >= 200 { break }
        }
        #expect(value == 0)
        // Smooth: still visible (> 10%) for at least ~1/3 s at 60 fps.
        var visible: Float = 1
        for _ in 0..<20 { visible = GlowTrail.update(previous: visible, current: 0) }
        #expect(visible > 0.1)
    }

    @Test("Below the cutoff snaps to 0; a custom decay is honored")
    func cutoffAndCustomDecay() {
        #expect(GlowTrail.update(previous: GlowTrail.cutoff / 2, current: 0) == 0)
        #expect(GlowTrail.update(previous: 1, current: 0, decay: 0.5) == 0.5)
        #expect(GlowTrail.update(previous: 1, current: 0.25, decay: 0) == 0.25)
    }
}
