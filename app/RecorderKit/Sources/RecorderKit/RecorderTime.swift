import Foundation

/// The recorder works in Japan Standard Time throughout, and rejects a start time whose offset is written
/// `+0900` instead of `+09:00`, so the formats are pinned here rather than left to a shared formatter.
public enum RecorderTime {
    public static let timeZone = TimeZone(identifier: "Asia/Tokyo")!

    /// `scheduledStartDateTime` as the recorder accepts it.
    public static func format(_ date: Date) -> String {
        formatter("yyyy-MM-dd'T'HH:mm:ssXXXXX").string(from: date)
    }

    /// Start times come back with either spelling of the offset, depending on the action.
    public static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in ["yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss"] {
            if let date = formatter(pattern).date(from: trimmed) { return date }
        }
        return nil
    }

    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter
    }
}
