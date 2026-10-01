import AppKit
import AutomataCore
import AutomataGPU

/// Lab-readout overlay in the bottom-left of the desktop window: rule,
/// generation, population and gen/s, refreshed at 4 Hz while visible.
/// Never takes mouse events (the window ignores them too).
final class HUDView: NSView {
    static let refreshInterval: TimeInterval = 0.25
    /// Inset from the left edge and from the bottom of the screen's visible frame (above the Dock).
    static let margin: CGFloat = 16

    private weak var renderer: Renderer?
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    /// (time, totalSteps) samples for the measured rate, about the last second.
    private var samples: [(time: CFTimeInterval, steps: UInt64)] = []

    init(renderer: Renderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedRed: 0.3, green: 1, blue: 0.75, alpha: 0.35).cgColor
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = NSColor(calibratedRed: 0.55, green: 1, blue: 0.8, alpha: 0.95)
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = true
        addSubview(label)
        setAccessibilityElement(false)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    /// Starts or stops the 4 Hz refresh and shows or hides the overlay.
    func setRunning(_ running: Bool) {
        isHidden = !running
        timer?.invalidate()
        timer = nil
        samples.removeAll()
        guard running else { return }
        refresh()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Places the overlay at the bottom-left of `screen`'s visible area, in
    /// the coordinates of a window covering `screen.frame`.
    func place(on screen: NSScreen) {
        let bottom = screen.visibleFrame.minY - screen.frame.minY
        let left = screen.visibleFrame.minX - screen.frame.minX
        setFrameOrigin(NSPoint(x: left + Self.margin, y: bottom + Self.margin))
    }

    private func refresh() {
        guard let renderer else { return }
        let now = CACurrentMediaTime()
        samples.append((now, renderer.totalSteps))
        samples.removeAll { now - $0.time > 1.05 }
        var actual: Double?
        if let first = samples.first, now - first.time > 0.5 {
            actual = Double(renderer.totalSteps &- first.steps) / (now - first.time)
        }
        label.stringValue = Self.text(
            rule: renderer.rule,
            generation: renderer.simulation?.generation,
            population: renderer.population?.count,
            configured: renderer.generationsPerSecond,
            actual: actual,
            paused: renderer.isPaused
        )
        label.sizeToFit()
        let padding = NSSize(width: 10, height: 6)
        label.setFrameOrigin(NSPoint(x: padding.width, y: padding.height))
        setFrameSize(NSSize(width: label.frame.width + 2 * padding.width, height: label.frame.height + 2 * padding.height))
    }

    static func text(
        rule: AutomatonRule, generation: UInt32?, population: Int?, configured: Int, actual: Double?, paused: Bool
    ) -> String {
        let generationText = generation.map { $0.formatted() } ?? "-"
        let populationText = population.map { "\($0.formatted()) \(rule.populationTitle)" } ?? "-"
        let rate: String
        if paused {
            rate = "\(configured) gen/s  [paused]"
        } else if let actual {
            rate = "\(configured) gen/s  (actual \(String(format: "%.1f", actual)))"
        } else {
            rate = "\(configured) gen/s"
        }
        return """
        RULE  \(rule.title)
        GEN   \(generationText)
        POP   \(populationText)
        RATE  \(rate)
        """
    }
}
