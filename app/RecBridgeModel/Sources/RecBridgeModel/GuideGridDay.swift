import Foundation
import RecorderKit

/// One broadcast day of the guide laid out as a grid, time down and stations across: which stations get a column,
/// where a programme sits in the day in minutes, where the grid opens, and the words that name an hour. Points and
/// scrolling are the screen's; this is what the day is. Worked out once for a day and its programmes, not as the
/// grid draws.
public struct GuideGridDay: Sendable {
    /// A station and what it has on, in the day's order.
    public struct Column: Sendable {
        public let channel: Channel
        public let programs: [GuideProgramRow]
    }

    /// Only the stations with a programme that day, in the order of `channels`. That leaves out the sub-channels
    /// that only mirror their parent.
    public let columns: [Column]
    /// The day's first moment, four in the morning.
    public let dayStart: Date

    public init(channels: [Channel], programs: [GuideProgramRow], day: Date) {
        let byService = Dictionary(grouping: programs, by: \.serviceID)
        columns = channels.compactMap { channel in
            guard let programs = byService[channel.serviceID], !programs.isEmpty else { return nil }
            return Column(channel: channel, programs: programs)
        }
        dayStart = GuideStore.dayRange(containing: day).start
    }

    /// A day's length in minutes.
    public static let minutes = 1440.0
    /// The minutes of lead-in that a grid opened at a time leaves above it.
    public static let leadIn = 15.0

    /// What a grid opened again for the same day and the same number of columns does not start over for.
    public var key: String { "\(Int(dayStart.timeIntervalSince1970))-\(columns.count)" }

    /// The minutes a programme takes, from the day's start, as the guide file has them: not cut to the day, and
    /// never ending before it starts, since the end is stored as it came and nothing holds it after the start.
    public func span(of program: GuideProgramRow) -> ClosedRange<Double> {
        let start = program.start.timeIntervalSince(dayStart) / 60
        return start...(start + Double(max(0, program.durationSec)) / 60)
    }

    /// Where a programme starts in the day, in minutes, and not before the day does.
    public func top(of program: GuideProgramRow) -> Double {
        max(0, program.start.timeIntervalSince(dayStart) / 60)
    }

    /// How long a programme is inside the day, in minutes: cut at both ends.
    public func shown(of program: GuideProgramRow) -> Double {
        let start = max(program.start, dayStart)
        let end = min(program.end, dayStart.addingTimeInterval(Self.minutes * 60))
        return end.timeIntervalSince(start) / 60
    }

    /// Minutes into the day at `now`, or nil when `now` is outside it.
    public func nowMinute(at now: Date) -> Double? {
        let minutes = now.timeIntervalSince(dayStart) / 60
        return (0..<Self.minutes).contains(minutes) ? minutes : nil
    }

    /// The minute the grid opens at: the time the reader pinned (`HH:mm`, see `DefaultsKey.guideOpenAt`), otherwise
    /// now when the day is today, otherwise the top of the day.
    public func openingMinute(pinned: String, now: Date) -> Double {
        GuideStore.minuteOfTheBroadcastDay(pinned) ?? nowMinute(at: now) ?? 0
    }

    /// The number written beside the `index`th hour of the day, which starts at four.
    public static func hourLabel(_ index: Int) -> Int {
        (index + GuideStore.dayStartHour) % 24
    }
}

/// How finely the grid's time axis is drawn, in points a minute.
public enum GuideGridScale {
    public static let standard = 3.0
    public static let smallest = 1.5
    public static let largest = 8.0
    /// What one press of a zoom button multiplies or divides by.
    public static let step = 1.4

    public static func clamped(_ scale: Double) -> Double {
        min(largest, max(smallest, scale))
    }

    public static func canShrink(_ scale: Double) -> Bool { scale > smallest }
    public static func canGrow(_ scale: Double) -> Bool { scale < largest }
}
