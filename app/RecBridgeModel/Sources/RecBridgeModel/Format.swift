import Foundation
import RecorderKit

/// Formatters live here because building one is not free and these are used down long lists.
public enum Format {
    public static let time: DateFormatter = formatter("HH:mm")
    public static let day: DateFormatter = formatter("M/d(E)")
    public static let dateTime: DateFormatter = formatter("M/d(E) HH:mm")

    /// When something this app did last happened: "12分前" while it is recent, and the date and time once it is
    /// older than a day. Broadcast times are always Japanese time, wherever the reader is standing; these are
    /// things that happened to this phone, and whether they were recent is a question with no time zone in it.
    public static func when(_ date: Date, from now: Date = Date()) -> String {
        guard now.timeIntervalSince(date) < 24 * 3600 else { return dateTime.string(from: date) }
        return date.formatted(.relative(presentation: .named).locale(Locale(identifier: "ja_JP")))
    }

    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = RecorderTime.timeZone
        formatter.dateFormat = pattern
        return formatter
    }

    /// A count as a screen's own text writes a number put into it, with the reader's grouping of digits (1,234):
    /// for the words a screen drew that way before they were the model's.
    public static func count(_ number: Int) -> String {
        String.localizedStringWithFormat("%lld", number)
    }

    public static func duration(_ seconds: Int) -> String {
        "\(max(0, seconds) / 60)分"
    }

    /// A size in bytes on `device`, as that device's screen counts a GB (`Gigabytes`), written `3.0 GB`.
    public static func gigabytes(_ bytes: Int, on device: DeviceSlot) -> String {
        gigabytes(Gigabytes.of(bytes: bytes, on: device))
    }

    /// A size `device` gave in its megabytes, as a recording's is.
    public static func gigabytes(megabytes: Int, on device: DeviceSlot) -> String {
        gigabytes(Gigabytes.of(megabytes: megabytes, on: device))
    }

    /// A recording's size, as its own device shows it.
    public static func size(of title: RecordedTitle) -> String? {
        title.sizeMB.map { gigabytes(megabytes: $0, on: title.device) }
    }

    /// Gigabytes counted already, as a sum of recordings is.
    public static func gigabytes(_ count: Double) -> String {
        String(format: "%.1f GB", count)
    }

    /// How full a disk of `device` is, in the words the television's USB disk was first given and the recorder's
    /// disks share: both sizes, or that a disk is there and has not said how full, or that it is not there.
    public static func storage(mounted: Bool, freeBytes: Int?, totalBytes: Int?, on device: DeviceSlot) -> String {
        guard mounted else { return "つながっていません" }
        guard let freeBytes, let totalBytes else { return "つながっています" }
        return "残り \(gigabytes(freeBytes, on: device)) / \(gigabytes(totalBytes, on: device))"
    }
}

extension String {
    /// The sentence as a body says it -- a red line, an alert's text, a footer, a notification, the Shortcuts
    /// action's answer, a waiting row's reason -- each of its lines ended with 。 where it has none. The
    /// sentences the strip says as well, or that are joined to others with 。 (`ScalarClient.diskNotFound`, the
    /// queue's reports, the devices' error descriptions), are written without one, so that a join does not make
    /// 。。: the full stop is put on here, where one is shown on its own.
    public var asABody: String {
        split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.isEmpty || ["。", "？", "！"].contains(where: line.hasSuffix) ? String(line) : line + "。"
        }.joined(separator: "\n")
    }
}
