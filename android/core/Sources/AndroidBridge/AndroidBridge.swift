import Foundation
import RecorderKit

// What the Android screens are handed: rows already worded and timed as the iOS app words them, so that the Kotlin
// side only lays them out. Each call names the recorder by its address, or the demo's invented recorder; nothing here
// wakes a recorder or writes to one.

/// A recorder as it describes itself.
public struct RecorderInfo {
    public var host: String
    public var name: String
    public var model: String
}

/// A device the search found: `kind` is `recorder` or `television`.
public struct FoundDevice {
    public var host: String
    public var kind: String
    public var name: String
}

/// One reservation, worded.
public struct ReservationRow {
    public var id: String
    public var title: String
    /// `11/8(日) 21:00`, Japan time.
    public var date: String
    /// `21:00〜21:54 · 54分`.
    public var span: String
    /// The station's kind and number until the guide names it, the mode, and the repeat.
    public var details: String
    public var recording: Bool
    public var conflict: Bool
}

/// One recording, worded.
public struct RecordingRow {
    public var id: String
    public var title: String
    public var date: String
    public var details: String
    public var isNew: Bool
    public var protected: Bool
    public var recording: Bool
}

/// What went wrong, in the words the iOS app says it in (`DeviceError.explanation`): it reaches Kotlin as the
/// exception's message.
public enum BridgeError: Error, CustomStringConvertible {
    case failed(String)

    public var description: String {
        switch self {
        case .failed(let said): said
        }
    }

    static func from(_ error: any Error) -> BridgeError {
        .failed((error as? any DeviceError)?.explanation ?? String(describing: error))
    }
}

/// The address the demo's recorder answers at: one reserved for documentation, never a real host.
public func demoHost() -> String { DemoRecorder.host }

func client(_ host: String) -> RecorderClient {
    host == DemoRecorder.host ? RecorderClient(host: host, transport: DemoRecorder()) : RecorderClient(host: host)
}

/// The recorder at `host`, as it describes itself.
public func describeRecorder(host: String) async throws -> RecorderInfo {
    do {
        let description = try await client(host).describe()
        return RecorderInfo(host: description.host, name: description.friendlyName, model: description.model)
    } catch {
        throw BridgeError.from(error)
    }
}

/// The recorder's reservations, soonest first.
public func reservations(host: String) async throws -> [ReservationRow] {
    do {
        let rows = try await client(host).reservations()
        return rows.sorted { $0.start < $1.start }.map(Wording.row)
    } catch {
        throw BridgeError.from(error)
    }
}

/// The recorder's recordings on its own disk, newest first.
public func recordings(host: String) async throws -> [RecordingRow] {
    do {
        let rows = try await client(host).allTitles()
        return rows.sorted { $0.start > $1.start }.map(Wording.row)
    } catch {
        throw BridgeError.from(error)
    }
}

/// The app's one search, レコーダーとテレビを探す, over the subnet this device is on: every address asked for a
/// recorder's description and a television's interface at once, which change nothing.
public func searchDevices() async -> [FoundDevice] {
    let found = await DeviceSearch.scan(hosts: LocalNetwork.hostsToScan(), transport: URLSessionTransport())
    return found.recorders.map { FoundDevice(host: $0.host, kind: "recorder", name: $0.friendlyName) }
        + found.televisions.map { FoundDevice(host: $0.host, kind: "television", name: $0.model) }
}

enum Wording {
    static let day: DateFormatter = formatter("M/d(E) HH:mm")
    static let time: DateFormatter = formatter("HH:mm")
    static let dayOnly: DateFormatter = formatter("M/d(E)")

    static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = RecorderTime.timeZone
        formatter.dateFormat = pattern
        return formatter
    }

    static func station(_ broadcastingType: Int, _ serviceID: Int) -> String {
        let kind = Codes.broadcasting(code: broadcastingType).flatMap { Codes.broadcastingShortLabel[$0] } ?? "?"
        return "\(kind) \(serviceID)"
    }

    static func row(_ reservation: Reservation) -> ReservationRow {
        let mode = Codes.quality(code: reservation.qualityCode).map { Codes.qualityLabel[$0] ?? $0 }
        // Said only when it repeats: a line of details has no room for the absence of something.
        let repeating = Codes.repeatName(code: reservation.repeatCode).flatMap { $0 == "none" ? nil : Codes.repeatLabel[$0] }
        let details = [station(reservation.broadcastingType, reservation.serviceID), mode, repeating]
            .compactMap { $0 }.joined(separator: " · ")
        return ReservationRow(id: reservation.id, title: reservation.title, date: day.string(from: reservation.start),
                              span: "\(time.string(from: reservation.start))〜\(time.string(from: reservation.end))"
                                  + " · \(reservation.durationSec / 60)分",
                              details: details, recording: reservation.recording, conflict: reservation.conflict)
    }

    static func row(_ title: RecordedTitle) -> RecordingRow {
        var parts = [title.channelName ?? station(title.broadcastingType, title.serviceID), "\(title.durationSec / 60)分"]
        if let size = title.sizeMB { parts.append(String(format: "%.1f GB", Gigabytes.of(megabytes: size, on: title.device))) }
        if let mode = title.qualityName { parts.append(Codes.qualityLabel[mode] ?? mode) }
        return RecordingRow(id: title.id, title: title.title, date: day.string(from: title.start),
                            details: parts.joined(separator: " · "), isNew: title.isNew,
                            protected: title.protected, recording: title.recording)
    }
}

// MARK: - the main actor

/// Comes back once a job has run on the main actor: much of RecorderKit, and the app's model, is isolated to it, and
/// on Android nothing runs the main queue unless the app runs it (`runWhatWaitsOnTheMainQueue`).
public func mainActorCheck() async -> String {
    await MainActor.run { Thread.isMainThread ? "main actor ran on the main thread" : "main actor ran off the main thread" }
}
