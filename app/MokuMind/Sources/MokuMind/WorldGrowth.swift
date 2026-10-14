import Foundation

/// The growth-point rules, in one place. The brain sums the events; stages come from `ForestStage`.
///
/// - Focus: 1 point per focused minute.
/// - Return: coming back after a short drift earns `clamp(focusMinutesBefore / 10, 0.5, 5)`, where
///   `focusMinutesBefore` is the focus since the previous credited return. It needs at least
///   5 focused minutes, so the bonus never exceeds 10% of the focus that earned it and drifting on
///   purpose can't farm growth.
/// - Long drifts, away time and meetings earn nothing. Nothing is ever taken away.
public enum WorldGrowth {
    public static let pointsPerFocusedMinute: Double = 1
    public static let minReturnPoints: Double = 0.5
    public static let maxReturnPoints: Double = 5
    public static let minFocusMinutesForReturn: Double = 5

    /// Points for coming back after a short drift, or nil when the focus before it was too short to count.
    public static func returnPoints(focusMinutesBefore: Double) -> Double? {
        guard focusMinutesBefore >= minFocusMinutesForReturn else { return nil }
        return min(max(focusMinutesBefore / 10, minReturnPoints), maxReturnPoints)
    }

    /// Splits accumulated focused seconds into whole minutes to credit now and the carry for later.
    public static func creditableMinutes(focusedSeconds: Double) -> (minutes: Int, carrySeconds: Double) {
        guard focusedSeconds >= 60 else { return (0, max(0, focusedSeconds)) }
        let minutes = Int(focusedSeconds / 60)
        return (minutes, focusedSeconds - Double(minutes) * 60)
    }
}
