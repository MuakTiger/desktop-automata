import AppKit
import Metal
import MetalKit
import AutomataCore
import AutomataGPU

/// Borderless, click-through window pinned to the desktop layer
/// (below Finder's desktop icons) on every Space.
final class DesktopWindow: NSWindow {
    private let metalView: MTKView?
    /// Strong reference: MTKView.delegate is weak. Nil when Metal is unavailable.
    let renderer: Renderer?
    /// Lab-readout overlay above the automaton. Nil when Metal is unavailable.
    private let hud: HUDView?
    private var isActive = false
    private var showsHUD: Bool

    init(screen: NSScreen, settings: Settings) {
        let frame = screen.frame
        var metalView: MTKView?
        var renderer: Renderer?
        if let device = MTLCreateSystemDefaultDevice() {
            do {
                let created = try Renderer(
                    device: device,
                    generationsPerSecond: settings.speed.generationsPerSecond,
                    cellPoints: settings.cellSize.points,
                    rule: settings.rule,
                    palette: settings.palette,
                    style: settings.style
                )
                let view = MTKView(frame: NSRect(origin: .zero, size: frame.size), device: device)
                created.attach(to: view)
                metalView = view
                renderer = created
            } catch {
                NSLog("DesktopAutomata: renderer setup failed (%@); desktop layer stays black", "\(error)")
            }
        } else {
            NSLog("DesktopAutomata: Metal device unavailable; desktop layer stays black")
        }
        self.metalView = metalView
        self.renderer = renderer
        self.hud = renderer.map(HUDView.init(renderer:))
        self.showsHUD = settings.hudEnabled

        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)

        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        if let metalView {
            let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
            metalView.autoresizingMask = [.width, .height]
            container.addSubview(metalView)
            if let hud {
                hud.place(on: screen)
                container.addSubview(hud)
            }
            contentView = container
        }
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Runs or idles the render loop (`MTKView.isPaused`; mouse polling and
    /// desktop probing run from the frame callback, so they stop too) and
    /// shows or hides the window.
    func apply(running: Bool, visible: Bool) {
        isActive = running
        metalView?.isPaused = !running
        updateHUD()
        if visible {
            if !isVisible { orderFrontRegardless() }
        } else {
            orderOut(nil)
        }
    }

    func setShowsHUD(_ shows: Bool) {
        showsHUD = shows
        updateHUD()
    }

    /// Re-fits the window to `screen` (display arrangement or resolution
    /// changed), then rebuilds the grid textures and reseeds.
    func fit(to screen: NSScreen) {
        let frame = screen.frame
        guard frame.width > 0, frame.height > 0 else { return }
        setFrame(frame, display: false)
        hud?.place(on: screen)
        renderer?.rebuild(for: frame.size)
    }

    private func updateHUD() {
        // The timer only runs while the overlay can be seen.
        hud?.setRunning(isActive && showsHUD)
    }
}
