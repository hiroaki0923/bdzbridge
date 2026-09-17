import Foundation
import RecorderKit
import UserNotifications

/// The few things worth interrupting somebody for.
///
/// Everything here happens with no screen in front of it -- the overnight run sends the reservations that
/// were waiting, and finds out how much room is left -- so a notification is the only way the reader learns
/// of it. Permission is asked for the first time a reservation is queued, which is the moment it starts to
/// matter, rather than at launch when it would mean nothing.
enum Notify {
    /// Asks, unless the reader has already answered. Returns whether notifications may be sent.
    @discardableResult
    static func askIfNeeded() async -> Bool {
        let centre = UNUserNotificationCenter.current()
        let settings = await centre.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return (try? await centre.requestAuthorization(options: [.alert, .sound])) ?? false
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    /// Posts one straight away. Silent when permission was never given, which is the reader's answer.
    private static func post(id: String, title: String, body: String) async {
        let centre = UNUserNotificationCenter.current()
        guard await centre.notificationSettings().authorizationStatus != .notDetermined else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // nil trigger: now, which is when the thing it is about happened
        try? await centre.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
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

    /// Warned once per fall below the line, not every night: `remembering` holds whether it has been said.
    static func lowSpace(freeBytes: Int, totalBytes: Int, warnBelowGB: Double = 50) async {
        let key = "warnedLowSpace"
        let freeGB = Double(freeBytes) / 1e9
        let warned = UserDefaults.standard.bool(forKey: key)
        if freeGB >= warnBelowGB {
            if warned { UserDefaults.standard.set(false, forKey: key) }   // room again; worth saying next time
            return
        }
        guard !warned else { return }
        UserDefaults.standard.set(true, forKey: key)
        await post(id: "low-space", title: "レコーダーの残り容量",
                   body: String(format: "残り %.0f GB です。古い録画を整理するか、録画モードを見直してください。", freeGB))
    }
}
