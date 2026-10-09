import Foundation

extension Duration {
    /// `m:ss`, or `h:mm:ss` from one hour up. Negative and non-finite values show as zero.
    var clockString: String {
        let value = seconds
        let total = value.isFinite ? max(0, Int(value)) : 0
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
