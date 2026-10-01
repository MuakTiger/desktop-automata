/// Why the desktop render loop is halted. Several can hold at once.
///
/// The menu's Pause/Play is not one of them: a user pause freezes the
/// simulation but keeps rendering so mouse stamps still paint.
public enum PauseReason: Hashable, CaseIterable, Sendable {
    case displaySleep
    case screenLocked
    case sessionInactive
    /// Menu Off: also hides the window.
    case userDisabled
}

/// Pure pause-reason set: the loop runs only when no reason holds, so
/// overlapping reasons (lock during sleep, ...) never resume early.
public struct PauseState: Equatable, Sendable {
    public private(set) var reasons: Set<PauseReason> = []

    public init() {}

    public var isRunning: Bool { reasons.isEmpty }
    /// The window is hidden only when the user turned the app off.
    public var isWindowVisible: Bool { !reasons.contains(.userDisabled) }

    /// Adds or removes `reason`. Returns whether `isRunning` changed.
    /// Duplicate inserts and removes of absent reasons are no-ops.
    @discardableResult
    public mutating func set(_ reason: PauseReason, active: Bool) -> Bool {
        let wasRunning = isRunning
        if active {
            reasons.insert(reason)
        } else {
            reasons.remove(reason)
        }
        return wasRunning != isRunning
    }
}
