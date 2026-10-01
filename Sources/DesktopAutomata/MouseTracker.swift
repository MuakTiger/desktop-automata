import AppKit
import AutomataCore
import AutomataGPU

/// Polls the pointer once per rendered frame (`NSEvent.mouseLocation` and
/// `NSEvent.pressedMouseButtons`; no permissions, no event taps) and turns
/// movement over the bare desktop into trail stamps and left clicks into
/// bursts. Over app windows, the Dock, the menu bar or another screen the
/// pen lifts and nothing is painted. The right button is ignored.
///
/// `DA_DEMO_STROKE=1` replaces the pointer with `DemoStroke` for its frames
/// (bypassing the probe), then returns to the real pointer.
final class MouseTracker {
    private weak var window: NSWindow?
    private weak var renderer: Renderer?
    let probe: DesktopProbe
    private var clicks = ClickDetector()
    private var brush = BrushStroke()
    private var demo: [DemoStroke.Sample] = []
    private var demoIndex = 0

    init(window: NSWindow, renderer: Renderer, demo: Bool, logsProbes: Bool) {
        self.window = window
        self.renderer = renderer
        probe = DesktopProbe(ownWindowNumber: { [weak window] in window?.windowNumber })
        probe.logsProbes = logsProbes
        if demo {
            self.demo = DemoStroke.samples(in: window.frame)
        }
        if logsProbes {
            let point = NSEvent.mouseLocation
            let hit = DesktopProbe.hit(at: point)
            NSLog("DesktopProbe: screen capture access=%@, own window %ld, cursor (%.0f, %.0f) -> window %ld layer %@",
                  CGPreflightScreenCaptureAccess() ? "yes" : "no", window.windowNumber, point.x, point.y,
                  hit.windowNumber, hit.layer.map(String.init) ?? "nil")
        }
        renderer.onFrame = { [weak self] now in self?.poll(now: now) }
    }

    private func poll(now: CFTimeInterval) {
        guard let window, let renderer, let simulation = renderer.simulation else { return }
        let grid = ScreenGrid(
            frame: window.frame, scale: Double(window.backingScaleFactor),
            width: simulation.width, height: simulation.height
        )
        if demoIndex < demo.count {
            let sample = demo[demoIndex]
            demoIndex += 1
            renderer.addStamps(brush.update(
                position: sample.point.flatMap(grid.position(of:)), clicked: sample.clicked, time: sample.time
            ))
            return
        }
        let point = NSEvent.mouseLocation
        let clicked = clicks.update(pressedButtons: NSEvent.pressedMouseButtons)
        var position = grid.position(of: point)
        if position != nil, !probe.desktopVisible(at: point, now: now, force: clicked) {
            position = nil
        }
        renderer.addStamps(brush.update(position: position, clicked: clicked, time: now))
    }
}
