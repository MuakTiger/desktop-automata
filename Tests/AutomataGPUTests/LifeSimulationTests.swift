import AutomataCore
import Metal
import Testing
@testable import AutomataGPU

/// Grid with each layer's cells alive in the channels of its mask (ORed together).
private func pattern(_ width: Int, _ height: Int, _ layers: [(cells: [(Int, Int)], mask: UInt8)]) -> Grid {
    var grid = Grid(width: width, height: height)
    for layer in layers {
        for (x, y) in layer.cells {
            RGBLife.setMask(grid.state(x: x, y: y) | layer.mask, x: x, y: y, in: &grid)
        }
    }
    return grid
}

@Suite("Half-float readback conversion")
struct HalfFloatTests {
    @Test func knownValues() {
        #expect(LifeSimulation.float(fromHalf: 0x0000) == 0)
        #expect(LifeSimulation.float(fromHalf: 0x3C00) == 1)
        #expect(LifeSimulation.float(fromHalf: 0xC000) == -2)
        #expect(LifeSimulation.float(fromHalf: 0x3800) == 0.5)
        #expect(LifeSimulation.float(fromHalf: 0x4200) == 3)
        #expect(LifeSimulation.float(fromHalf: 0x3BFF) == 1 - 0x1p-11)
        #expect(LifeSimulation.float(fromHalf: 0x0001) == 0x1p-24)
        #expect(LifeSimulation.float(fromHalf: 0x7C00) == .infinity)
        #expect(LifeSimulation.float(fromHalf: 0x7E00).isNaN)
    }
}

@Suite("LifeSimulation GPU parity", .enabled(if: MTLCreateSystemDefaultDevice() != nil, "No Metal device"))
struct LifeSimulationTests {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        library = try ShaderSource.makeLibrary(device: device)
    }

    private func commit(_ encode: (MTLCommandBuffer) -> Void) throws {
        let commandBuffer = try #require(queue.makeCommandBuffer())
        encode(commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
    }

    /// Nil when `gpu` equals `cpu.cells` byte-for-byte; otherwise the first difference.
    private func firstMismatch(_ gpu: [UInt8], _ cpu: Grid) -> String? {
        guard gpu.count == cpu.cells.count else { return "size gpu \(gpu.count) cpu \(cpu.cells.count)" }
        guard let i = zip(gpu, cpu.cells).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset
        else { return nil }
        let cell = i / Grid.bytesPerCell
        return "cell (\(cell % cpu.width),\(cell / cpu.width)) byte \(i % 4): gpu \(gpu[i]) cpu \(cpu.cells[i])"
    }

    @Test("Random grid matches the CPU reference exactly for 20 generations",
          arguments: [(64, 48, UInt32(0x5EED)), (37, 23, UInt32(1))])
    func parity(width: Int, height: Int, seed: UInt32) throws {
        let simulation = try LifeSimulation(device: device, library: library, width: width, height: height)
        var cpu = RGBLife.seeded(width: width, height: height, seed: seed)

        try commit { simulation.encodeSeed(seed, into: $0) }
        let seeded = try simulation.readback(using: queue)
        #expect(firstMismatch(seeded, cpu) == nil, "after seeding")

        // Several steps per command buffer, like the render loop under load.
        for batch in [1, 4, 4, 3, 8] {
            try commit { commandBuffer in
                for _ in 0..<batch { simulation.encodeStep(into: commandBuffer) }
            }
            cpu = RGBLife.step(cpu, generations: batch)
            let gpu = try simulation.readback(using: queue)
            #expect(firstMismatch(gpu, cpu) == nil, "generation \(cpu.generation)")
        }
        #expect(simulation.generation == 20 && cpu.generation == 20)
        #expect(cpu.cells.contains { $0 != 0 }, "grid died out; parity check would be trivial")
    }

    @Test("Ages count up, saturate at 255 and reset on death like the CPU; birth/death flags match")
    func ageAndFlagParity() throws {
        // Red block (still life: its ages saturate), green blinker (births and deaths
        // every generation), blue glider (moves and wraps around the torus).
        let cpuStart = pattern(24, 24, [
            ([(2, 2), (3, 2), (2, 3), (3, 3)], 0b001),
            ([(10, 5), (11, 5), (12, 5)], 0b010),
            ([(16, 15), (17, 16), (15, 17), (16, 17), (17, 17)], 0b100),
        ])
        var cpu = cpuStart
        let simulation = try LifeSimulation(device: device, library: library, width: 24, height: 24)
        try simulation.upload(cpuStart, using: queue)
        #expect(firstMismatch(try simulation.readback(using: queue), cpu) == nil, "after upload")

        for batch in [1, 1, 2, 4, 50, 200, 42] {
            try commit { commandBuffer in
                for _ in 0..<batch { simulation.encodeStep(into: commandBuffer) }
            }
            cpu = RGBLife.step(cpu, generations: batch)
            #expect(firstMismatch(try simulation.readback(using: queue), cpu) == nil, "generation \(cpu.generation)")
        }
        #expect(cpu.generation == 300)
        // The run really reached the saturating, resetting and flagging branches.
        #expect(cpu.age(x: 2, y: 2, channel: 0) == 255)
        // Even generation: the blinker is horizontal again, its ends just reborn
        // and its vertical tips just died (age reset to 0); the pivot never died.
        #expect(RGBLife.isNewborn(cpu, x: 10, y: 5, channel: 1))
        #expect(RGBLife.diedLastGeneration(cpu, x: 11, y: 4, channel: 1))
        #expect(cpu.age(x: 11, y: 4, channel: 1) == 0)
        #expect(cpu.age(x: 11, y: 5, channel: 1) == 255)
    }

    @Test("Colorize matches LifeColoring (palette, age, drift, flash, afterimage)", arguments: Palette.allCases)
    func colorizeParity(palette: Palette) throws {
        let (width, height, seed) = (37, 23, UInt32(77))
        let simulation = try LifeSimulation(device: device, library: library, width: width, height: height)
        try commit { commandBuffer in
            simulation.encodeSeed(seed, into: commandBuffer)
            for _ in 0..<6 { simulation.encodeStep(into: commandBuffer) }
        }
        let cpu = RGBLife.step(RGBLife.seeded(width: width, height: height, seed: seed), generations: 6)
        #expect(firstMismatch(try simulation.readback(using: queue), cpu) == nil)

        // The grid exercises every coloring branch.
        let cells = (0..<height).flatMap { y in (0..<width).flatMap { x in (0..<3).map { (x, y, $0) } } }
        #expect(cells.contains { RGBLife.isNewborn(cpu, x: $0.0, y: $0.1, channel: $0.2) })
        #expect(cells.contains { RGBLife.diedLastGeneration(cpu, x: $0.0, y: $0.1, channel: $0.2) })
        #expect(cells.contains { cpu.age(x: $0.0, y: $0.1, channel: $0.2) > 3 })

        let drift: Float = 1.37
        for afterimage in [LifeColoring.afterimage, 0] {
            try commit {
                simulation.encodeColorize(palette: palette.cosine, drift: drift, afterimage: afterimage, into: $0)
            }
            let gpu = try simulation.readbackColor(using: queue)
            var worst: (error: Float, x: Int, y: Int) = (0, 0, 0)
            for y in 0..<height {
                for x in 0..<width {
                    let expected = LifeColoring.color(
                        of: cpu, x: x, y: y, palette: palette.cosine, drift: drift, afterimage: afterimage
                    )
                    let got = gpu[y * width + x]
                    let error = max(abs(got.x - expected.x), abs(got.y - expected.y), abs(got.z - expected.z), abs(got.w - 1))
                    if error > worst.error { worst = (error, x, y) }
                }
            }
            // rgba16Float keeps ~3 significant digits; values reach ~3 where channels overlap.
            #expect(worst.error < 0.01, "\(palette) afterimage \(afterimage): cell (\(worst.x),\(worst.y)) off by \(worst.error)")
        }
    }

    @Test("Stamps (trail in all six hues + bursts, one clipped at the edge) match RGBLife.stamp, then steps")
    func stampParity() throws {
        let (width, height, seed) = (64, 48, UInt32(0x5EED))
        let simulation = try LifeSimulation(device: device, library: library, width: width, height: height)
        var cpu = RGBLife.seeded(width: width, height: height, seed: seed)
        try commit { simulation.encodeSeed(seed, into: $0) }

        // A diagonal trail over 2.4 s (every hue step) plus a click in the middle.
        var brush = BrushStroke()
        var trail: [Stamp] = []
        for i in 0...24 {
            let p = SIMD2(4.5 + 2.2 * Double(i), 4.5 + 1.5 * Double(i))
            trail += brush.update(position: p, clicked: i == 12, time: Double(i) * 0.1)
        }
        #expect(Set(trail.map(\.value)) == Set(0..<6))
        #expect(trail.contains { $0.kind == .burst })
        let edgeBurst = Stamp(x: 62, y: 1, radius: BrushStroke.burstRadius, kind: .burst, value: 4, seed: 99)

        try commit { simulation.encodeStamps(trail, into: $0) }
        RGBLife.stamp(trail, into: &cpu)
        #expect(firstMismatch(try simulation.readback(using: queue), cpu) == nil, "after trail")
        #expect(simulation.generation == 0)
        // Stamped channels count as births (age 1), so they get the birth flash.
        var painted = 0
        for y in 0..<height {
            for x in 0..<width {
                let paint = trail.reduce(UInt8(0)) { $0 | RGBLife.paint($1, x: x, y: y) }
                for c in 0..<3 where (paint >> UInt8(c)) & 1 == 1 {
                    painted += 1
                    #expect(RGBLife.isNewborn(cpu, x: x, y: y, channel: c))
                }
            }
        }
        #expect(painted > 100)

        try commit { commandBuffer in
            simulation.encodeStep(into: commandBuffer)
            simulation.encodeStamps([edgeBurst], into: commandBuffer)
            for _ in 0..<3 { simulation.encodeStep(into: commandBuffer) }
        }
        cpu = RGBLife.step(cpu)
        RGBLife.stamp([edgeBurst], into: &cpu)
        // The burst's solid rim is blue (hue 4); the disk is clipped at the edges.
        #expect(RGBLife.isNewborn(cpu, x: 62, y: 1 + 16, channel: 2))
        cpu = RGBLife.step(cpu, generations: 3)
        #expect(firstMismatch(try simulation.readback(using: queue), cpu) == nil, "after burst + 4 steps")
        #expect(simulation.generation == 4)
    }

    @Test("Clear empties the grid and stepping keeps it empty")
    func clear() throws {
        let simulation = try LifeSimulation(device: device, library: library, width: 64, height: 48)
        try commit { commandBuffer in
            simulation.encodeSeed(9, into: commandBuffer)
            simulation.encodeStep(into: commandBuffer)
            simulation.encodeClear(into: commandBuffer)
        }
        #expect(simulation.generation == 0)
        #expect(try simulation.readback(using: queue).allSatisfy { $0 == 0 })
        try commit { simulation.encodeStep(into: $0) }
        #expect(try simulation.readback(using: queue).allSatisfy { $0 == 0 })
    }
}
