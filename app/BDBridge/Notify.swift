import Foundation
import RecorderKit
import UserNotifications

/// The few things worth interrupting somebody for.
///
/// Everything here happens with no screen in front of it -- the overnight run sends the reservations that
/// were waiting, and finds out how much room is left -- so a notification is the only way the reader learns
/// of it.
///
/// Permission comes in two steps. Once the app has reached a real recorder, it asks for provisional
/// permission, which shows no dialog and lets the notifications reach Notification Centre quietly, where
/// the reader can keep them or turn them off. Asking only when a reservation was queued, as the app used
/// to, meant that somebody who only ever used it at home was never asked, and the low-space warning -- the
/// one thing here that matters to everybody -- never reached them. No dialog also means it cannot land on
/// top of the system's local network question, which comes up around the first connect. The dialog itself
/// waits for the first queued reservation, the moment being told starts to matter, or for the reader to
/// ask for it in the settings.
enum Notify {
    /// Provisional permission, the first time and only then: no dialog, see above. Nothing is asked of a
    /// reader who has already answered, whichever way.
    static func allowQuietly() async {
        let centre = UNUserNotificationCenter.current()
        guard await centre.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await centre.requestAuthorization(options: [.alert, .provisional])
    }

    /// Asks with the system's dialog, unless the reader has already answered. Provisional permission is not
    /// an answer: the reader has not been asked anything, and the notifications only reach Notification
    /// Centre, so this asks for them to be shown properly. Returns whether notifications may be sent.
    ///
    /// No sound is asked for, since nothing here plays one.
    @discardableResult
    static func askIfNeeded() async -> Bool {
        let centre = UNUserNotificationCenter.current()
        switch await centre.notificationSettings().authorizationStatus {
        case .notDetermined, .provisional:
            _ = try? await centre.requestAuthorization(options: [.alert])
            return await mayPost()
        case .authorized, .ephemeral:
            return true
        default:
            return false
        }
    }

    /// Where permission stands, for the settings to say.
    static func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Whether a notification posted now would reach the reader at all, quietly included.
    private static func mayPost() async -> Bool {
        switch await status() {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    /// Posts one straight away. Silent when permission was never given, which is the reader's answer.
    ///
    /// Without a sound, and passive, which does not light the screen either: everything here is posted by
    /// the overnight run, soon after two in the morning, and none of it needs an answer before the reader
    /// picks the phone up anyway. It waits in Notification Centre until then.
    private static func post(id: String, title: String, body: String) async {
        guard await mayPost() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.interruptionLevel = .passive
        // nil trigger: now, which is when the thing it is about happened
        try? await UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// What became of the reservations that were waiting. Nothing is said when nothing happened, and a
    /// reservation refused on an earlier night is not news again: it is no longer sent (`PendingQueue.flush`).
    static func queueFlushed(_ outcome: PendingQueue.Outcome) async {
        guard !outcome.isEmpty, let summary = outcome.summary else { return }
        await post(id: "queue-flushed", title: "送信待ちの予約", body: summary)
    }

    /// The line the low-space warning is given at, which the settings name as well.
    static let lowSpaceGB: Double = 50

    /// Warned once per fall below the line, not every night: `warnedLowSpace` holds whether it has been said.
    ///
    /// It counts as said only when it could be heard. Marking it said while notifications were not allowed
    /// spent the warning on nobody, and allowing them afterwards brought nothing until the disk had been cleared
    /// above the line and filled below it again.
    ///
    /// A disk of no size is a recorder that has not said how full it is, not one that is full: nothing is
    /// said about it, and whether the warning has been given is left as it was.
    static func lowSpace(freeBytes: Int, totalBytes: Int, warnBelowGB: Double = lowSpaceGB) async {
        guard totalBytes > 0 else { return }
        let key = DefaultsKey.warnedLowSpace
        let freeGB = Double(freeBytes) / 1e9
        let warned = UserDefaults.standard.bool(forKey: key)
        if freeGB >= warnBelowGB {
            if warned { UserDefaults.standard.set(false, forKey: key) }   // room again; worth saying next time
            return
        }
        guard !warned, await mayPost() else { return }
        UserDefaults.standard.set(true, forKey: key)
        await post(id: "low-space", title: "レコーダーの残り容量",
                   body: String(format: "残り %.0f GB です。古い録画を整理するか、録画モードを見直してください。", freeGB))
    }
}

extension PendingQueue.Outcome {
    /// What became of the queue, in a few short sentences: the body of the overnight notification, and the
    /// line the app shows when it sent the queue itself. nil when there is nothing to say.
    var summary: String? {
        var lines: [String] = []
        if !sent.isEmpty {
            lines.append("送信待ちだった\(Self.naming(sent))を登録しました")
        }
        if !expired.isEmpty {
            lines.append("\(Self.naming(expired))は放送が終わっていたため、送らずに削除しました")
        }
        if !refused.isEmpty {
            lines.append("\(Self.naming(refused))はレコーダーが受け付けませんでした。理由は予約タブにあります")
        }
        if !deferred.isEmpty {
            lines.append("\(Self.naming(deferred))は送れなかったため、次の機会にもう一度送ります")
        }
        // Only as the end of something else: an interruption before anything went is the app going offline,
        // which the strip already says.
        if interrupted, !lines.isEmpty {
            lines.append("途中でレコーダーの応答がなくなったため、残りは次につながったときに送ります")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "。")
    }

    /// The first by name, and how many more. "ほか" counts the others, not all of them.
    private static func naming(_ reservations: [PendingReservation]) -> String {
        guard let first = reservations.first else { return "" }
        return reservations.count == 1 ? "「\(first.request.title)」"
            : "「\(first.request.title)」ほか \(reservations.count - 1) 件"
    }
}
