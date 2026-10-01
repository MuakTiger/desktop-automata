/// Brian's Brain on a torus. State byte r: 0 off, 1 firing, 2 refractory.
/// firing -> refractory -> off; off -> firing iff exactly 2 of the 8 Moore
/// neighbors are firing.
///
/// Byte g is the age in the current state: firing and refractory cells are
/// always 1 (each lasts one generation); off cells count generations since they
/// went off (1, 2, ... saturating at 255) so the colorizer can draw a fading
/// trail, and stay 0 if they have not fired since seeding.
///
/// CPU reference for the Brian's Brain branches of the `life_*` kernels.
public enum BriansBrain {
    public static let off: UInt8 = 0
    public static let firing: UInt8 = 1
    public static let refractory: UInt8 = 2
    /// A cell is seeded firing when its hash's low byte is below this (~30%).
    public static let seedThreshold: UInt32 = 77

    public static func seeded(width: Int, height: Int, seed: UInt32) -> Grid {
        var grid = Grid(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let h = CellHash.hash(x: UInt32(x), y: UInt32(y), generation: 0, seed: seed)
                if h & 0xFF < seedThreshold { set(firing, x: x, y: y, in: &grid) }
            }
        }
        return grid
    }

    /// Sets cell (`x`, `y`) to `state` at age 1 (off cells: age 0, never fired).
    public static func set(_ state: UInt8, x: Int, y: Int, in grid: inout Grid) {
        let i = grid.index(x: x, y: y)
        grid.cells[i] = state
        grid.cells[i + 1] = state == off ? 0 : 1
        grid.cells[i + 2] = 0
        grid.cells[i + 3] = 0
    }

    public static func step(_ grid: Grid) -> Grid {
        let w = grid.width
        let h = grid.height
        var next = grid
        next.generation = grid.generation &+ 1
        for y in 0..<h {
            for x in 0..<w {
                let i = grid.index(x: x, y: y)
                let state = grid.cells[i]
                let age = grid.cells[i + 1]
                var nextState = off
                var nextAge: UInt8 = 0
                switch state {
                case firing:
                    nextState = refractory
                    nextAge = 1
                case refractory:
                    nextAge = 1
                default:
                    var n = 0
                    for dy in -1...1 {
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            if grid.cells[grid.index(x: (x + dx + w) % w, y: (y + dy + h) % h)] == firing { n += 1 }
                        }
                    }
                    if n == 2 {
                        nextState = firing
                        nextAge = 1
                    } else {
                        nextAge = age == 0 ? 0 : (age == 255 ? 255 : age + 1)
                    }
                }
                next.cells[i] = nextState
                next.cells[i + 1] = nextAge
                next.cells[i + 2] = 0
                next.cells[i + 3] = 0
            }
        }
        return next
    }

    /// State `stamp` paints into (`x`, `y`), or nil. Always `firing`: trail on a
    /// sparse hash spray, burst on a solid rim around a dense spray.
    public static func paint(_ stamp: Stamp, x: Int, y: Int) -> UInt8? {
        let dx = x - Int(stamp.x)
        let dy = y - Int(stamp.y)
        guard stamp.covers(dx: dx, dy: dy) else { return nil }
        let h = CellHash.hash(x: UInt32(x), y: UInt32(y), generation: 0, seed: stamp.seed)
        switch stamp.kind {
        case .trail:
            return h & 0xFF < RGBLife.trailDensity ? firing : nil
        case .burst:
            let inner = Int(stamp.radius - RGBLife.burstRingWidth)
            if dx * dx + dy * dy > inner * inner + inner { return firing }
            return h & 0xFF < RGBLife.burstDensity ? firing : nil
        }
    }

    /// Number of firing cells.
    public static func population(_ grid: Grid) -> Int {
        stride(from: 0, to: grid.cells.count, by: Grid.bytesPerCell).reduce(0) { $0 + (grid.cells[$1] == firing ? 1 : 0) }
    }
}
