import Testing
@testable import TermIMSCore

@Suite("Switch policy")
struct SwitchPolicyTests {
    typealias P = SwitchPolicy

    // MARK: combining what the surfaces said

    @Test("surfaces naming one source agree on it")
    func agreement() {
        #expect(P.combine(["cn"]) == .matched("cn"))
        #expect(P.combine(["cn", "cn"]) == .matched("cn"))
    }

    /// Two unremarkable tabs really do call for the default — agreeing on
    /// "nothing matches" is an answer, not an absence of one.
    @Test("surfaces agreeing that no rule applies is decisive")
    func agreedNoRule() {
        #expect(P.combine([nil]) == .noRuleApplies)
        #expect(P.combine([nil, nil]) == .noRuleApplies)
    }

    @Test("disagreement cannot be resolved")
    func disagreement() {
        #expect(P.combine(["cn", nil]) == .undecided)
        #expect(P.combine([nil, "cn"]) == .undecided)
        #expect(P.combine(["cn", "jp"]) == .undecided)
    }

    @Test("no surface at all is not an answer")
    func noSurfaces() {
        #expect(P.combine([]) == .undecided)
    }

    // MARK: acting on the outcome

    @Test("a match is used wherever the user came from", arguments: [P.Transition.enteringApp, .withinApp])
    func matchAlwaysUsed(transition: P.Transition) {
        #expect(P.decide(.matched("cn"), transition: transition) == .use("cn"))
    }

    @Test("an agreed non-match falls to the default", arguments: [P.Transition.enteringApp, .withinApp])
    func noRuleUsesDefault(transition: P.Transition) {
        #expect(P.decide(.noRuleApplies, transition: transition) == .useDefault)
    }

    /// Arriving from another application, the current source belongs to that
    /// application — some answer is needed, and the default is the one we have.
    @Test("entering the app, an undecided outcome still takes the default")
    func undecidedOnEntry() {
        #expect(P.decide(.undecided, transition: .enteringApp) == .useDefault)
    }

    /// Already inside, the current source is the user's context. Replacing it
    /// on a guess corrupts what is being typed; holding costs at most one
    /// manual switch.
    @Test("already inside, an undecided outcome changes nothing")
    func undecidedWithinApp() {
        #expect(P.decide(.undecided, transition: .withinApp) == .hold)
    }
}
