import Testing
@testable import Runner

/// Covers the Task 8 third fix-wave race guard: `LiveActivityController`
/// must defer `Activity.request` until every non-matching stray has been
/// ended, which opens a window where `begin()` has returned but `activity`
/// is still `nil`. `LiveActivityRequestGate` is the pure, ActivityKit-free
/// extraction of the generation/in-flight bookkeeping that closes the two
/// races that window creates:
///  - re-entrancy: a second `begin()` while a request is in flight must not
///    fire a second `Activity.request`.
///  - `end()`/`discard()` racing the deferred request: a request whose
///    session already finished must not land and create an orphan.
struct LiveActivityRequestGateTests {
    @Test func initiallyNothingIsInFlightAndNoTokenProceeds() {
        var gate = LiveActivityRequestGate()
        #expect(gate.isInFlight == false)
        #expect(gate.shouldProceed(0) == false)
        #expect(gate.shouldProceed(1) == false)
    }

    @Test func startMarksInFlightAndSuccessiveTokensDiffer() {
        var gate = LiveActivityRequestGate()
        let first = gate.start()
        #expect(gate.isInFlight == true)
        let second = gate.start()
        #expect(second != first)
    }

    @Test func shouldProceedWithTheCurrentTokenSucceedsExactlyOnce() {
        var gate = LiveActivityRequestGate()
        let token = gate.start()
        #expect(gate.shouldProceed(token) == true)
        // Consumed: a second caller with the same token must not also proceed.
        #expect(gate.shouldProceed(token) == false)
        #expect(gate.isInFlight == false)
    }

    @Test func reEntrantBeginWhileInFlightIsVisibleViaIsInFlight() {
        var gate = LiveActivityRequestGate()
        _ = gate.start()
        // This is the guard `begin()` uses to refuse firing a second request.
        #expect(gate.isInFlight == true)
    }

    @Test func aNewerStartInvalidatesAnOlderTokenEvenWithoutExplicitInvalidate() {
        var gate = LiveActivityRequestGate()
        let staleToken = gate.start()
        let freshToken = gate.start()
        #expect(freshToken != staleToken)
        #expect(gate.shouldProceed(staleToken) == false)
        #expect(gate.shouldProceed(freshToken) == true)
    }

    @Test func invalidateBeforeShouldProceedPreventsTheRequestFromLanding() {
        var gate = LiveActivityRequestGate()
        let token = gate.start()
        // Simulates end()/discard() racing the deferred request: the run
        // finishes before the stray-clearing task reaches the request.
        gate.invalidate()
        #expect(gate.isInFlight == false)
        #expect(gate.shouldProceed(token) == false)
    }

    @Test func invalidateThenANewStartAllowsTheFreshTokenToProceed() {
        var gate = LiveActivityRequestGate()
        let oldToken = gate.start()
        gate.invalidate()
        let newToken = gate.start()
        #expect(gate.shouldProceed(oldToken) == false)
        #expect(gate.shouldProceed(newToken) == true)
    }

    @Test func invalidateWhenNothingIsInFlightIsHarmless() {
        var gate = LiveActivityRequestGate()
        gate.invalidate()
        #expect(gate.isInFlight == false)
    }
}
