/// Rock-Paper-Scissors on a torus. State byte r: species 0 = R, 1 = G, 2 = B.
/// R eats G, G eats B, B eats R. A cell converts to its predator when more
/// than `baseThreshold + offset` of its 8 Moore neighbors are that predator;
/// `offset` (0..<`offsetRange`) comes from `CellHash.hash(x, y, generation,
/// stepSeed)`, so the noise is deterministic and shared with the GPU.
///
/// Byte g is the age since the cell last converted (1 = converted this
/// generation or seeded / stamped, max 255).
///
/// CPU reference for the RPS branches of the `life_*` kernels.
public enum RockPaperScissors {
    public static let speciesCount: UInt32 = 3
    public static let baseThreshold: UInt32 = 2
    public static let offsetRange: UInt32 = 3
    /// Seed of the per-cell, per-generation threshold noise.
    public static let stepSeed: UInt32 = 0x5250_5321

    /// The species that eats `species`: G is eaten by R, B by G, R by B.
    public static func predator(of species: UInt8) -> UInt8 {
        UInt8((UInt32(species) + 2) % speciesCount)
    }

    /// Uniform random species, all at age 1.
    public static func seeded(width: Int, height: Int, seed: UInt32) -> Grid {
        var grid = Grid(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let h = CellHash.hash(x: UInt32(x), y: UInt32(y), generation: 0, seed: seed)
                set(UInt8(h % speciesCount), x: x, y: y, in: &grid)
            }
        }
        return grid
    }

    /// Sets cell (`x`, `y`) to `species` at age 1.
    public static func set(_ species: UInt8, x: Int, y: Int, in grid: inout Grid) {
        let i = grid.index(x: x, y: y)
        grid.cells[i] = species
        grid.cells[i + 1] = 1
        grid.cells[i + 2] = 0
        grid.cells[i + 3] = 0
    }

    /// Conversion threshold of cell (`x`, `y`) when stepping from `generation`.
    public static func threshold(x: Int, y: Int, generation: UInt32) -> UInt32 {
        baseThreshold + CellHash.hash(x: UInt32(x), y: UInt32(y), generation: generation, seed: stepSeed) % offsetRange
    }

    public static func step(_ grid: Grid) -> Grid {
        let w = grid.width
        let h = grid.height
        var next = grid
        next.generation = grid.generation &+ 1
        for y in 0..<h {
            for x in 0..<w {
                let i = grid.index(x: x, y: y)
                let predator = predator(of: grid.cells[i])
                var n: UInt32 = 0
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        if grid.cells[grid.index(x: (x + dx + w) % w, y: (y + dy + h) % h)] == predator { n += 1 }
                    }
                }
                if n > threshold(x: x, y: y, generation: grid.generation) {
                    next.cells[i] = predator
                    next.cells[i + 1] = 1
                } else {
                    let age = grid.cells[i + 1]
                    next.cells[i + 1] = age == 255 ? 255 : age + 1
                }
            }
        }
        return next
    }

    /// Species of hue step `step` (R, RG -> R; G, GB -> G; B, BR -> B).
    public static func species(forHueStep step: UInt32) -> UInt8 {
        UInt8((step % Stamp.hueStepCount) / 2)
    }

    /// Species `stamp` paints into (`x`, `y`), or nil: the stamp's cycling
    /// R/G/B species on a sparse spray (trail) or a solid disk (burst).
    public static func paint(_ stamp: Stamp, x: Int, y: Int) -> UInt8? {
        let dx = x - Int(stamp.x)
        let dy = y - Int(stamp.y)
        guard stamp.covers(dx: dx, dy: dy) else { return nil }
        let species = species(forHueStep: stamp.value)
        switch stamp.kind {
        case .trail:
            let h = CellHash.hash(x: UInt32(x), y: UInt32(y), generation: 0, seed: stamp.seed)
            return h & 0xFF < RGBLife.trailDensity ? species : nil
        case .burst:
            return species
        }
    }

    /// Number of cells that converted in the latest generation (age 1).
    public static func population(_ grid: Grid) -> Int {
        CyclicCA.population(grid)
    }
}
