import Testing
@testable import AutomataCore

/// Positions well outside one period, including negative ones.
private let samples: [Float] = stride(from: -2.0, through: 4.0, by: 1.0 / 64).map { Float($0) }
/// One full period.
private let period: [Float] = stride(from: 0.0, to: 2.0, by: 1.0 / 128).map { Float($0) }

private func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    let d = a - b
    return (d * d).sum().squareRoot()
}

@Suite("Cosine palettes")
struct CosinePaletteTests {
    @Test("Outputs stay in [0, 1]", arguments: Palette.allCases)
    func unitRange(palette: Palette) {
        let outside = samples.filter { t in
            let c = palette.cosine.color(at: t)
            return !(c.min() >= 0 && c.max() <= 1)
        }
        #expect(outside.isEmpty, "\(palette) leaves [0, 1] at t = \(outside.prefix(5))")
    }

    @Test("Each palette is vivid: some component sweeps most of [0, 1]", arguments: Palette.allCases)
    func vivid(palette: Palette) {
        let colors = period.map { palette.cosine.color(at: $0) }
        let ranges = (0..<3).map { k in colors.map { $0[k] }.max()! - colors.map { $0[k] }.min()! }
        #expect(ranges.max()! > 0.7, "\(palette) ranges \(ranges)")
    }

    @Test("Every pair of palettes looks different")
    func distinct() {
        let all = Palette.allCases
        for i in all.indices {
            for j in all.indices where j > i {
                let mean = period.map { distance(all[i].cosine.color(at: $0), all[j].cosine.color(at: $0)) }
                    .reduce(0, +) / Float(period.count)
                #expect(mean > 0.2, "\(all[i]) vs \(all[j]): mean RGB distance \(mean)")
            }
        }
    }

    @Test("Palettes repeat with period 2, so the hue drift can wrap without a seam", arguments: Palette.allCases)
    func periodic(palette: Palette) {
        let worst = samples.map { distance(palette.cosine.color(at: $0), palette.cosine.color(at: $0 + CosinePalette.period)) }.max()!
        #expect(worst < 1e-4)
        let before = palette.cosine.color(at: LifeColoring.hueDrift(seconds: 2 * LifeColoring.driftSecondsPerUnit - 0.01))
        let after = palette.cosine.color(at: LifeColoring.hueDrift(seconds: 2 * LifeColoring.driftSecondsPerUnit + 0.01))
        #expect(distance(before, after) < 0.01)
    }

    @Test("Known values: Rainbow and Pure RGB put red, green and blue 1/3 apart")
    func knownValues() {
        let rainbow = Palette.rainbow.cosine
        #expect(distance(rainbow.color(at: 0), [1, 0.25, 0.25]) < 1e-5)
        #expect(distance(rainbow.color(at: 1.0 / 3), [0.25, 1, 0.25]) < 1e-5)
        let pure = Palette.pureRGB.cosine
        #expect(distance(pure.color(at: 0), [1, 0, 0]) < 1e-5)
        #expect(distance(pure.color(at: 1.0 / 3), [0, 1, 0]) < 1e-5)
        #expect(distance(pure.color(at: 2.0 / 3), [0, 0, 1]) < 1e-5)
    }
}

@Suite("Life coloring (CPU reference)")
struct LifeColoringTests {
    /// 1x1 grid with `state` in byte 0 and `ages` in bytes 1...3.
    private func cell(state: UInt8, ages: (UInt8, UInt8, UInt8)) -> Grid {
        var grid = Grid(width: 1, height: 1)
        grid.cells = [state, ages.0, ages.1, ages.2]
        return grid
    }

    private func color(_ grid: Grid, _ palette: Palette = .neon, drift: Float = 0, afterimage: Float = LifeColoring.afterimage) -> SIMD3<Float> {
        LifeColoring.color(of: grid, x: 0, y: 0, palette: palette.cosine, drift: drift, afterimage: afterimage)
    }

    @Test("Age position starts at 0, grows with age and stays within ageSpan")
    func agePosition() {
        #expect(LifeColoring.agePosition(1) == 0)
        let positions = (1...255).map { LifeColoring.agePosition(UInt8($0)) }
        #expect(zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 })
        #expect(positions.last! <= LifeColoring.ageSpan)
    }

    @Test("Hue drift starts at 0, moves one unit per driftSecondsPerUnit, wraps at the period")
    func hueDrift() {
        let unit = LifeColoring.driftSecondsPerUnit
        #expect(LifeColoring.hueDrift(seconds: 0) == 0)
        #expect(abs(LifeColoring.hueDrift(seconds: unit) - 1) < 1e-6)
        #expect(abs(LifeColoring.hueDrift(seconds: unit / 2) - 0.5) < 1e-6)
        #expect(abs(LifeColoring.hueDrift(seconds: 2 * unit + 1) - Float(1 / unit)) < 1e-5)
        #expect(LifeColoring.hueDrift(seconds: 1_000_000) < CosinePalette.period)
    }

    @Test("Empty cell is black; a dead cell without a death flag has no afterimage")
    func empty() {
        #expect(color(cell(state: 0, ages: (0, 0, 0))) == .zero)
    }

    @Test("Older cells move along the palette", arguments: Palette.allCases)
    func ageDrivesColor(palette: Palette) {
        let young = color(cell(state: 0b001, ages: (2, 0, 0)), palette)
        let old = color(cell(state: 0b001, ages: (200, 0, 0)), palette)
        #expect(young == palette.cosine.color(at: LifeColoring.agePosition(2)))
        #expect(distance(young, old) > 0.05, "\(palette): \(young) vs \(old)")
    }

    @Test("Newborn channels flash toward white for their birth generation", arguments: Palette.allCases)
    func birthFlash(palette: Palette) {
        let base = palette.cosine.color(at: 0)
        let newborn = color(cell(state: 0b001, ages: (1, 0, 0)), palette)
        #expect(distance(newborn, base + (1 - base) * LifeColoring.birthFlash) < 1e-6)
        #expect(newborn.min() >= LifeColoring.birthFlash - 1e-6)
    }

    @Test("A channel that just died leaves a dim afterimage, only when enabled")
    func afterimage() {
        let died = cell(state: 1 << (RGBLife.deathFlagShift + 1), ages: (0, 0, 0))  // green died
        let base = Palette.neon.cosine.color(at: LifeColoring.channelSpread)
        #expect(distance(color(died), base * LifeColoring.afterimage) < 1e-6)
        #expect(color(died, afterimage: 0) == .zero)
        #expect(color(died).max() <= LifeColoring.afterimage)
    }

    @Test("Channels add, each offset by channelSpread, and the drift shifts them all")
    func channelsAdd() {
        let drift: Float = 0.37
        let red = color(cell(state: 0b001, ages: (5, 0, 0)), drift: drift)
        let blue = color(cell(state: 0b100, ages: (0, 0, 9)), drift: drift)
        let both = color(cell(state: 0b101, ages: (5, 0, 9)), drift: drift)
        #expect(distance(both, red + blue) < 1e-6)
        let palette = Palette.neon.cosine
        #expect(red == palette.color(at: drift + LifeColoring.agePosition(5)))
        #expect(blue == palette.color(at: drift + 2 * LifeColoring.channelSpread + LifeColoring.agePosition(9)))
    }
}
