import Testing
import AutomataCore

@Suite("Pause state")
struct PauseStateTests {
    /// Applies one event and returns whether `isRunning` flipped.
    private func apply(_ state: inout PauseState, _ reason: PauseReason, _ active: Bool) -> Bool {
        state.set(reason, active: active)
    }

    @Test("A single reason pauses and its removal resumes", arguments: PauseReason.allCases)
    func singleReason(reason: PauseReason) {
        var state = PauseState()
        #expect(state.isRunning && state.isWindowVisible)
        let paused = apply(&state, reason, true)
        #expect(paused && !state.isRunning)
        #expect(state.isWindowVisible == (reason != .userDisabled))
        let resumed = apply(&state, reason, false)
        #expect(resumed && state.isRunning && state.isWindowVisible)
    }

    @Test("Overlapping reasons resume only when all are gone")
    func overlapping() {
        var state = PauseState()
        #expect(apply(&state, .displaySleep, true))
        #expect(!apply(&state, .screenLocked, true))
        #expect(!apply(&state, .displaySleep, false))  // wake while still locked
        #expect(!state.isRunning)
        #expect(!apply(&state, .sessionInactive, true))
        #expect(!apply(&state, .screenLocked, false))
        #expect(!state.isRunning)
        #expect(apply(&state, .sessionInactive, false))
        #expect(state.isRunning)
        // Off during sleep: waking keeps it off and hidden.
        _ = apply(&state, .userDisabled, true)
        _ = apply(&state, .displaySleep, true)
        _ = apply(&state, .displaySleep, false)
        #expect(!state.isRunning && !state.isWindowVisible)
    }

    @Test("Duplicate events are idempotent")
    func idempotent() {
        var state = PauseState()
        #expect(!apply(&state, .screenLocked, false))  // unlock without lock
        #expect(state.isRunning)
        #expect(apply(&state, .screenLocked, true))
        #expect(!apply(&state, .screenLocked, true))
        #expect(state.reasons == [.screenLocked])
        #expect(apply(&state, .screenLocked, false))  // one remove is enough
        #expect(!apply(&state, .screenLocked, false))
        #expect(state.isRunning && state.reasons.isEmpty)
    }
}
