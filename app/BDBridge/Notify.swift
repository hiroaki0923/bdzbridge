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

    /// What became of the reservations that were waiting. Nothing is said when nothing happened.
    static func queueFlushed(_ outcome: PendingQueue.Outcome) async {
        guard !outcome.isEmpty else { return }
        var lines: [String] = []
        if let first = outcome.sent.first {
            lines.append(outcome.sent.count == 1
                         ? "「\(first.request.title)」を登録しました"
                         : "「\(first.request.title)」ほか \(outcome.sent.count) 件を登録しました")
        }
        if !outcome.expired.isEmpty { lines.append("\(outcome.expired.count) 件は放送が終わっていました") }
        if !outcome.refused.isEmpty { lines.append("\(outcome.refused.count) 件はレコーダーが受け付けませんでした") }
        await post(id: "queue-flushed", title: "送信待ちの予約", body: lines.joined(separator: "。"))
    }

    /// The line the low-space warning is given at, which the settings name as well.
    static let lowSpaceGB: Double = 50

    /// Warned once per fall below the line, not every night: `warnedLowSpace` holds whether it has been said.
    ///
    /// It counts as said only when it could be heard. Marking it said while notifications were not allowed
    /// spent the warning on nobody, and allowing them afterwards brought nothing until the disk had been cleared
    /// above the line and filled below it again.
    static func lowSpace(freeBytes: Int, totalBytes: Int, warnBelowGB: Double = lowSpaceGB) async {
        let key = "warnedLowSpace"
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
