import Foundation

/// The one-sentence answer Siri and Shortcuts give for "what's my Deskpilot status", built from
/// the widget's snapshot so it says the same thing the widget shows.
public enum DeskStatusSummary {
    public static let disconnected = "Deskpilot isn't connected to the desk."

    public static func sentence(_ snapshot: DeskSnapshot?, now: Date = Date()) -> String {
        guard let s = snapshot, s.connected, now.timeIntervalSince(s.updatedAt) <= DeskSnapshot.staleAfter else {
            return disconnected
        }
        // At-desk time grows while present between the app's snapshot writes, as in the widget.
        let atDesk = s.atDeskSeconds + (s.isPresent ? max(0, now.timeIntervalSince(s.updatedAt)) : 0)
        let today = "\(Formatting.duration(atDesk)) at the desk and \(s.standsToday) stands today."
        guard s.isPresent else { return "You're away from the desk. \(today)" }

        let posture = "You're \(s.isStanding == true ? "standing" : "sitting") at \(Formatting.height(tenths: s.heightTenths))."
        let next: String
        if let move = s.nextMove {
            let verb = move.toStanding ? "stand" : "sit"
            // The countdown runs to the beep, like the app's; past that the desk decides.
            next = move.announceAt > now
                ? "Next \(verb) in \(Formatting.countdownMinutes(to: move.announceAt, now: now))."
                : "Next \(verb) any moment."
        } else if s.paused {
            next = "Cruise control is paused."
        } else {
            next = "Cruise control is off."
        }
        return "\(posture) \(today) \(next)"
    }
}
