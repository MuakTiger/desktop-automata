import CoreGraphics
import Testing
@testable import AutomataCore

@Suite("Screen to grid coordinates")
struct CoordsTests {
    let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    @Test("Corners and y-flip: Cocoa's bottom-left origin maps to grid row 0 at the top")
    func cornersAndFlip() throws {
        let grid = ScreenGrid(frame: screen, scale: 2, cellPoints: 6)
        #expect(grid.width == 427 && grid.height == 240)
        #expect(try #require(grid.cell(of: CGPoint(x: 0, y: 1440))) == (0, 0))
        #expect(try #require(grid.cell(of: CGPoint(x: 0, y: 0))) == (0, 239))
        #expect(try #require(grid.cell(of: CGPoint(x: 2560, y: 0))) == (426, 239))
        #expect(try #require(grid.cell(of: CGPoint(x: 2560, y: 1440))) == (426, 0))
        // 240 rows over 1440 pt: exactly 6 pt per row, counted from the top.
        #expect(try #require(grid.cell(of: CGPoint(x: 3, y: 1440 - 6 * 10 - 3))).y == 10)
        // Off the screen (another display): no cell.
        #expect(grid.cell(of: CGPoint(x: -1, y: 10)) == nil)
        #expect(grid.cell(of: CGPoint(x: 10, y: 1441)) == nil)
        // A screen whose origin is not (0, 0).
        let offset = ScreenGrid(frame: CGRect(x: -100, y: 50, width: 1200, height: 720), scale: 2, cellPoints: 6)
        #expect(try #require(offset.cell(of: CGPoint(x: -100, y: 770))) == (0, 0))
        #expect(try #require(offset.cell(of: CGPoint(x: 1100, y: 50))) == (199, 119))
    }

    @Test("2x Retina resolves the backing pixel under the point, like the fragment shader")
    func retina() throws {
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 720)
        let one = ScreenGrid(frame: frame, scale: 1, cellPoints: 6)
        let two = ScreenGrid(frame: frame, scale: 2, cellPoints: 6)
        #expect(one.width == two.width && one.height == two.height)  // the grid is sized in points
        #expect(two.pixelWidth == 2400 && two.pixelHeight == 1440)
        // Pixel centers: x 3.2 pt is pixel 3 at 1x, pixel 6 at 2x.
        #expect(abs(try #require(one.position(of: CGPoint(x: 3.2, y: 700))).x - 3.5 / 6) < 1e-12)
        #expect(abs(try #require(two.position(of: CGPoint(x: 3.2, y: 700))).x - 6.5 / 12) < 1e-12)
        // Cell boundary at 6 pt in both scales.
        for grid in [one, two] {
            #expect(try #require(grid.cell(of: CGPoint(x: 5.9, y: 719.9))) == (0, 0))
            #expect(try #require(grid.cell(of: CGPoint(x: 6.0, y: 714.0))) == (1, 1))
        }
    }

    @Test("Cell sizes 3 and 12 pt", arguments: [(3, 854, 480, 427, 240), (12, 214, 120, 107, 60)])
    func cellSizes(points: Int, width: Int, height: Int, midX: Int, midY: Int) throws {
        let grid = ScreenGrid(frame: screen, scale: 2, cellPoints: points)
        #expect(grid.width == width && grid.height == height)
        #expect(try #require(grid.cell(of: CGPoint(x: 0, y: 1440))) == (0, 0))
        #expect(try #require(grid.cell(of: CGPoint(x: 2560, y: 0))) == (width - 1, height - 1))
        #expect(try #require(grid.cell(of: CGPoint(x: 1280, y: 720))) == (midX, midY))
    }

    @Test("Grid dims are ceil(points / cell) for every cell size, on 2560x1440 and an odd size", arguments: [
        (3, 854, 480, 504, 328),
        (4, 640, 360, 378, 246),
        (6, 427, 240, 252, 164),
        (8, 320, 180, 189, 123),
        (12, 214, 120, 126, 82),
    ])
    func gridDims(points: Int, width: Int, height: Int, oddWidth: Int, oddHeight: Int) throws {
        #expect(CellSize.allCases.map(\.points).contains(points))
        #expect(ScreenGrid.gridSize(for: CGSize(width: 2560, height: 1440), cellPoints: points) == (width, height))
        #expect(ScreenGrid.gridSize(for: CGSize(width: 1511, height: 983), cellPoints: points) == (oddWidth, oddHeight))
        // The mouse mapping uses the same dims, and its corners land on the grid's corners.
        for frame in [screen, CGRect(x: 0, y: 0, width: 1511, height: 983)] {
            let grid = ScreenGrid(frame: frame, scale: 2, cellPoints: points)
            let size = ScreenGrid.gridSize(for: frame.size, cellPoints: points)
            #expect(grid.width == size.width && grid.height == size.height)
            #expect(try #require(grid.cell(of: CGPoint(x: frame.minX, y: frame.maxY))) == (0, 0))
            #expect(try #require(grid.cell(of: CGPoint(x: frame.maxX, y: frame.minY))) == (size.width - 1, size.height - 1))
        }
        #expect(ScreenGrid.gridSize(for: .zero, cellPoints: points) == (1, 1))
    }
}

@Suite("Brush stroke")
struct BrushStrokeTests {
    @Test("A fast move leaves no gaps and keeps the spacing bound")
    func noGaps() throws {
        var brush = BrushStroke()
        let start = SIMD2(10.5, 10.5)
        let end = SIMD2(110.3, 60.7)  // ~112 cells in one frame
        let first = brush.update(position: start, clicked: false, time: 0)
        let move = brush.update(position: end, clicked: false, time: 0)
        #expect(first.count == 1)
        #expect(move.count == 55 && move.count <= Stamp.maxPerFrame)
        let stamps = first + move
        #expect(stamps.allSatisfy { $0.kind == .trail && $0.radius == BrushStroke.trailRadius })
        // Consecutive centers: spacing plus at most one cell of rounding (√2).
        for (a, b) in zip(stamps, stamps.dropFirst()) {
            let d = SIMD2(Double(b.x - a.x), Double(b.y - a.y))
            #expect((d * d).sum().squareRoot() <= BrushStroke.spacing + 2.0.squareRoot())
        }
        // Every cell the path crosses (up to the last stamp) is inside some stamp.
        let last = try #require(brush.lastStamp)
        for i in 0...1000 {
            let p = start + (last - start) * (Double(i) / 1000)
            let (x, y) = (Int(p.x), Int(p.y))
            #expect(stamps.contains { $0.covers(dx: x - Int($0.x), dy: y - Int($0.y)) }, "gap at (\(x), \(y))")
        }
    }

    @Test("At most 64 stamps per frame; a click adds one burst; lifting starts a new stroke")
    func capClickAndLift() {
        var brush = BrushStroke()
        _ = brush.update(position: SIMD2(0.5, 0.5), clicked: false, time: 0)
        #expect(brush.update(position: SIMD2(500.5, 0.5), clicked: false, time: 0).count == Stamp.maxPerFrame)
        #expect(brush.lastStamp == SIMD2(500.5, 0.5))

        let click = brush.update(position: SIMD2(900.5, 0.5), clicked: true, time: 0)
        #expect(click.count == Stamp.maxPerFrame)
        #expect(click.first?.kind == .burst && click.first?.radius == BrushStroke.burstRadius)
        #expect(click.dropFirst().allSatisfy { $0.kind == .trail })

        #expect(brush.update(position: SIMD2(901, 0.5), clicked: false, time: 0).isEmpty)  // < spacing
        #expect(brush.update(position: nil, clicked: false, time: 0).isEmpty)
        #expect(brush.lastStamp == nil)
        #expect(brush.update(position: SIMD2(5.5, 5.5), clicked: false, time: 0).count == 1)
    }

    @Test("Trail hue cycles R, RG, G, GB, B, BR over time")
    func hueCycle() {
        let steps = (0..<7).map { BrushStroke.hueStep(at: Double($0) * BrushStroke.hueStepSeconds + 0.01) }
        #expect(steps == [0, 1, 2, 3, 4, 5, 0])
        #expect(steps.prefix(6).map(RGBLife.mask(forHueStep:)) == [0b001, 0b011, 0b010, 0b110, 0b100, 0b101])
    }

    @Test("Click is the left button's rising edge; the right button is ignored")
    func clickEdge() {
        var detector = ClickDetector()
        // press, hold, release, press again, release, right only, left while right held, hold
        let buttons = [1, 1, 0, 1, 0, 2, 3, 1]
        #expect(buttons.map { detector.update(pressedButtons: $0) } == [true, false, false, true, false, false, true, false])
    }
}

@Suite("Window layer classification")
struct WindowLayerClassifierTests {
    @Test("Desktop below layer 0 or our own window; windows, Dock and menu bar are not")
    func table() {
        let own = 42
        let cases: [(layer: Int?, window: Int, desktop: Bool)] = [
            (-2147483623, 7, true),   // desktop picture
            (-2147483603, 7, true),   // Finder desktop icons
            (-2147483601, 7, true),   // desktop-level helper
            (-1, 7, true),
            (0, 7, false),            // normal app window
            (3, 7, false),            // floating panel
            (20, 7, false),           // Dock
            (24, 7, false),           // menu bar
            (25, 7, false),           // status items
            (101, 7, false),          // pop-up menu
            (2147483630, 7, false),
            (-2147483623, own, true), // our own window
            (nil, own, true),
            (nil, 7, false),          // unknown layer: fail closed
            (nil, 0, false),          // no window found
        ]
        for c in cases {
            #expect(WindowLayerClassifier.isDesktop(layer: c.layer, windowNumber: c.window, ownWindowNumber: own) == c.desktop,
                    "layer \(String(describing: c.layer)) window \(c.window)")
        }
    }
}
