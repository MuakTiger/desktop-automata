/// Cyclic cellular automaton on a torus (Griffeath). State byte r: 0..<states.
/// A cell in state s advances to (s + 1) mod states when at least `threshold`
/// of its 8 Moore neighbors are already in (s + 1) mod states.
///
/// Byte g is the age in the current state: 1 on the generation the cell
/// advanced (or was seeded / stamped), + 1 per generation it stays, max 255.
///
/// CPU reference for the cyclic branches of the `life_*` kernels.
public enum CyclicCA {
    /// Number of states (the rainbow has this many bands).
    public static let states: UInt32 = 14
    /// Successor neighbors needed to advance.
    public static let threshold: UInt32 = 1

    /// Uniform random states, all at age 1.
    public static func seeded(width: Int, height: Int, seed: UInt32) -> Grid {
        var grid = Grid(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let h = CellHash.hash(x: UInt32(x), y: UInt32(y), generation: 0, seed: seed)
                set(UInt8(h % states), x: x, y: y, in: &grid)
            }
        }
        return grid
    }

    /// Sets cell (`x`, `y`) to `state` at age 1.
    public static func set(_ state: UInt8, x: Int, y: Int, in grid: inout Grid) {
        let i = grid.index(x: x, y: y)
        grid.cells[i] = state
        grid.cells[i + 1] = 1
        grid.cells[i + 2] = 0
        grid.cells[i + 3] = 0
    }

    public static func step(_ grid: Grid, states: UInt32 = states, threshold: UInt32 = threshold) -> Grid {
        let w = grid.width
        let h = grid.height
        var next = grid
        next.generation = grid.generation &+ 1
        for y in 0..<h {
            for x in 0..<w {
                let i = grid.index(x: x, y: y)
                let state = UInt32(grid.cells[i])
                let successor = UInt8((state + 1) % states)
                var n: UInt32 = 0
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        if grid.cells[grid.index(x: (x + dx + w) % w, y: (y + dy + h) % h)] == successor { n += 1 }
                    }
                }
                if n >= threshold {
                    next.cells[i] = successor
                    next.cells[i + 1] = 1
                } else {
                    let age = grid.cells[i + 1]
                    next.cells[i + 1] = age == 255 ? 255 : age + 1
                }
            }
        }
        return next
    }

    /// Integer square root (floor), identical to `isqrt` in the MSL.
    public static func isqrt(_ value: Int) -> Int {
        var k = 0
        while (k + 1) * (k + 1) <= value { k += 1 }
        return k
    }

    /// State `stamp` paints into (`x`, `y`), or nil. The base state follows the
    /// stamp's time-cycling hue step around the cycle. Trail: the base state on
    /// a sparse hash spray. Burst: concentric rings counting down from the base
    /// state outward, which launch an expanding wave.
    public static func paint(_ stamp: Stamp, x: Int, y: Int, states: UInt32 = states) -> UInt8? {
        let dx = x - Int(stamp.x)
        let dy = y - Int(stamp.y)
        guard stamp.covers(dx: dx, dy: dy) else { return nil }
        let base = (stamp.value % Stamp.hueStepCount) * states / Stamp.hueStepCount
        switch stamp.kind {
        case .trail:
            let h = CellHash.hash(x: UInt32(x), y: UInt32(y), generation: 0, seed: stamp.seed)
            return h & 0xFF < RGBLife.trailDensity ? UInt8(base) : nil
        case .burst:
            let ring = UInt32(isqrt(dx * dx + dy * dy)) % states
            return UInt8((base + states - ring) % states)
        }
    }

    /// Number of cells that advanced in the latest generation (age 1).
    public static func population(_ grid: Grid) -> Int {
        stride(from: 0, to: grid.cells.count, by: Grid.bytesPerCell).reduce(0) { $0 + (grid.cells[$1 + 1] == 1 ? 1 : 0) }
    }
}
