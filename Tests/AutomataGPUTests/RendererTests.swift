import AppKit
import AutomataCore
import Metal
import MetalKit
import Testing
@testable import AutomataGPU

private let hasMetal = MTLCreateSystemDefaultDevice() != nil

/// BGRA pixel reader for images made by `Renderer.renderOffscreen`.
private struct Pixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]
    private let bytesPerRow: Int

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        bytesPerRow = image.bytesPerRow
        let data = try #require(image.dataProvider?.data) as Data
        bytes = [UInt8](data)
    }

    /// (r, g, b) at pixel (`x`, `y`), y down.
    func rgb(_ x: Int, _ y: Int) -> SIMD3<Int> {
        let i = y * bytesPerRow + x * 4
        return SIMD3(Int(bytes[i + 2]), Int(bytes[i + 1]), Int(bytes[i]))
    }
}

@Suite("Renderer")
struct RendererTests {
    @Test("Compiles shaders and builds pipelines on the system device",
          .enabled(if: hasMetal, "No Metal device"))
    func initWithDevice() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try Renderer(device: device, generationsPerSecond: 10, cellPoints: 6)
        #expect(renderer.generationsPerSecond == 10)
        #expect(renderer.simulation == nil)
    }

    @Test("Grid size is ceil(view points / cell), at least 1x1")
    func gridSize() {
        #expect(Renderer.gridSize(for: CGSize(width: 2560, height: 1440), cellPoints: 6) == (427, 240))
        #expect(Renderer.gridSize(for: CGSize(width: 600, height: 480), cellPoints: 6) == (100, 80))
        #expect(Renderer.gridSize(for: CGSize(width: 2, height: 2), cellPoints: 6) == (1, 1))
    }

    @Test("Gridlines only in Pixel style with cells of at least 6 pt; afterimage only in Pixel style")
    func styleRules() {
        #expect(CellSize.allCases.map { Renderer.gridLineWidth(style: .pixel, cellPoints: $0.points) } == [0, 0, 1, 1, 1])
        #expect(CellSize.allCases.allSatisfy { Renderer.gridLineWidth(style: .glow, cellPoints: $0.points) == 0 })
        #expect(Renderer.afterimage(style: .pixel) == LifeColoring.afterimage)
        #expect(Renderer.afterimage(style: .glow) == 0)
    }

    @Test("Defaults to Neon in Pixel style; palette and style are kept",
          .enabled(if: hasMetal, "No Metal device"))
    func paletteAndStyle() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try Renderer(device: device, generationsPerSecond: 10, cellPoints: 6)
        #expect(renderer.palette == .neon && renderer.style == .pixel)
        renderer.palette = .acid
        #expect(renderer.palette == .acid)
        let other = try Renderer(device: device, generationsPerSecond: 10, cellPoints: 6, palette: .fireAndIce, style: .glow)
        #expect(other.palette == .fireAndIce && other.style == .glow)
    }

    @Test("Offscreen frame: colorful cells, gridlines on every cell edge at 6 pt, none at 4 pt",
          .enabled(if: hasMetal, "No Metal device"))
    func offscreenFrame() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // 120x96 pt at 2x: 12 px cells at 6 pt, 8 px cells at 4 pt.
        for (points, expectLines) in [(6, true), (4, false)] {
            let renderer = try Renderer(device: device, generationsPerSecond: 10, cellPoints: points)
            let image = try renderer.renderOffscreen(
                viewSize: CGSize(width: 120, height: 96), scale: 2, generations: 3, seed: 5
            )
            let pixels = try Pixels(image)
            #expect(pixels.width == 240 && pixels.height == 192)
            let simulation = try #require(renderer.simulation)
            #expect(simulation.width == 120 / points && simulation.height == 96 / points)
            #expect(simulation.generation == 3)

            let cellPixels = 2 * points
            var interiors: [SIMD3<Int>] = []
            var cellsWithLine = 0
            for cy in 0..<simulation.height {
                for cx in 0..<simulation.width {
                    let (x0, y0) = (cx * cellPixels, cy * cellPixels)
                    let interior = pixels.rgb(x0 + cellPixels / 2, y0 + cellPixels / 2)
                    interiors.append(interior)
                    if pixels.rgb(x0, y0 + cellPixels / 2) != interior
                        && pixels.rgb(x0 + cellPixels / 2, y0) != interior { cellsWithLine += 1 }
                }
            }
            let cellCount = simulation.width * simulation.height
            #expect(cellsWithLine == (expectLines ? cellCount : 0), "\(points) pt")
            // Colorful, not just black and white: many distinct colors, some strongly saturated.
            #expect(Set(interiors).count >= 10, "\(points) pt")
            #expect(interiors.contains { $0.max() - $0.min() >= 120 }, "\(points) pt")
        }
    }

    @Test("Glow frame: same state as Pixel, halos light dead cells; switching style keeps the simulation",
          .enabled(if: hasMetal, "No Metal device"))
    func glowFrame() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = CGSize(width: 120, height: 96)
        let pixelRenderer = try Renderer(device: device, generationsPerSecond: 10, cellPoints: 6, style: .pixel)
        let glowRenderer = try Renderer(device: device, generationsPerSecond: 10, cellPoints: 6, style: .glow)
        let pixel = try Pixels(pixelRenderer.renderOffscreen(viewSize: size, scale: 2, generations: 30, seed: 5))
        let glow = try Pixels(glowRenderer.renderOffscreen(viewSize: size, scale: 2, generations: 30, seed: 5))
        let pixelSim = try #require(pixelRenderer.simulation)
        let glowSim = try #require(glowRenderer.simulation)
        #expect(try pixelSim.readback(using: pixelRenderer.commandQueue) == glowSim.readback(using: glowRenderer.commandQueue))

        var haloCells = 0
        var gridlineCells = 0
        for cy in 0..<glowSim.height {
            for cx in 0..<glowSim.width {
                let (x0, y0) = (cx * 12, cy * 12)
                let center = glow.rgb(x0 + 6, y0 + 6)
                if pixel.rgb(x0 + 6, y0 + 6) == SIMD3(0, 0, 0) && center.max() > 10 { haloCells += 1 }
                // A gridline would darken the edge pixel well below its inner neighbor.
                let sum = { (p: SIMD3<Int>) in p.x + p.y + p.z }
                if sum(glow.rgb(x0, y0 + 6)) < sum(glow.rgb(x0 + 1, y0 + 6)) - 60
                    && sum(glow.rgb(x0 + 6, y0)) < sum(glow.rgb(x0 + 6, y0 + 1)) - 60 { gridlineCells += 1 }
            }
        }
        #expect(haloCells > 5)
        #expect(gridlineCells == 0)

        // Live switch: the state and generation are untouched.
        let before = try glowSim.readback(using: glowRenderer.commandQueue)
        glowRenderer.style = .pixel
        glowRenderer.style = .glow
        #expect(glowRenderer.simulation === glowSim)
        #expect(glowSim.generation == 30)
        #expect(try glowSim.readback(using: glowRenderer.commandQueue) == before)
    }

    @Test("Stamps are painted on the next frame even while paused, without stepping",
          .enabled(if: hasMetal, "No Metal device"))
    func stampsWhilePaused() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try Renderer(device: device, generationsPerSecond: 60, cellPoints: 6)
        renderer.resizeIfNeeded(for: CGSize(width: 384, height: 288))
        let simulation = try #require(renderer.simulation)
        renderer.clear()
        renderer.isPaused = true

        let burst = Stamp(x: 32, y: 24, radius: BrushStroke.burstRadius, kind: .burst, value: 0, seed: 7)
        renderer.addStamps([burst])
        let commandBuffer = try #require(renderer.commandQueue.makeCommandBuffer())
        renderer.advanceFrame(simulation, elapsed: 1, into: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var expected = Grid(width: 64, height: 48)
        RGBLife.stamp([burst], into: &expected)
        #expect(simulation.generation == 0)
        #expect(try simulation.readback(using: renderer.commandQueue) == expected.cells)
        #expect(expected.cells.contains { $0 != 0 })
    }

    @Test("Attach sizes and seeds the grid; controls step, clear and reseed",
          .enabled(if: hasMetal, "No Metal device"))
    @MainActor
    func attachAndControls() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try Renderer(device: device, generationsPerSecond: 10, cellPoints: 6)
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 600, height: 480), device: device)
        renderer.attach(to: view)
        #expect(view.preferredFramesPerSecond == 60)
        let simulation = try #require(renderer.simulation)
        #expect(simulation.width == 100 && simulation.height == 80)
        #expect(simulation.generation == 0)
        let seeded = try simulation.readback(using: renderer.commandQueue)
        #expect(seeded.contains { $0 != 0 })

        renderer.stepOnce()
        #expect(simulation.generation == 1)

        renderer.clear()
        #expect(simulation.generation == 0)
        #expect(try simulation.readback(using: renderer.commandQueue).allSatisfy { $0 == 0 })

        renderer.randomReset()
        #expect(try simulation.readback(using: renderer.commandQueue).contains { $0 != 0 })
    }
}
