import AutomataCore
import Metal
import Testing
@testable import AutomataGPU

private let newRules: [AutomatonRule] = [.briansBrain, .cyclic, .rockPaperScissors]

@Suite("Rule GPU parity", .enabled(if: MTLCreateSystemDefaultDevice() != nil, "No Metal device"))
struct RuleSimulationTests {
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

    private func firstMismatch(_ gpu: [UInt8], _ cpu: Grid) -> String? {
        guard gpu.count == cpu.cells.count else { return "size gpu \(gpu.count) cpu \(cpu.cells.count)" }
        guard let i = zip(gpu, cpu.cells).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset
        else { return nil }
        let cell = i / Grid.bytesPerCell
        return "cell (\(cell % cpu.width),\(cell / cpu.width)) byte \(i % 4): gpu \(gpu[i]) cpu \(cpu.cells[i])"
    }

    @Test("64x48 random grid matches the CPU reference for 20 generations, with population", arguments: newRules)
    func parity(rule: AutomatonRule) throws {
        let (width, height, seed) = (64, 48, UInt32(0x5EED))
        let simulation = try LifeSimulation(device: device, library: library, width: width, height: height, rule: rule)
        var cpu = Automaton.seeded(rule, width: width, height: height, seed: seed)
        try commit { simulation.encodeSeed(seed, into: $0) }
        #expect(firstMismatch(try simulation.readback(using: queue), cpu) == nil, "\(rule) after seeding")

        var states = Set<UInt8>()
        for batch in [1, 4, 4, 3, 8] {
            try commit { commandBuffer in
                for _ in 0..<batch { simulation.encodeStep(into: commandBuffer) }
            }
            cpu = Automaton.step(rule, cpu, generations: batch)
            #expect(firstMismatch(try simulation.readback(using: queue), cpu) == nil, "\(rule) generation \(cpu.generation)")
            #expect(try simulation.population(using: queue) == Automaton.population(rule, cpu), "\(rule) population")
            states.formUnion(stride(from: 0, to: cpu.cells.count, by: 4).map { cpu.cells[$0] })
        }
        #expect(simulation.generation == 20)
        // Non-trivial: the rule kept several states alive and something changed this generation.
        #expect(states.count >= 3, "\(rule)")
        #expect(Automaton.population(rule, cpu) > 0, "\(rule)")
    }

    @Test("Stamps (trail over all hues + bursts) match Automaton.stamp, then steps", arguments: newRules)
    func stampParity(rule: AutomatonRule) throws {
        let (width, height, seed) = (64, 48, UInt32(9))
        let simulation = try LifeSimulation(device: device, library: library, width: width, height: height, rule: rule)
        var cpu = Automaton.seeded(rule, width: width, height: height, seed: seed)
        try commit { simulation.encodeSeed(seed, into: $0) }

        var brush = BrushStroke()
        var stamps: [Stamp] = []
        for i in 0...24 {
            let p = SIMD2(4.5 + 2.2 * Double(i), 4.5 + 1.5 * Double(i))
            stamps += brush.update(position: p, clicked: i == 12, time: Double(i) * 0.1)
        }
        stamps.append(Stamp(x: 62, y: 1, radius: BrushStroke.burstRadius, kind: .burst, value: 4, seed: 99))
        try commit { commandBuffer in
            simulation.encodeStamps(stamps, into: commandBuffer)
            for _ in 0..<3 { simulation.encodeStep(into: commandBuffer) }
        }
        Automaton.stamp(rule, stamps, into: &cpu)
        cpu = Automaton.step(rule, cpu, generations: 3)
        #expect(firstMismatch(try simulation.readback(using: queue), cpu) == nil, "\(rule)")
    }

    @Test("Colorize matches RuleColoring", arguments: newRules)
    func colorizeParity(rule: AutomatonRule) throws {
        let (width, height, seed) = (37, 23, UInt32(77))
        let simulation = try LifeSimulation(device: device, library: library, width: width, height: height, rule: rule)
        try commit { commandBuffer in
            simulation.encodeSeed(seed, into: commandBuffer)
            for _ in 0..<12 { simulation.encodeStep(into: commandBuffer) }
        }
        let cpu = Automaton.step(rule, Automaton.seeded(rule, width: width, height: height, seed: seed), generations: 12)
        for palette in Palette.allCases {
            try commit {
                simulation.encodeColorize(palette: palette.cosine, drift: 1.37, afterimage: LifeColoring.afterimage, into: $0)
            }
            let gpu = try simulation.readbackColor(using: queue)
            var worst: Float = 0
            for y in 0..<height {
                for x in 0..<width {
                    let expected = RuleColoring.color(
                        rule, of: cpu, x: x, y: y, palette: palette.cosine, drift: 1.37, afterimage: LifeColoring.afterimage
                    )
                    let got = gpu[y * width + x]
                    worst = max(worst, abs(got.x - expected.x), abs(got.y - expected.y), abs(got.z - expected.z), abs(got.w - 1))
                }
            }
            #expect(worst < 0.01, "\(rule) \(palette): off by \(worst)")
        }
    }

    @Test("Renderer rule switch reseeds the new rule at generation 0")
    func rendererRuleSwitch() throws {
        let renderer = try Renderer(device: device, generationsPerSecond: 10, cellPoints: 6)
        renderer.resizeIfNeeded(for: CGSize(width: 384, height: 288))
        let simulation = try #require(renderer.simulation)
        renderer.stepOnce()
        #expect(simulation.generation == 1)
        renderer.rule = .cyclic
        #expect(simulation.rule == .cyclic && simulation.generation == 0)
        let bytes = try simulation.readback(using: renderer.commandQueue)
        let states = Set(stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] })
        #expect(states.count == Int(CyclicCA.states), "seeded with every cyclic state")
        let other = try Renderer(device: device, generationsPerSecond: 10, cellPoints: 6, rule: .briansBrain)
        other.resizeIfNeeded(for: CGSize(width: 384, height: 288))
        #expect(other.simulation?.rule == .briansBrain)
    }
}
