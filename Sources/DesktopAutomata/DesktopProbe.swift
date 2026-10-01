import AppKit
import AutomataCore

/// Answers "is bare desktop visible at this screen point?" without any
/// permission: the topmost window under the point comes from
/// `NSWindow.windowNumber(at:belowWindowWithWindowNumber: 0)` and its layer
/// from `CGWindowListCopyWindowInfo(.optionIncludingWindow, number)`
/// (`kCGWindowLayer` and bounds need no Screen Recording permission; only
/// window titles do). `WindowLayerClassifier` decides.
///
/// Results are cached: re-probes at most every `minInterval` (~20 Hz) and only
/// when the cursor moved, unless forced (on a click).
final class DesktopProbe {
    struct Hit: Equatable {
        var windowNumber: Int
        var layer: Int?
    }

    static let minInterval: CFTimeInterval = 0.05

    /// Our desktop window's number (counts as desktop).
    var ownWindowNumber: () -> Int?
    /// `DA_PROBE_LOG=1`: log each probe whose window or layer changed.
    var logsProbes = false

    private var lastPoint: NSPoint?
    private var lastProbeTime: CFTimeInterval = -.infinity
    private(set) var lastHit: Hit?
    private(set) var isDesktopVisible = false

    init(ownWindowNumber: @escaping () -> Int?) {
        self.ownWindowNumber = ownWindowNumber
    }

    /// Whether the desktop is visible at `point` (Cocoa screen coordinates).
    func desktopVisible(at point: NSPoint, now: CFTimeInterval, force: Bool = false) -> Bool {
        let moved = point != lastPoint
        guard force || (moved && now - lastProbeTime >= Self.minInterval) else { return isDesktopVisible }
        lastPoint = point
        lastProbeTime = now
        let hit = Self.hit(at: point)
        isDesktopVisible = WindowLayerClassifier.isDesktop(
            layer: hit.layer, windowNumber: hit.windowNumber, ownWindowNumber: ownWindowNumber()
        )
        if logsProbes, hit != lastHit {
            NSLog("DesktopProbe: (%.0f, %.0f) -> window %ld layer %@ desktop=%@",
                  point.x, point.y, hit.windowNumber, hit.layer.map(String.init) ?? "nil",
                  isDesktopVisible ? "yes" : "no")
        }
        lastHit = hit
        return isDesktopVisible
    }

    /// Topmost window at `point` and its layer (nil if it has no window-list entry).
    static func hit(at point: NSPoint) -> Hit {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard
            number > 0,
            let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]],
            let info = list.first
        else { return Hit(windowNumber: number, layer: nil) }
        return Hit(windowNumber: number, layer: info[kCGWindowLayer as String] as? Int)
    }
}
