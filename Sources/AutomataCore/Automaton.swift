import Foundation

extension AutomatonRule {
    /// Rule index uniform passed to the MSL kernels (`kRule*` constants there).
    public var index: UInt32 {
        switch self {
        case .rgbLife: return 0
        case .briansBrain: return 1
        case .cyclic: return 2
        case .rockPaperScissors: return 3
        }
    }

    /// What `Automaton.population` counts, for display.
    public var populationTitle: String {
        switch self {
        case .rgbLife: return "live"
        case .briansBrain: return "firing"
        case .cyclic: return "advancing"
        case .rockPaperScissors: return "converting"
        }
    }
}

/// Rule dispatch over the CPU references (`RGBLife`, `BriansBrain`, `CyclicCA`,
/// `RockPaperScissors`) that the GPU kernels mirror.
public enum Automaton {
    public static func seeded(_ rule: AutomatonRule, width: Int, height: Int, seed: UInt32) -> Grid {
        switch rule {
        case .rgbLife: return RGBLife.seeded(width: width, height: height, seed: seed)
        case .briansBrain: return BriansBrain.seeded(width: width, height: height, seed: seed)
        case .cyclic: return CyclicCA.seeded(width: width, height: height, seed: seed)
        case .rockPaperScissors: return RockPaperScissors.seeded(width: width, height: height, seed: seed)
        }
    }

    public static func step(_ rule: AutomatonRule, _ grid: Grid) -> Grid {
        switch rule {
        case .rgbLife: return RGBLife.step(grid)
        case .briansBrain: return BriansBrain.step(grid)
        case .cyclic: return CyclicCA.step(grid)
        case .rockPaperScissors: return RockPaperScissors.step(grid)
        }
    }

    public static func step(_ rule: AutomatonRule, _ grid: Grid, generations: Int) -> Grid {
        var result = grid
        for _ in 0..<generations { result = step(rule, result) }
        return result
    }

    /// Paints `stamps` into `grid` for `rule`. RGB Life ORs channels in (order
    /// independent); the other rules set the painted state at age 1, later
    /// stamps winning, exactly like `life_stamp`.
    public static func stamp(_ rule: AutomatonRule, _ stamps: [Stamp], into grid: inout Grid) {
        let paint: (Stamp, Int, Int) -> UInt8?
        let set: (UInt8, Int, Int, inout Grid) -> Void
        switch rule {
        case .rgbLife:
            RGBLife.stamp(stamps, into: &grid)
            return
        case .briansBrain:
            paint = BriansBrain.paint
            set = { BriansBrain.set($0, x: $1, y: $2, in: &$3) }
        case .cyclic:
            paint = { CyclicCA.paint($0, x: $1, y: $2) }
            set = { CyclicCA.set($0, x: $1, y: $2, in: &$3) }
        case .rockPaperScissors:
            paint = RockPaperScissors.paint
            set = { RockPaperScissors.set($0, x: $1, y: $2, in: &$3) }
        }
        for stamp in stamps {
            let r = Int(stamp.radius)
            let y0 = max(Int(stamp.y) - r, 0), y1 = min(Int(stamp.y) + r, grid.height - 1)
            let x0 = max(Int(stamp.x) - r, 0), x1 = min(Int(stamp.x) + r, grid.width - 1)
            guard y0 <= y1, x0 <= x1 else { continue }
            for y in y0...y1 {
                for x in x0...x1 {
                    if let value = paint(stamp, x, y) { set(value, x, y, &grid) }
                }
            }
        }
    }

    /// Rule-specific population (see `AutomatonRule.populationTitle`): live
    /// cells (RGB Life, any channel), firing cells (Brian's Brain), cells that
    /// advanced / converted in the latest generation (Cyclic, RPS).
    public static func population(_ rule: AutomatonRule, _ grid: Grid) -> Int {
        switch rule {
        case .rgbLife:
            return stride(from: 0, to: grid.cells.count, by: Grid.bytesPerCell)
                .reduce(0) { $0 + (grid.cells[$1] & RGBLife.liveMask != 0 ? 1 : 0) }
        case .briansBrain: return BriansBrain.population(grid)
        case .cyclic: return CyclicCA.population(grid)
        case .rockPaperScissors: return RockPaperScissors.population(grid)
        }
    }
}

/// Colors for the non-Life rules. CPU reference for the rule branches of
/// `life_colorize`, which receives these constants through `ColorizeParams`.
public enum RuleColoring {
    /// Brian's Brain: palette units the hue shifts across the screen (left/top
    /// to right/bottom), so the brain is a rainbow, not one color.
    public static let spatialSpread: Float = 2
    /// Brian's Brain: how far firing cells are pushed toward white.
    public static let fireFlash: Float = 0.35
    /// Brian's Brain: brightness of refractory cells (palette + 1/3).
    public static let refractoryBrightness: Float = 0.85
    /// Brian's Brain: off cells glow (palette + 2/3, scaled by the afterimage
    /// brightness) for this many generations after going off, fading linearly.
    public static let trailLength: Float = 8
    /// Cyclic / RPS: push toward white on the generation a cell changed.
    public static let frontFlash: Float = 0.25
    /// Cyclic / RPS: brightness lost from age 1 to 256 (log2 scale), so active
    /// fronts are bright and stagnant regions dim.
    public static let ageDim: Float = 0.6
    /// RPS: palette distance between the species (a third of the period).
    public static let speciesSpread: Float = CosinePalette.period / 3
    /// RPS: weight of the species' pure primary (R, G, B) mixed with the
    /// palette color, so the three species stay distinct in every palette.
    public static let speciesTint: Float = 0.55

    /// Brightness of a Cyclic / RPS cell of age `age`.
    public static func ageBrightness(_ age: UInt8) -> Float {
        1 - ageDim * log2(Float(max(age, 1))) / 8
    }

    /// Linear color of cell (`x`, `y`) under `rule` (not RGB Life; use `LifeColoring`).
    public static func color(
        _ rule: AutomatonRule, of grid: Grid, x: Int, y: Int,
        palette: CosinePalette, drift: Float, afterimage: Float
    ) -> SIMD3<Float> {
        let i = grid.index(x: x, y: y)
        let state = grid.cells[i]
        let age = grid.cells[i + 1]
        switch rule {
        case .rgbLife:
            return LifeColoring.color(of: grid, x: x, y: y, palette: palette, drift: drift, afterimage: afterimage)
        case .briansBrain:
            let t = drift + spatialSpread * 0.5 * (Float(x) / Float(grid.width) + Float(y) / Float(grid.height))
            switch state {
            case BriansBrain.firing:
                let c = palette.color(at: t)
                return c + (1 - c) * fireFlash
            case BriansBrain.refractory:
                return palette.color(at: t + 1.0 / 3) * refractoryBrightness
            default:
                guard age >= 1, Float(age) <= trailLength else { return .zero }
                return palette.color(at: t + 2.0 / 3) * (afterimage * (trailLength + 1 - Float(age)) / trailLength)
            }
        case .cyclic:
            let t = drift + CosinePalette.period * Float(state) / Float(CyclicCA.states)
            return front(palette.color(at: t), age: age)
        case .rockPaperScissors:
            var primary = SIMD3<Float>(repeating: 0)
            primary[Int(state % 3)] = 1
            let tinted = primary * speciesTint + palette.color(at: drift + Float(state) * speciesSpread) * (1 - speciesTint)
            return front(tinted, age: age)
        }
    }

    private static func front(_ color: SIMD3<Float>, age: UInt8) -> SIMD3<Float> {
        var c = color * ageBrightness(age)
        if age == 1 { c += (1 - c) * frontFlash }
        return c
    }
}
