/// RGB Life: Conway's B3/S23 run independently on the red, green and blue
/// channels of a torus. Overlapping live channels mix (red + green = yellow).
///
/// This is the CPU reference for the `life_seed` / `life_step` kernels in
/// `ShaderSource.metal`; both must stay identical.
public enum RGBLife {
    public static let channelCount = 3
    /// A channel is seeded alive when its 8-bit hash slice is below this:
    /// 77 / 256 ≈ 30% density per channel.
    public static let seedThreshold: UInt32 = 77
    /// Bits of state byte 0 holding the live mask.
    public static let liveMask: UInt8 = 0b111
    /// Bit `deathFlagShift + c` of state byte 0 is set when channel `c` died in
    /// the latest generation.
    public static let deathFlagShift: UInt8 = 3

    /// Whether channel `channel` of cell (`x`, `y`) is alive.
    public static func isAlive(_ grid: Grid, x: Int, y: Int, channel: Int) -> Bool {
        (grid.state(x: x, y: y) >> UInt8(channel)) & 1 == 1
    }

    /// Whether channel `channel` of cell (`x`, `y`) was born in the latest
    /// generation (or seeded): alive at age 1.
    public static func isNewborn(_ grid: Grid, x: Int, y: Int, channel: Int) -> Bool {
        isAlive(grid, x: x, y: y, channel: channel) && grid.age(x: x, y: y, channel: channel) == 1
    }

    /// Whether channel `channel` of cell (`x`, `y`) died in the latest generation.
    public static func diedLastGeneration(_ grid: Grid, x: Int, y: Int, channel: Int) -> Bool {
        (grid.state(x: x, y: y) >> (deathFlagShift + UInt8(channel))) & 1 == 1
    }

    /// A grid where each channel of each cell is alive with ~30% probability,
    /// decided by `CellHash.hash(x, y, generation: 0, seed)`. Byte `c` of the
    /// hash decides channel `c`. Live channels start at age 1.
    public static func seeded(width: Int, height: Int, seed: UInt32) -> Grid {
        var grid = Grid(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let h = CellHash.hash(x: UInt32(x), y: UInt32(y), generation: 0, seed: seed)
                var mask: UInt8 = 0
                for c in 0..<channelCount where (h >> (8 * UInt32(c))) & 0xFF < seedThreshold {
                    mask |= 1 << UInt8(c)
                }
                setMask(mask, x: x, y: y, in: &grid)
            }
        }
        return grid
    }

    /// Sets cell (`x`, `y`) to `mask` with live channels at age 1 and dead ones
    /// at 0. Clears the cell's death flags.
    public static func setMask(_ mask: UInt8, x: Int, y: Int, in grid: inout Grid) {
        let i = grid.index(x: x, y: y)
        grid.cells[i] = mask & liveMask
        for c in 0..<channelCount {
            grid.cells[i + 1 + c] = (mask >> UInt8(c)) & 1
        }
    }

    /// One B3/S23 generation per channel on a torus.
    /// Ages: born -> 1, survived -> age + 1 (saturating at 255), dead -> 0.
    /// Death flags: set for channels alive before and dead now, cleared otherwise.
    public static func step(_ grid: Grid) -> Grid {
        let w = grid.width
        let h = grid.height
        var next = grid
        next.generation = grid.generation &+ 1
        for y in 0..<h {
            for x in 0..<w {
                var counts = (0, 0, 0)
                // Iterate offsets (not coordinates) so 1- and 2-wide grids
                // count wrapped duplicates exactly like the GPU kernel.
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = (x + dx + w) % w
                        let ny = (y + dy + h) % h
                        let m = grid.cells[grid.index(x: nx, y: ny)]
                        counts.0 += Int(m & 1)
                        counts.1 += Int((m >> 1) & 1)
                        counts.2 += Int((m >> 2) & 1)
                    }
                }
                let i = grid.index(x: x, y: y)
                let mask = grid.cells[i]
                var nextMask: UInt8 = 0
                for (c, n) in [counts.0, counts.1, counts.2].enumerated() {
                    let alive = (mask >> UInt8(c)) & 1 == 1
                    let lives = n == 3 || (alive && n == 2)
                    let age = grid.cells[i + 1 + c]
                    let nextAge: UInt8
                    if lives {
                        nextMask |= 1 << UInt8(c)
                        nextAge = alive ? (age == 255 ? 255 : age + 1) : 1
                    } else {
                        if alive { nextMask |= 1 << (deathFlagShift + UInt8(c)) }
                        nextAge = 0
                    }
                    next.cells[i + 1 + c] = nextAge
                }
                next.cells[i] = nextMask
            }
        }
        return next
    }

    // MARK: Stamps (CPU reference for `life_stamp`)

    /// Channel masks for the hue steps R, RG, G, GB, B, BR.
    public static let hueMasks: [UInt8] = [0b001, 0b011, 0b010, 0b110, 0b100, 0b101]
    /// Trail cells are painted when the hash's low byte is below this (50%).
    public static let trailDensity: UInt32 = 128
    /// Burst interior: each channel is painted when its hash byte is below this (~45%).
    public static let burstDensity: UInt32 = 115
    /// Width in cells of a burst's solid rim.
    public static let burstRingWidth: Int32 = 2

    public static func mask(forHueStep step: UInt32) -> UInt8 {
        hueMasks[Int(step % Stamp.hueStepCount)]
    }

    /// Channels `stamp` paints into cell (`x`, `y`): 0 outside its disk. Trail:
    /// the hue mask on a sparse hash spray. Burst: the hue mask on its rim, an
    /// independent dense hash spray per channel inside.
    public static func paint(_ stamp: Stamp, x: Int, y: Int) -> UInt8 {
        let dx = x - Int(stamp.x)
        let dy = y - Int(stamp.y)
        guard stamp.covers(dx: dx, dy: dy) else { return 0 }
        let h = CellHash.hash(x: UInt32(x), y: UInt32(y), generation: 0, seed: stamp.seed)
        let hueMask = mask(forHueStep: stamp.value)
        switch stamp.kind {
        case .trail:
            return h & 0xFF < trailDensity ? hueMask : 0
        case .burst:
            let inner = Int(stamp.radius - burstRingWidth)
            if dx * dx + dy * dy > inner * inner + inner { return hueMask }
            var paint: UInt8 = 0
            for c in 0..<channelCount where (h >> (8 * UInt32(c))) & 0xFF < burstDensity {
                paint |= 1 << UInt8(c)
            }
            return paint
        }
    }

    /// Paints `stamps` into `grid`: painted channels become alive at age 1
    /// (newborn, so they flash) and lose their death flag. Never kills; the
    /// result does not depend on stamp order. Does not advance the generation.
    public static func stamp(_ stamps: [Stamp], into grid: inout Grid) {
        for stamp in stamps {
            let r = Int(stamp.radius)
            let y0 = max(Int(stamp.y) - r, 0), y1 = min(Int(stamp.y) + r, grid.height - 1)
            let x0 = max(Int(stamp.x) - r, 0), x1 = min(Int(stamp.x) + r, grid.width - 1)
            guard y0 <= y1, x0 <= x1 else { continue }
            for y in y0...y1 {
                for x in x0...x1 {
                    let paint = paint(stamp, x: x, y: y)
                    guard paint != 0 else { continue }
                    let i = grid.index(x: x, y: y)
                    grid.cells[i] = (grid.cells[i] | paint) & ~(paint << deathFlagShift)
                    for c in 0..<channelCount where (paint >> UInt8(c)) & 1 == 1 {
                        grid.cells[i + 1 + c] = 1
                    }
                }
            }
        }
    }

    /// `grid` advanced by `generations` steps.
    public static func step(_ grid: Grid, generations: Int) -> Grid {
        var result = grid
        for _ in 0..<generations {
            result = step(result)
        }
        return result
    }
}
