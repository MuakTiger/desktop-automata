import AppKit
import AutomataCore
import Metal
import MetalKit
import Testing
@testable import AutomataGPU

@Suite("Population + cell size", .enabled(if: MTLCreateSystemDefaultDevice() != nil, "No Metal device"))
struct PopulationTests {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        library = try ShaderSource.makeLibrary(device: device)
    }

    @Test("GPU population equals the CPU count on 64x48 for every rule", arguments: AutomatonRule.allCases)
    func gpuMatchesCPU(rule: AutomatonRule) throws {
        let (width, height, seed) = (64, 48, UInt32(0xC0FFEE))
        let simulation = try LifeSimulation(device: device, library: library, width: width, height: height, rule: rule)
        var cpu = Automaton.seeded(rule, width: width, height: height, seed: seed)
        let commandBuffer = try #require(queue.makeCommandBuffer())
        simulation.encodeSeed(seed, into: commandBuffer)
        commandBuffer.commit()
        #expect(try simulation.population(using: queue) == Automaton.population(rule, cpu), "\(rule) seeded")
        for batch in [1, 2, 5, 9] {
            let commandBuffer = try #require(queue.makeCommandBuffer())
            for _ in 0..<batch { simulation.encodeStep(into: commandBuffer) }
            commandBuffer.commit()
            cpu = Automaton.step(rule, cpu, generations: batch)
            let count = Automaton.population(rule, cpu)
            #expect(try simulation.population(using: queue) == count, "\(rule) generation \(cpu.generation)")
            #expect(count > 0 && count < width * height, "\(rule) count \(count) is non-trivial")
        }
    }

    @Test("Renderer hands the population back via the completed handler without blocking")
    @MainActor
    func rendererReadback() async throws {
        let renderer = try Renderer(device: device, generationsPerSecond: 10, cellPoints: 6, rule: .briansBrain)
        renderer.rebuild(for: CGSize(width: 384, height: 288))
        let simulation = try #require(renderer.simulation)
        #expect(simulation.width == 64 && simulation.height == 48)
        renderer.reset(seed: 7)
        #expect(renderer.population == nil)
        let commandBuffer = try #require(renderer.commandQueue.makeCommandBuffer())
        renderer.encodePopulationIfDue(simulation, into: commandBuffer)
        commandBuffer.commit()
        // The handler hops to the main queue; suspending frees the main actor to run it.
        let deadline = Date().addingTimeInterval(5)
        while renderer.population == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let population = try #require(renderer.population)
        let cpu = Automaton.seeded(.briansBrain, width: 64, height: 48, seed: 7)
        #expect(population.count == Automaton.population(.briansBrain, cpu))
        #expect(population.generation == 0)
        // A rebuild drops the old count.
        renderer.rebuild(for: CGSize(width: 384, height: 288))
        #expect(renderer.population == nil)
    }

    @Test("Changing the cell size rebuilds and reseeds the grid; screen rebuild always reallocates")
    @MainActor
    func cellSizeRebuild() throws {
        let renderer = try Renderer(device: device, generationsPerSecond: 10, cellPoints: 6)
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 601, height: 481), device: device)
        renderer.attach(to: view)
        let first = try #require(renderer.simulation)
        #expect(first.width == 101 && first.height == 81)
        renderer.stepOnce()
        #expect(first.generation == 1)

        for size in CellSize.allCases.reversed() {
            renderer.cellPoints = size.points
            let simulation = try #require(renderer.simulation)
            let expected = Renderer.gridSize(for: CGSize(width: 601, height: 481), cellPoints: size.points)
            #expect(simulation.width == expected.width && simulation.height == expected.height, "\(size)")
            #expect(simulation.generation == 0)
            #expect(try simulation.readback(using: renderer.commandQueue).contains { $0 != 0 }, "\(size) reseeded")
        }
        #expect(renderer.simulation?.width == 201)  // 3 pt last

        // Same cell size: nothing happens.
        let kept = try #require(renderer.simulation)
        renderer.cellPoints = 3
        #expect(renderer.simulation === kept)

        // Screen change to the same size still rebuilds (new textures, reseeded); empty size is ignored.
        renderer.rebuild(for: CGSize(width: 601, height: 481))
        let rebuilt = try #require(renderer.simulation)
        #expect(rebuilt !== kept)
        renderer.rebuild(for: .zero)
        #expect(renderer.simulation === rebuilt)
        renderer.rebuild(for: CGSize(width: 1511, height: 983))
        #expect(renderer.simulation?.width == 504 && renderer.simulation?.height == 328)
    }
}
