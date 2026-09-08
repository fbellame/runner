import Foundation

/// Whether Today should offer a Monthly Wrapped banner, and what happens when
/// the user acts on it.
///
/// Both halves used to live in `TodayView`. The ✕ called `markSeen` and nothing
/// else — a write SwiftUI does not observe — so the banner stayed on screen for
/// the rest of the session, and the only thing that made it go away was
/// relaunching the app. The fix was a second piece of state, which is precisely
/// the kind of rule that wants a test and could not have one inside a view body.
enum WrappedBannerState {

    /// The month to offer, or `nil` when there is nothing to offer.
    ///
    /// Deliberately cheap: `availableMonths` is one pass and a sort, and both
    /// dismissal checks happen here. Building the story is not — `monthWrapped`
    /// runs `TrophyMath.allBadges` twice and `ActivityStats.typeRecords` twelve
    /// times over all history, plus a per-day heat strip — and it used to run on
    /// every Today body pass, ten of them on a cold launch, purely to decide
    /// whether to draw a banner the user had dismissed months earlier. Check
    /// `isSeen` before building anything.
    ///
    /// - Parameters:
    ///   - dismissedThisSession: the in-memory half. A persisted `markSeen` is
    ///     invisible to SwiftUI, so without this the banner survives its own
    ///     dismissal until the next launch.
    ///   - isSeen: the durable half, surviving relaunch.
    static func pendingMonth(_ summaries: [ActivityWorkoutSummary],
                             asOf: Date,
                             calendar: Calendar,
                             dismissedThisSession: WrappedMonth?,
                             isSeen: (WrappedMonth) -> Bool) -> WrappedMonth? {
        guard let month = WrappedMath.availableMonths(summaries, asOf: asOf,
                                                      calendar: calendar).first,
              month != dismissedThisSession,
              !isSeen(month) else {
            return nil
        }
        return month
    }
}
