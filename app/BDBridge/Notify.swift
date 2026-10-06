import Foundation
import RecorderKit
import UserNotifications

/// The few things worth interrupting somebody for.
///
/// Everything here happens with no screen in front of it -- the overnight run sends the reservations that
/// were waiting, to the recorder and to the television, and finds out how much room is left; the Shortcuts
/// action sends them too -- so a notification is the only way the reader learns of it.
///
/// Permission comes in two steps. Once the app has reached a real recorder, it asks for provisional permission,
/// which shows no dialog and lets the notifications reach Notification Centre quietly, where the reader can
/// keep them or turn them off. So the low-space warning reaches a reader who never queues a reservation, and
/// nothing lands on the system's local network question, which comes up around the first connect. The dialog
/// itself waits for the first queued reservation, or for the reader to ask for it in the settings.
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
    /// Centre, so this asks for them to be shown properly. Returns whether notifications may be sent. No
    /// sound is asked for, since nothing here plays one.
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
    /// Without a sound, and passive, which does not light the screen either: the overnight run posts soon after
    /// two in the morning, and nothing here needs an answer before the reader picks the phone up anyway.
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
    /// With a television saved it says which device the reservations went to (`PendingQueue.Outcome.said`).
    static func queueFlushed(_ outcome: PendingQueue.Outcome) async {
        guard !outcome.isEmpty,
              let said = outcome.said(withATelevisionSaved: BackgroundWork.televisionSaved()) else { return }
        await post(id: "queue-flushed", title: "送信待ちの予約", body: said)
    }

    /// The queue was not sent, because another recorder than the one it was made for answered and with no
    /// screen nothing is taken up (`RecorderDriver.isTheOneKnown`). Said so that the reader opens the app;
    /// under the queue's own identifier, so that it is one entry however many nights it takes.
    static func queueHeldBack() async {
        await post(id: "queue-flushed", title: "送信待ちの予約", body: anotherRecorderAnswered)
    }

    /// What a run with no screen has to tell of the television (`TVNotices`), each under an identifier of its
    /// own: neither takes the place of the recorder's (`queue-flushed`) nor of the other. What became of the
    /// queue is replaced by the next run's, as the recorder's is; a notice of reservations not yet there stays
    /// until one of its kind replaces it or none of the reservations it told of waits to go, so that the news
    /// of a sending does not take away a warning that may still hold.
    ///
    /// That one replaces another is Apple's, for the recorder's notification as well: "If the identifier
    /// matches a previously delivered notification, the system alerts the user again, replaces the old
    /// notification with the new one, and places the new notification at the top of the list."
    /// (`UNNotificationRequest.init(identifier:content:trigger:)`). So is taking a delivered one away by its
    /// identifier.
    static func television(_ notices: TVNotices) async {
        if notices.withdrawsNotYet { withdrawTelevisionNotYet() }
        if let queue = notices.queue { await post(id: televisionQueue, title: "送信待ちの予約", body: queue) }
        if let notYet = notices.notYet { await post(id: televisionNotYet, title: "送信待ちの予約", body: notYet) }
    }

    /// Takes away the warning of reservations not yet at the television, once none of them waits: sent since,
    /// or gone with the television taken away.
    static func withdrawTelevisionNotYet() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [televisionNotYet])
    }

    /// Takes away what became of what waited for the television, when it asked for a registration: once one
    /// has been made, or the television taken away.
    static func withdrawTelevisionQueue() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [televisionQueue])
    }

    /// The identifiers of the television's two notifications: what became of what waited for it, and the
    /// warning of reservations not yet there. Neither is the recorder's, nor the other's.
    static let televisionQueue = "tv-queue-flushed"
    static let televisionNotYet = "tv-not-yet-sent"

    /// What that notification says, and the Shortcuts action when it is run by hand. The state the reader
    /// will find, in the words used when the recorder could not be reached.
    static let anotherRecorderAnswered = "これまでとは別のレコーダーが応答したため、送信待ちの予約はそのまま残しています。"
        + "アプリを開いて確かめてください。"

    /// The line the low-space warning is given at, which the settings name as well.
    static let lowSpaceGB: Double = 50

    /// Warned once per fall below the line, not every night: `warnedLowSpace` holds whether it has been said.
    /// It counts as said only when it could be heard, or allowing notifications afterwards would bring nothing
    /// until the disk had been cleared above the line and filled below it again.
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
