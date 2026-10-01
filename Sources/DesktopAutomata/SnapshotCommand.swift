import AppKit
import AutomataCore
import AutomataGPU
import Metal

/// Debug mode: `DA_SNAPSHOT=/path/out.png DesktopAutomata` renders N generations
/// offscreen, writes a PNG and exits without showing any UI.
///
/// Optional environment:
/// - `DA_SNAPSHOT_GENERATIONS`: generations to run (default 30)
/// - `DA_RULE`: `AutomatonRule` raw value (default the settings default)
/// - `DA_SNAPSHOT_PALETTE`: `Palette` raw value (default the settings default)
/// - `DA_SNAPSHOT_CELL`: cell size in points, one of `CellSize` (default the settings default)
/// - `DA_SNAPSHOT_SEED`: seed (default 1)
/// - `DA_STYLE`: `RenderStyle` raw value, `pixel` or `glow` (default the settings default)
/// - `DA_DEMO_STROKE=1`: after those generations, play `DemoStroke` (a synthetic
///   diagonal trail and a click burst, 60 fps frames at the default speed)
///   through the stamp pipeline before drawing
///
/// The view size and scale are the main screen's (1280x800 pt at 2x without one).
enum SnapshotCommand {
    static func run(path: String, environment: [String: String]) -> Int32 {
        var settings = Settings.defaults
        var generations = 30
        var seed: UInt32 = 1
        if let value = environment["DA_SNAPSHOT_GENERATIONS"] {
            guard let parsed = Int(value), parsed >= 0 else { return fail("DA_SNAPSHOT_GENERATIONS must be >= 0") }
            generations = parsed
        }
        if let value = environment["DA_RULE"] {
            guard let parsed = AutomatonRule(rawValue: value) else {
                return fail("DA_RULE must be one of \(AutomatonRule.allCases.map(\.rawValue))")
            }
            settings.rule = parsed
        }
        if let value = environment["DA_SNAPSHOT_PALETTE"] {
            guard let parsed = Palette(rawValue: value) else {
                return fail("DA_SNAPSHOT_PALETTE must be one of \(Palette.allCases.map(\.rawValue))")
            }
            settings.palette = parsed
        }
        if let value = environment["DA_SNAPSHOT_CELL"] {
            guard let parsed = Int(value).flatMap(CellSize.init(rawValue:)) else {
                return fail("DA_SNAPSHOT_CELL must be one of \(CellSize.allCases.map(\.rawValue))")
            }
            settings.cellSize = parsed
        }
        if let value = environment["DA_STYLE"] {
            guard let parsed = RenderStyle(rawValue: value) else {
                return fail("DA_STYLE must be one of \(RenderStyle.allCases.map(\.rawValue))")
            }
            settings.style = parsed
        }
        if let value = environment["DA_SNAPSHOT_SEED"] {
            guard let parsed = UInt32(value) else { return fail("DA_SNAPSHOT_SEED must be a UInt32") }
            seed = parsed
        }
        guard let device = MTLCreateSystemDefaultDevice() else { return fail("no Metal device") }

        let screen = NSScreen.main
        let viewSize = screen?.frame.size ?? CGSize(width: 1280, height: 800)
        let scale = screen?.backingScaleFactor ?? 2
        var stampFrames: [[Stamp]] = []
        if environment["DA_DEMO_STROKE"] == "1" {
            let grid = ScreenGrid(
                frame: screen?.frame ?? CGRect(origin: .zero, size: viewSize),
                scale: Double(scale), cellPoints: settings.cellSize.points
            )
            stampFrames = DemoStroke.stampFrames(on: grid)
        }
        let url = URL(fileURLWithPath: path)
        do {
            try Snapshot.writePNG(
                to: url, device: device, settings: settings,
                viewSize: viewSize, scale: scale, generations: generations, seed: seed, stampFrames: stampFrames
            )
        } catch {
            return fail("\(error)")
        }
        let demo = stampFrames.isEmpty
            ? ""
            : ", demo stroke \(stampFrames.joined().count) stamps over \(stampFrames.count) frames"
        print("DesktopAutomata: wrote \(url.path) (\(Int(viewSize.width))x\(Int(viewSize.height)) pt @\(scale)x, "
            + "\(settings.rule.title), \(settings.palette.title), \(settings.style.title), \(settings.cellSize.title), \(generations) generations, seed \(seed)\(demo))")
        return 0
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("DesktopAutomata snapshot: \(message)\n".utf8))
        return 1
    }
}
