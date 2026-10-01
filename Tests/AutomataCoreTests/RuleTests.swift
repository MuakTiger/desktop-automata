import Testing
@testable import AutomataCore

private func cells(_ grid: Grid) -> [UInt8] {
    stride(from: 0, to: grid.cells.count, by: Grid.bytesPerCell).map { grid.cells[$0] }
}

@Suite("Brian's Brain")
struct BriansBrainTests {
    @Test("firing -> refractory -> off, with ages")
    func transitions() {
        var grid = Grid(width: 8, height: 8)
        BriansBrain.set(BriansBrain.firing, x: 4, y: 4, in: &grid)
        let g1 = BriansBrain.step(grid)
        #expect(g1.state(x: 4, y: 4) == BriansBrain.refractory && g1.age(x: 4, y: 4, channel: 0) == 1)
        let g2 = BriansBrain.step(g1)
        #expect(g2.state(x: 4, y: 4) == BriansBrain.off && g2.age(x: 4, y: 4, channel: 0) == 1)
        let g3 = BriansBrain.step(g2)
        #expect(g3.age(x: 4, y: 4, channel: 0) == 2, "off cells count generations since going off")
        // A lone firing cell never ignites neighbors (each sees 1 firing neighbor).
        #expect(cells(g1).filter { $0 == BriansBrain.firing }.isEmpty)
        #expect(g3.generation == 3)
    }

    @Test("off cells are born with exactly 2 firing neighbors only", arguments: 0...8)
    func birth(firingNeighbors: Int) {
        let offsets = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]
        var grid = Grid(width: 9, height: 9)
        for (dx, dy) in offsets.prefix(firingNeighbors) {
            BriansBrain.set(BriansBrain.firing, x: 4 + dx, y: 4 + dy, in: &grid)
        }
        let next = BriansBrain.step(grid)
        #expect((next.state(x: 4, y: 4) == BriansBrain.firing) == (firingNeighbors == 2))
        // Refractory neighbors do not count.
        var refractory = Grid(width: 9, height: 9)
        for (dx, dy) in offsets.prefix(firingNeighbors) {
            BriansBrain.set(BriansBrain.refractory, x: 4 + dx, y: 4 + dy, in: &refractory)
        }
        #expect(BriansBrain.step(refractory).state(x: 4, y: 4) == BriansBrain.off)
    }

    @Test("Seeds ~30% firing, deterministically")
    func seeding() {
        let grid = BriansBrain.seeded(width: 100, height: 100, seed: 3)
        let density = Double(BriansBrain.population(grid)) / 10_000
        #expect(density > 0.27 && density < 0.33)
        #expect(grid == BriansBrain.seeded(width: 100, height: 100, seed: 3))
        #expect(cells(grid).allSatisfy { $0 == BriansBrain.off || $0 == BriansBrain.firing })
    }
}

@Suite("Cyclic CA")
struct CyclicCATests {
    /// 5x5 grid of `state` with `count` successor neighbors around (2, 2).
    private func grid(state: UInt8, successor: UInt8, count: Int) -> Grid {
        var grid = Grid(width: 5, height: 5)
        for y in 0..<5 { for x in 0..<5 { CyclicCA.set(state, x: x, y: y, in: &grid) } }
        let offsets = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]
        for (dx, dy) in offsets.prefix(count) { CyclicCA.set(successor, x: 2 + dx, y: 2 + dy, in: &grid) }
        return grid
    }

    @Test("Advances at the threshold, not below it", arguments: [UInt32(1), 2, 3])
    func threshold(threshold: UInt32) {
        for count in 0...8 {
            let next = CyclicCA.step(grid(state: 5, successor: 6, count: count), threshold: threshold)
            let advanced = next.state(x: 2, y: 2) == 6
            #expect(advanced == (UInt32(count) >= threshold), "count \(count)")
            #expect(next.age(x: 2, y: 2, channel: 0) == (advanced ? 1 : 2))
        }
        // Neighbors in other states (here s + 2) never count.
        #expect(CyclicCA.step(grid(state: 5, successor: 7, count: 8), threshold: threshold).state(x: 2, y: 2) == 5)
    }

    @Test("Wraps N-1 -> 0")
    func wrap() {
        let n = UInt8(CyclicCA.states)
        let next = CyclicCA.step(grid(state: n - 1, successor: 0, count: Int(CyclicCA.threshold)))
        #expect(next.state(x: 2, y: 2) == 0)
        // State 0 is not the successor of N-2.
        #expect(CyclicCA.step(grid(state: n - 2, successor: 0, count: 8)).state(x: 2, y: 2) == n - 2)
    }

    @Test("Parameters in range; seeding uses every state; burst rings count down outward")
    func parametersAndSeeding() {
        #expect((12...16).contains(CyclicCA.states) && (1...3).contains(CyclicCA.threshold))
        let grid = CyclicCA.seeded(width: 64, height: 48, seed: 1)
        #expect(Set(cells(grid)) == Set(0..<UInt8(CyclicCA.states)))
        let burst = Stamp(x: 20, y: 20, radius: 16, kind: .burst, value: 3, seed: 1)
        let base = UInt8(3 * CyclicCA.states / 6)
        #expect(CyclicCA.paint(burst, x: 20, y: 20) == base)
        #expect(CyclicCA.paint(burst, x: 23, y: 20) == (base + UInt8(CyclicCA.states) - 3) % UInt8(CyclicCA.states))
        #expect(CyclicCA.paint(burst, x: 40, y: 40) == nil)
        #expect(CyclicCA.isqrt(15) == 3 && CyclicCA.isqrt(16) == 4 && CyclicCA.isqrt(0) == 0)
    }
}

@Suite("Rock-Paper-Scissors")
struct RockPaperScissorsTests {
    @Test("R eats G, G eats B, B eats R")
    func predators() {
        #expect(RockPaperScissors.predator(of: 1) == 0)
        #expect(RockPaperScissors.predator(of: 2) == 1)
        #expect(RockPaperScissors.predator(of: 0) == 2)
    }

    @Test("Converts iff more predators than the hashed threshold; prey never converts")
    func predation() {
        let offsets = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]
        var sawThresholds = Set<UInt32>()
        for generation in UInt32(0)..<40 {
            let threshold = RockPaperScissors.threshold(x: 2, y: 2, generation: generation)
            sawThresholds.insert(threshold)
            for count in 0...8 {
                var grid = Grid(width: 5, height: 5)
                for y in 0..<5 { for x in 0..<5 { RockPaperScissors.set(1, x: x, y: y, in: &grid) } }  // all G
                for (dx, dy) in offsets.prefix(count) { RockPaperScissors.set(0, x: 2 + dx, y: 2 + dy, in: &grid) }  // R
                grid.generation = generation
                let next = RockPaperScissors.step(grid)
                #expect((next.state(x: 2, y: 2) == 0) == (UInt32(count) > threshold))
                // G is B's predator, not R's: an R cell surrounded by G stays R.
                if count == 8 { #expect(next.state(x: 2, y: 2) == 0) }
            }
        }
        #expect(sawThresholds == [2, 3, 4])
        var rInG = Grid(width: 5, height: 5)
        for y in 0..<5 { for x in 0..<5 { RockPaperScissors.set(1, x: x, y: y, in: &rInG) } }
        RockPaperScissors.set(0, x: 2, y: 2, in: &rInG)
        #expect(RockPaperScissors.step(rInG).state(x: 2, y: 2) == 0)
    }

    @Test("Fixed seed: deterministic, all species survive, fronts move")
    func deterministic() {
        let start = RockPaperScissors.seeded(width: 48, height: 32, seed: 42)
        let a = RockPaperScissors.step(start, generations: 30)
        let b = RockPaperScissors.step(start, generations: 30)
        #expect(a == b)
        #expect(Set(cells(a)) == [0, 1, 2])
        #expect(RockPaperScissors.population(a) > 0)
        #expect(a != start)
    }
}

extension RockPaperScissors {
    static func step(_ grid: Grid, generations: Int) -> Grid {
        Automaton.step(.rockPaperScissors, grid, generations: generations)
    }
}

@Suite("Automaton dispatch")
struct AutomatonTests {
    @Test("Rule indices match the MSL kRule constants")
    func indices() {
        #expect(AutomatonRule.allCases.map(\.index) == [0, 1, 2, 3])
    }

    @Test("Non-Life stamps set the painted state at age 1; later stamps win")
    func stamps() {
        let first = Stamp(x: 10, y: 10, radius: 4, kind: .burst, value: 0, seed: 1)  // R
        let second = Stamp(x: 12, y: 10, radius: 4, kind: .burst, value: 4, seed: 2)  // B
        var grid = RockPaperScissors.seeded(width: 24, height: 20, seed: 5)
        Automaton.stamp(.rockPaperScissors, [first, second], into: &grid)
        #expect(grid.state(x: 7, y: 10) == 0 && grid.state(x: 12, y: 10) == 2)
        #expect(grid.age(x: 12, y: 10, channel: 0) == 1)

        var brain = Grid(width: 24, height: 20)
        Automaton.stamp(.briansBrain, [first], into: &brain)
        #expect(brain.state(x: 10, y: 6) == BriansBrain.firing, "solid rim")
        #expect(cells(brain).allSatisfy { $0 == BriansBrain.off || $0 == BriansBrain.firing })
        #expect(BriansBrain.population(brain) > 20)
    }

    @Test("Population: live / firing / changed this generation")
    func population() {
        var life = Grid(width: 4, height: 4)
        RGBLife.setMask(0b101, x: 1, y: 1, in: &life)
        RGBLife.setMask(0b010, x: 2, y: 1, in: &life)
        #expect(Automaton.population(.rgbLife, life) == 2)
        let cyclic = CyclicCA.seeded(width: 10, height: 10, seed: 1)
        #expect(Automaton.population(.cyclic, cyclic) == 100, "seeded cells are newborn")
    }

    @Test("Rule colors stay finite and vivid; BB trail fades; RPS species differ")
    func colors() {
        let palette = Palette.neon.cosine
        var brain = Grid(width: 3, height: 1)
        BriansBrain.set(BriansBrain.firing, x: 0, y: 0, in: &brain)
        BriansBrain.set(BriansBrain.refractory, x: 1, y: 0, in: &brain)
        let fire = RuleColoring.color(.briansBrain, of: brain, x: 0, y: 0, palette: palette, drift: 0, afterimage: 0.3)
        let refr = RuleColoring.color(.briansBrain, of: brain, x: 1, y: 0, palette: palette, drift: 0, afterimage: 0.3)
        #expect(fire.sum() > refr.sum() && refr.sum() > 0)
        #expect(RuleColoring.color(.briansBrain, of: brain, x: 2, y: 0, palette: palette, drift: 0, afterimage: 0.3) == .zero)
        var trail = brain
        trail.cells[trail.index(x: 2, y: 0) + 1] = 1
        let young = RuleColoring.color(.briansBrain, of: trail, x: 2, y: 0, palette: palette, drift: 0, afterimage: 0.3)
        trail.cells[trail.index(x: 2, y: 0) + 1] = 6
        let old = RuleColoring.color(.briansBrain, of: trail, x: 2, y: 0, palette: palette, drift: 0, afterimage: 0.3)
        #expect(young.sum() > old.sum() && old.sum() > 0)
        #expect(RuleColoring.color(.briansBrain, of: trail, x: 2, y: 0, palette: palette, drift: 0, afterimage: 0) == .zero)

        var rps = Grid(width: 3, height: 1)
        for s in 0..<3 { RockPaperScissors.set(UInt8(s), x: s, y: 0, in: &rps) }
        for p in Palette.allCases {
            let colors = (0..<3).map { RuleColoring.color(.rockPaperScissors, of: rps, x: $0, y: 0, palette: p.cosine, drift: 0, afterimage: 0) }
            // Each species is dominated by its own primary.
            for s in 0..<3 { #expect(colors[s].max() == colors[s][s], "\(p) species \(s)") }
        }
        #expect(RuleColoring.ageBrightness(1) == 1 && RuleColoring.ageBrightness(255) > 0.3)
    }
}
