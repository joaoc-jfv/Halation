import Foundation

/// Keeps the display awake while a video plays.
@MainActor
protocol SleepPrevention: AnyObject {
    func setActive(_ active: Bool)
}

@MainActor
final class SystemSleepPrevention: SleepPrevention {
    private var activity: (any NSObjectProtocol)?

    func setActive(_ active: Bool) {
        if active, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
                reason: "Playing a video"
            )
        } else if !active, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
