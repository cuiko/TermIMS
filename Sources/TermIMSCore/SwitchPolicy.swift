import Foundation

/// Deciding what to do once the surfaces have been read.
///
/// Separating this from the reading matters because the honest answer is
/// sometimes "I cannot tell". Terminals like Ghostty expose no per-tab tty, so
/// when two tabs in one directory both run a foreground program, nothing
/// distinguishes them. Treating that as "no rule matched" switches to the
/// terminal default, which is a switch made on no evidence — it interrupts
/// whatever the user was typing.
///
/// Whether that is acceptable depends on where the user came from, so the
/// transition is part of the decision.
public enum SwitchPolicy {

    /// What the surfaces said, once their answers were combined.
    public enum Outcome: Equatable {
        /// Every surface in contention names the same input source.
        case matched(String)
        /// The surfaces were read, and no rule applies to them.
        case noRuleApplies
        /// Which surface has focus could not be determined.
        case undecided
    }

    public enum Transition: Equatable {
        /// The user just came from another application.
        case enteringApp
        /// The user was already here; a tab, pane, or window changed.
        case withinApp
    }

    public enum Action: Equatable {
        case use(String)
        /// Fall through to the configured default.
        case useDefault
        /// Change nothing.
        case hold
    }

    /// Combine one answer per surface into a single outcome.
    ///
    /// Surfaces agreeing on "no rule" is itself an answer — two tabs both
    /// running something unremarkable really do call for the default. Only
    /// disagreement, or having no surface at all, means we cannot tell.
    public static func combine(_ perSurface: [String?]) -> Outcome {
        guard let first = perSurface.first else { return .undecided }
        guard perSurface.allSatisfy({ $0 == first }) else { return .undecided }
        guard let id = first else { return .noRuleApplies }
        return .matched(id)
    }

    /// What to do about an outcome.
    ///
    /// Entering the application has to produce some input source: the user
    /// arrived from elsewhere and the previous one belonged to another app, so
    /// the default is the best available answer. Once inside, the current
    /// source is already the user's context, and replacing it on a guess is
    /// worse than leaving it — a wrong switch corrupts text being typed, while
    /// holding merely leaves a switch to be made by hand.
    public static func decide(_ outcome: Outcome, transition: Transition) -> Action {
        switch outcome {
        case .matched(let id):
            return .use(id)
        case .noRuleApplies:
            return .useDefault
        case .undecided:
            return transition == .enteringApp ? .useDefault : .hold
        }
    }
}
