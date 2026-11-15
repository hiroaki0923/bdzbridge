import Foundation
import RecorderKit

/// The word a programme carries in the guide when the reader has reserved it, and whether it is said in red.
/// A reservation the device holds wins over one still waiting on the phone, and the recorder's over the
/// television's is settled before it gets here.
public struct GuideMark: Sendable, Equatable {
    public let word: String
    /// Red for what is being recorded and for a waiting reservation the device refused; the rest are orange.
    public let isRed: Bool

    public init?(reservation: Reservation?, pending: PendingReservation?) {
        if let reservation {
            word = reservation.recording ? "録画中" : "予約"
            isRed = reservation.recording
        } else if let pending {
            word = "送信待ち"
            isRed = pending.problem != nil
        } else {
            return nil
        }
    }
}

extension GuideProgramRow {
    /// On the air at `now`.
    public func isOnAir(at now: Date) -> Bool { start <= now && now < end }

    /// Over at `now`.
    public func hasEnded(at now: Date) -> Bool { end <= now }

    /// How much of the programme has gone at `now`, from 0 to 1; 0 for one that is not on air or has no length.
    public func elapsed(at now: Date) -> Double {
        guard isOnAir(at: now), durationSec > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(start) / Double(durationSec)))
    }

    /// What VoiceOver reads for a programme in the grid: the station, when and for how long, the title, whether it
    /// is on the air, and the mark.
    public func spoken(mark: GuideMark?, at now: Date) -> String {
        var parts = [serviceName, "\(Format.time.string(from: start))から\(Format.duration(durationSec))", title]
        if isOnAir(at: now) { parts.append("放送中") }
        if let mark { parts.append(mark.word) }
        return parts.joined(separator: "、")
    }
}

/// The accent colour of an ARIB level-1 genre, the same mapping the web app uses, as the fractions the screens
/// make their colour of.
public enum GuideGenre {
    public struct Accent: Sendable, Equatable {
        public let red: Double
        public let green: Double
        public let blue: Double
    }

    /// Nil for a genre that has none, which the screen draws as a separator.
    public static func accent(level1: Int?) -> Accent? {
        switch level1 {
        case 0: Accent(red: 0.56, green: 0.56, blue: 0.58)
        case 1: Accent(red: 0.20, green: 0.78, blue: 0.35)
        case 2: Accent(red: 1.00, green: 0.58, blue: 0.00)
        case 3: Accent(red: 1.00, green: 0.18, blue: 0.33)
        case 4: Accent(red: 0.69, green: 0.32, blue: 0.87)
        case 5: Accent(red: 1.00, green: 0.80, blue: 0.00)
        case 6: Accent(red: 0.00, green: 0.48, blue: 1.00)
        case 7: Accent(red: 0.35, green: 0.78, blue: 0.98)
        case 8: Accent(red: 0.19, green: 0.69, blue: 0.78)
        case 9: Accent(red: 0.64, green: 0.52, blue: 0.37)
        case 10: Accent(red: 0.35, green: 0.34, blue: 0.84)
        case 11: Accent(red: 0.00, green: 0.78, blue: 0.75)
        default: nil
        }
    }
}
