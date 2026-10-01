import AppKit
import AutomataCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// In-memory only; resets to defaults on every launch.
    private var settings = Settings.defaults
    /// Simulation pause state; the app always launches playing.
    private var isPaused = false
    /// Reasons the render loop is halted (sleep, lock, session, Off).
    private var pauseState = PauseState()
    private var desktopWindow: DesktopWindow?
    private var mouseTracker: MouseTracker?
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Main display only.
        if let screen = NSScreen.screens.first {
            let window = DesktopWindow(screen: screen, settings: settings)
            desktopWindow = window
            if let renderer = window.renderer {
                let environment = ProcessInfo.processInfo.environment
                mouseTracker = MouseTracker(
                    window: window, renderer: renderer,
                    demo: environment["DA_DEMO_STROKE"] == "1",
                    logsProbes: environment["DA_PROBE_LOG"] == "1"
                )
            }
        } else {
            NSLog("DesktopAutomata: no screen available")
        }

        let menu = StatusMenuController(
            isEnabled: settings.isEnabled, isPaused: isPaused, rule: settings.rule, speed: settings.speed, palette: settings.palette,
            style: settings.style, cellSize: settings.cellSize, showsHUD: settings.hudEnabled
        )
        menu.onToggleEnabled = { [weak self] enabled in
            self?.setEnabled(enabled)
        }
        menu.onTogglePaused = { [weak self] paused in
            self?.setPaused(paused)
        }
        menu.onStep = { [weak self] in
            self?.desktopWindow?.renderer?.stepOnce()
        }
        menu.onRandomReset = { [weak self] in
            self?.desktopWindow?.renderer?.randomReset()
        }
        menu.onClear = { [weak self] in
            self?.desktopWindow?.renderer?.clear()
        }
        menu.onSelectRule = { [weak self] rule in
            self?.setRule(rule)
        }
        menu.onSelectSpeed = { [weak self] speed in
            self?.setSpeed(speed)
        }
        menu.onSelectPalette = { [weak self] palette in
            self?.setPalette(palette)
        }
        menu.onSelectStyle = { [weak self] style in
            self?.setStyle(style)
        }
        menu.onSelectCellSize = { [weak self] size in
            self?.setCellSize(size)
        }
        menu.onToggleHUD = { [weak self] shows in
            self?.setShowsHUD(shows)
        }
        statusMenu = menu

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        observePower()
        pauseState.set(.userDisabled, active: !settings.isEnabled)
        applyPauseState()
    }

    private func setEnabled(_ enabled: Bool) {
        settings.isEnabled = enabled
        setPauseReason(.userDisabled, active: !enabled)
    }

    private func setPauseReason(_ reason: PauseReason, active: Bool) {
        pauseState.set(reason, active: active)
        applyPauseState()
    }

    private func applyPauseState() {
        statusMenu?.isEnabled = settings.isEnabled
        desktopWindow?.apply(running: pauseState.isRunning, visible: pauseState.isWindowVisible)
    }

    /// Display sleep, screen lock and fast user switching halt the render loop.
    private func observePower() {
        let workspace = NSWorkspace.shared.notificationCenter
        let pairs: [(NSNotification.Name, PauseReason, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, .displaySleep, true),
            (NSWorkspace.screensDidWakeNotification, .displaySleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false),
        ]
        for (name, reason, active) in pairs {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.setPauseReason(reason, active: active)
            }
        }
        let distributed = DistributedNotificationCenter.default()
        for (name, active) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributed.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] _ in
                self?.setPauseReason(.screenLocked, active: active)
            }
        }
    }

    private func setPaused(_ paused: Bool) {
        isPaused = paused
        statusMenu?.isPaused = paused
        desktopWindow?.renderer?.isPaused = paused
    }

    /// Switches the rule; the renderer reseeds and restarts at generation 0.
    private func setRule(_ rule: AutomatonRule) {
        settings.rule = rule
        statusMenu?.rule = rule
        desktopWindow?.renderer?.rule = rule
    }

    private func setSpeed(_ speed: SimSpeed) {
        settings.speed = speed
        statusMenu?.speed = speed
        desktopWindow?.renderer?.generationsPerSecond = speed.generationsPerSecond
    }

    private func setPalette(_ palette: Palette) {
        settings.palette = palette
        statusMenu?.palette = palette
        desktopWindow?.renderer?.palette = palette
    }

    /// Switches the render style on the next frame; the simulation keeps running.
    private func setStyle(_ style: RenderStyle) {
        settings.style = style
        statusMenu?.style = style
        desktopWindow?.renderer?.style = style
    }

    /// Rebuilds the grid at the new cell size and reseeds.
    private func setCellSize(_ size: CellSize) {
        settings.cellSize = size
        statusMenu?.cellSize = size
        desktopWindow?.renderer?.cellPoints = size.points
    }

    private func setShowsHUD(_ shows: Bool) {
        settings.hudEnabled = shows
        statusMenu?.showsHUD = shows
        desktopWindow?.setShowsHUD(shows)
    }

    /// Display arrangement or resolution changed: re-fit to the main display and reseed.
    @objc private func screenParametersChanged(_ notification: Notification) {
        guard let screen = NSScreen.screens.first else { return }
        desktopWindow?.fit(to: screen)
    }
}
