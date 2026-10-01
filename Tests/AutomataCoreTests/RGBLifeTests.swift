import Testing
@testable import AutomataCore

private struct Cell: Hashable, CustomStringConvertible {
    let x: Int
    let y: Int
    init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
    var description: String { "(\(x),\(y))" }
}

private let blinker = [Cell(2, 3), Cell(3, 3), Cell(4, 3)]
private let block = [Cell(2, 2), Cell(3, 2), Cell(2, 3), Cell(3, 3)]
/// Travels +1 x, +1 y every 4 generations (y grows downward).
private let glider = [Cell(1, 0), Cell(2, 1), Cell(0, 2), Cell(1, 2), Cell(2, 2)]

/// Grid with `cells` alive in the channels of `mask` (ORed into existing state).
private func makeGrid(_ width: Int, _ height: Int, _ layers: [(cells: [Cell], mask: UInt8)]) -> Grid {
    var grid = Grid(width: width, height: height)
    for layer in layers {
        for cell in layer.cells {
            let mask = grid.state(x: cell.x, y: cell.y) | layer.mask
            RGBLife.setMask(mask, x: cell.x, y: cell.y, in: &grid)
        }
    }
    return grid
}

private func makeGrid(_ width: Int, _ height: Int, alive cells: [Cell], mask: UInt8 = 0b111) -> Grid {
    makeGrid(width, height, [(cells, mask)])
}

private func live(_ grid: Grid, channel: Int) -> Set<Cell> {
    var result = Set<Cell>()
    for y in 0..<grid.height {
        for x in 0..<grid.width where (grid.state(x: x, y: y) >> UInt8(channel)) & 1 == 1 {
            result.insert(Cell(x, y))
        }
    }
    return result
}

/// Cells of `grid` where `flag(grid, x, y, channel)` holds.
private func flagged(_ grid: Grid, channel: Int, _ flag: (Grid, Int, Int, Int) -> Bool) -> Set<Cell> {
    var result = Set<Cell>()
    for y in 0..<grid.height {
        for x in 0..<grid.width where flag(grid, x, y, channel) {
            result.insert(Cell(x, y))
        }
    }
    return result
}

private func translated(_ cells: [Cell], dx: Int, dy: Int, width: Int, height: Int) -> Set<Cell> {
    Set(cells.map { Cell(($0.x + dx + width) % width, ($0.y + dy + height) % height) })
}

/// Only channel `channel` of `grid` (live bit, death flag and age byte); everything else zeroed.
private func isolate(_ grid: Grid, channel: Int) -> Grid {
    var result = Grid(width: grid.width, height: grid.height)
    result.generation = grid.generation
    let bits: UInt8 = (1 << UInt8(channel)) | (1 << (RGBLife.deathFlagShift + UInt8(channel)))
    for i in stride(from: 0, to: grid.cells.count, by: Grid.bytesPerCell) {
        result.cells[i] = grid.cells[i] & bits
        result.cells[i + 1 + channel] = grid.cells[i + 1 + channel]
    }
    return result
}

@Suite("RGB Life (CPU reference)")
struct RGBLifeTests {
    @Test("Blinker oscillates with period 2", arguments: [UInt8(0b001), 0b010, 0b100, 0b111])
    func blinkerPeriod2(mask: UInt8) {
        let start = makeGrid(8, 8, alive: blinker, mask: mask)
        let gen1 = RGBLife.step(start)
        let gen2 = RGBLife.step(gen1)
        for c in 0..<3 where (mask >> UInt8(c)) & 1 == 1 {
            #expect(live(gen1, channel: c) == [Cell(3, 2), Cell(3, 3), Cell(3, 4)])
            #expect(live(gen2, channel: c) == Set(blinker))
        }
        // Live masks repeat (death flags differ: gen 2's dying cells are gen 1's ends).
        #expect(gen2.cells.enumerated().filter { $0.offset % 4 == 0 }.map { $0.element & RGBLife.liveMask }
            == start.cells.enumerated().filter { $0.offset % 4 == 0 }.map(\.element))
        #expect(gen2.generation == 2)
    }

    @Test("Block is a still life; ages count up and saturate at 255")
    func blockStillLife() {
        let start = makeGrid(6, 6, alive: block, mask: 0b010)
        var grid = start
        for _ in 0..<10 {
            grid = RGBLife.step(grid)
            #expect(live(grid, channel: 1) == Set(block))
            #expect(live(grid, channel: 0).isEmpty && live(grid, channel: 2).isEmpty)
        }
        #expect(grid.age(x: 2, y: 2, channel: 1) == 11)
        #expect(grid.age(x: 2, y: 2, channel: 0) == 0)
        #expect(grid.age(x: 0, y: 0, channel: 1) == 0)
        grid = RGBLife.step(grid, generations: 300)
        #expect(live(grid, channel: 1) == Set(block))
        #expect(grid.age(x: 3, y: 3, channel: 1) == 255)
    }

    @Test("Glider moves +1,+1 after 4 generations")
    func gliderMoves() {
        let start = makeGrid(12, 12, alive: glider, mask: 0b100)
        let gen4 = RGBLife.step(start, generations: 4)
        #expect(live(gen4, channel: 2) == translated(glider, dx: 1, dy: 1, width: 12, height: 12))
        let gen8 = RGBLife.step(gen4, generations: 4)
        #expect(live(gen8, channel: 2) == translated(glider, dx: 2, dy: 2, width: 12, height: 12))
    }

    @Test("Births start at age 1 and deaths reset age to 0")
    func birthAndDeathAges() {
        let gen1 = RGBLife.step(makeGrid(8, 8, alive: blinker, mask: 0b001))
        #expect(gen1.age(x: 3, y: 2, channel: 0) == 1)  // born
        #expect(gen1.age(x: 3, y: 3, channel: 0) == 2)  // survived
        #expect(gen1.age(x: 2, y: 3, channel: 0) == 0)  // died
    }

    @Test("Birth and death flags mark exactly the cells that changed, for one generation")
    func birthAndDeathFlags() {
        // Red blinker plus a lone green cell, which dies at generation 1 and stays dead.
        let lone = Cell(7, 7)
        let start = makeGrid(10, 10, [(blinker, 0b001), ([lone], 0b010)])
        let ends: Set<Cell> = [Cell(2, 3), Cell(4, 3)]
        let tips: Set<Cell> = [Cell(3, 2), Cell(3, 4)]

        // Placed cells count as newborn (age 1); nothing has died yet.
        #expect(flagged(start, channel: 0, RGBLife.isNewborn) == Set(blinker))
        #expect(flagged(start, channel: 1, RGBLife.isNewborn) == [lone])
        #expect((0..<3).allSatisfy { flagged(start, channel: $0, RGBLife.diedLastGeneration).isEmpty })

        let gen1 = RGBLife.step(start)
        #expect(flagged(gen1, channel: 0, RGBLife.isNewborn) == tips)
        #expect(flagged(gen1, channel: 0, RGBLife.diedLastGeneration) == ends)
        #expect(flagged(gen1, channel: 1, RGBLife.isNewborn).isEmpty)
        #expect(flagged(gen1, channel: 1, RGBLife.diedLastGeneration) == [lone])
        #expect(flagged(gen1, channel: 2, RGBLife.diedLastGeneration).isEmpty)
        #expect(gen1.state(x: 3, y: 3) == 0b001)  // survivor: no flags
        #expect(gen1.state(x: 2, y: 3) == 1 << RGBLife.deathFlagShift)

        let gen2 = RGBLife.step(gen1)
        #expect(flagged(gen2, channel: 0, RGBLife.isNewborn) == ends)
        #expect(flagged(gen2, channel: 0, RGBLife.diedLastGeneration) == tips)
        // The lone cell's flag lasted one generation.
        #expect(flagged(gen2, channel: 1, RGBLife.diedLastGeneration).isEmpty)
        #expect(gen2.state(x: lone.x, y: lone.y) == 0)

        // Seeding never sets death flags.
        let seeded = RGBLife.seeded(width: 40, height: 30, seed: 3)
        #expect(stride(from: 0, to: seeded.cells.count, by: 4).allSatisfy { seeded.cells[$0] & ~RGBLife.liveMask == 0 })
    }

    @Test("Channels evolve independently; overlaps keep both bits")
    func channelIndependence() {
        // Red blinker, green block, blue glider, all overlapping.
        let combined = makeGrid(16, 16, [(blinker, 0b001), (block, 0b010), (glider, 0b100)])
        #expect(combined.state(x: 2, y: 3) == 0b011)  // red + green = yellow
        #expect(combined.state(x: 2, y: 2) == 0b110)  // green + blue = cyan
        let stepped = RGBLife.step(combined, generations: 6)
        for c in 0..<3 {
            let alone = RGBLife.step(isolate(combined, channel: c), generations: 6)
            #expect(isolate(stepped, channel: c) == alone, "channel \(c)")
        }
    }

    @Test("Channels evolve independently on a random grid")
    func channelIndependenceRandom() {
        let start = RGBLife.seeded(width: 40, height: 30, seed: 7)
        let stepped = RGBLife.step(start, generations: 12)
        for c in 0..<3 {
            #expect(isolate(stepped, channel: c) == RGBLife.step(isolate(start, channel: c), generations: 12))
        }
        let masks = Set(stride(from: 0, to: stepped.cells.count, by: 4).map { stepped.cells[$0] })
        #expect(masks.contains(where: { $0.nonzeroBitCount >= 2 }), "expected some mixed colors")
    }

    @Test("Torus: blinker across the corner and glider wrapping back home")
    func torusWrap() {
        let corner = [Cell(7, 0), Cell(0, 0), Cell(1, 0)]
        let gen1 = RGBLife.step(makeGrid(8, 8, alive: corner, mask: 0b001))
        #expect(live(gen1, channel: 0) == [Cell(0, 7), Cell(0, 0), Cell(0, 1)])
        #expect(live(RGBLife.step(gen1), channel: 0) == Set(corner))

        // An 8x8 torus brings a glider back to its start after 8 * 4 generations.
        let start = makeGrid(8, 8, alive: glider, mask: 0b111)
        let gen16 = RGBLife.step(start, generations: 16)
        #expect(live(gen16, channel: 0) == translated(glider, dx: 4, dy: 4, width: 8, height: 8))
        let gen32 = RGBLife.step(gen16, generations: 16)
        for c in 0..<3 {
            #expect(live(gen32, channel: c) == Set(glider))
        }
    }

    @Test("Seeding is deterministic, ~30% per channel, live ages start at 1")
    func seeding() {
        let a = RGBLife.seeded(width: 200, height: 150, seed: 42)
        #expect(a == RGBLife.seeded(width: 200, height: 150, seed: 42))
        #expect(a.cells != RGBLife.seeded(width: 200, height: 150, seed: 43).cells)
        #expect(a.generation == 0)
        let total = Double(a.width * a.height)
        for c in 0..<3 {
            let density = Double(live(a, channel: c).count) / total
            #expect(density > 0.28 && density < 0.32, "channel \(c) density \(density)")
        }
        for i in stride(from: 0, to: a.cells.count, by: 4) {
            for c in 0..<3 {
                #expect(a.cells[i + 1 + c] == (a.cells[i] >> UInt8(c)) & 1)
            }
        }
    }

    @Test("Empty grid stays empty")
    func emptyStaysEmpty() {
        let empty = Grid(width: 10, height: 7)
        let stepped = RGBLife.step(empty, generations: 3)
        #expect(stepped.cells.allSatisfy { $0 == 0 })
        #expect(stepped.generation == 3)
    }
}

@Suite("CellHash")
struct CellHashTests {
    @Test func lowbias32Basics() {
        #expect(CellHash.lowbias32(0) == 0)
        #expect(CellHash.lowbias32(1) != 1)
        #expect(CellHash.lowbias32(1) != CellHash.lowbias32(2))
    }

    @Test("Every input changes the hash")
    func inputsMatter() {
        let base = CellHash.hash(x: 3, y: 5, generation: 7, seed: 11)
        #expect(base == CellHash.hash(x: 3, y: 5, generation: 7, seed: 11))
        #expect(base != CellHash.hash(x: 4, y: 5, generation: 7, seed: 11))
        #expect(base != CellHash.hash(x: 3, y: 6, generation: 7, seed: 11))
        #expect(base != CellHash.hash(x: 3, y: 5, generation: 8, seed: 11))
        #expect(base != CellHash.hash(x: 3, y: 5, generation: 7, seed: 12))
        #expect(CellHash.hash(x: 3, y: 5, generation: 0, seed: 0) != CellHash.hash(x: 5, y: 3, generation: 0, seed: 0))
    }
}
