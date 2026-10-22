import Foundation
import RecorderKit
import UserNotifications

/// The few things worth interrupting somebody for.
///
/// Everything here happens with no screen in front of it -- the overnight run sends the reservations that
/// were waiting, to the recorder and to the television, and finds out how much room is left; the Shortcuts
/// action sends them too -- so a notification is the only way the reader learns of it. What is worth saying
/// of a run, and when it has been said already, is RecorderKit's (`RecorderDriver.tells`, `ToldOnce.after`):
/// here it is posted, under an identifier that says what it takes the place of.
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

    /// What became of the reservations that were waiting for the recorder, as a round with no screen tells it
    /// (`RecorderDriver.tells`), which says whether there is news at all: nothing is posted when nothing
    /// happened, and a reservation refused on an earlier night is not news again, since it is no longer sent
    /// (`PendingQueue.flush`). A round that met silence at a reservation's create says that the reservation is
    /// held, also when nothing else happened, and a round with news says how many are still held from an
    /// earlier one. With a television saved the sentences say which device the reservations went to, by the
    /// rule the strip names it by (`PendingQueue.Outcome.said(withATelevisionSaved:)`).
    static func queueFlushed(_ outcome: PendingQueue.Outcome) async {
        let device = BackgroundWork.televisionSaved() ? outcome.slot.label : nil
        guard let said = RecorderDriver.tells(outcome, naming: device) else { return }
        await post(id: "queue-flushed", title: "送信待ちの予約", body: said)
    }

    /// The queue was not sent, because another recorder than the one it was made for answered and with no
    /// screen nothing is taken up (`RecorderDriver.isTheOneKnown`). Said so that the reader opens the app, and
    /// once: the runs ask for it only when it is news, the stop they told last not having been this one
    /// (`NightFound.heldBack`, `NoScreenTold.heldBackIsNews`). Under the queue's own identifier, so that what
    /// the next round has to tell takes its place.
    static func queueHeldBack() async {
        await post(id: "queue-flushed", title: "送信待ちの予約", body: anotherRecorderAnswered)
    }

    /// What a run with no screen has to tell of the television (`NoScreenNotices`), each under an identifier of its
    /// own: neither takes the place of the recorder's two (`queue-flushed`, `recorderNotYet`) nor of the
    /// other. What became of the queue is replaced by the next run's, as the recorder's is, or taken away when
    /// a run finds that what it said is no longer so (`NoScreenNotices.withdrawsQueue`); a notice of
    /// reservations not yet there stays until one of its kind replaces it or none of the reservations it told
    /// of waits to go, so that the news of a sending does not take away a warning that may still hold.
    ///
    /// That one replaces another is Apple's, for the recorder's notifications as well: "If the identifier
    /// matches a previously delivered notification, the system alerts the user again, replaces the old
    /// notification with the new one, and places the new notification at the top of the list."
    /// (`UNNotificationRequest.init(identifier:content:trigger:)`). So is taking a delivered one away by its
    /// identifier.
    static func television(_ notices: NoScreenNotices) async {
        withdrawTelevision(notices)
        if let queue = notices.queue { await post(id: televisionQueue, title: "送信待ちの予約", body: queue) }
        if let notYet = notices.notYet { await post(id: televisionNotYet, title: "送信待ちの予約", body: notYet) }
    }

    /// Takes away what `notices` says is to go of what the runs with no screen told of the television: by a run
    /// (`television`), or as what was told is forgotten by a registration or the television taken away
    /// (`ToldOnce.withdrawn`).
    static func withdrawTelevision(_ notices: NoScreenNotices) {
        if notices.withdrawsNotYet { withdrawTelevisionNotYet() }
        if notices.withdrawsQueue { withdrawTelevisionQueue() }
    }

    /// Takes away the warning of reservations not yet at the television, once none of them waits: sent since,
    /// or gone with the television taken away.
    static func withdrawTelevisionNotYet() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [televisionNotYet])
    }

    /// Takes away what became of what waited for the television, when it asked for a registration: once one
    /// has been made, the television taken away, or a run with no screen has forgotten the want of one and
    /// has nothing of the queue to say in its place (`NoScreenNotices.withdrawsQueue`). Also when it said that
    /// another device answered, once a registration has been made, the television taken away in between or
    /// not (`ToldOnce.withdrawn`, `ToldOnce.kept`).
    static func withdrawTelevisionQueue() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [televisionQueue])
    }

    /// The recorder's warning of reservations that have not reached it in time, as a run with no screen hands
    /// it over (`NightFound.told`, `NoScreenTold`), and its withdrawal once none of the reservations it told of
    /// waits to go: as the television's (`television`), and under an identifier of its own, so that what became
    /// of the queue (`queue-flushed`) does not take the place of a warning that may still hold. The screens
    /// take it away as well, once a sending or a delete of their own leaves none of those reservations waiting
    /// (`AppModel.forgetTheRecordersWarningOnceSent`), and when the cache is made over to another recorder
    /// (`RecorderHost.cacheMadeOver`).
    static func recorder(notYet: String?, withdraws: Bool) async {
        if withdraws {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [recorderNotYet])
        }
        if let notYet { await post(id: recorderNotYet, title: "送信待ちの予約", body: notYet) }
    }

    /// The identifier of the recorder's warning of reservations not yet there. Not the queue's.
    static let recorderNotYet = "not-yet-sent"

    /// The identifiers of the television's two notifications: what became of what waited for it, and the
    /// warning of reservations not yet there. Neither is the recorder's, nor the other's.
    static let televisionQueue = "tv-queue-flushed"
    static let televisionNotYet = "tv-not-yet-sent"

    /// What the notification of a queue held back says (`queueHeldBack`): the sentence the driver keeps for it.
    static let anotherRecorderAnswered = RecorderDriver.anotherAnsweredWithNoScreen

    /// The line the low-space warning is given at, which the settings name as well.
    static let lowSpaceGB: Double = 50

    /// Warned once per fall below the line, not every night: `warnedLowSpace` holds whether it has been said.
    /// It counts as said only when it could be heard, or allowing notifications afterwards would bring nothing
    /// until the disk had been cleared above the line and filled below it again.
    ///
    /// What is to be done is the recorder's rule (`RecorderDisk.internalSpace`): the line, and once per fall.
    /// Here the mark is read and written and the notice posted. A disk of no size does not come here: the
    /// overnight run reads the free space as the screens do (`RecorderDriver.storage(of:)`), which takes such
    /// an answer for a recorder that will not say, and tells nothing of it; `totalBytes` is handed on and
    /// not looked at.
    ///
    /// `naming` is the internal disk's label, handed in only while a USB disk beside it takes recordings, so that
    /// each of the two notices says which disk it is about. With none it says what it always has.
    static func lowSpace(freeBytes: Int, totalBytes: Int, naming disk: String? = nil,
                         warnBelowGB: Double = lowSpaceGB) async {
        let key = DefaultsKey.warnedLowSpace
        switch RecorderDisk.internalSpace(freeBytes: freeBytes, totalBytes: totalBytes,
                                          warned: UserDefaults.standard.bool(forKey: key), warnBelowGB: warnBelowGB) {
        case .nothing:
            return
        case .roomAgain:
            UserDefaults.standard.set(false, forKey: key)
        case .warn(let freeGB, _):
            guard await mayPost() else { return }
            UserDefaults.standard.set(true, forKey: key)
            await post(id: "low-space", title: "レコーダーの残り容量",
                       body: RecorderDisk.lowSpaceBody(freeGB: freeGB, naming: disk))
        }
    }

    /// The same for the disk in the recorder's USB slot, under an identifier of its own so that neither notice
    /// takes the other's place, and with a mark of its own that says which disk was warned about: another disk
    /// put in the slot, already low, is warned about as well. Said only when it could be heard, as above.
    static func lowSpace(on disk: RecorderDisk, warnBelowGB: Double = lowSpaceGB) async {
        let key = DefaultsKey.warnedLowSpaceOnUSB
        switch usbSpace(disk, marked: UserDefaults.standard.string(forKey: key), warnBelowGB: warnBelowGB) {
        case .nothing:
            return
        case .roomAgain:
            UserDefaults.standard.removeObject(forKey: key)
        case .warn(let freeGB, let mark):
            guard await mayPost() else { return }
            UserDefaults.standard.set(mark, forKey: key)
            await post(id: usbLowSpaceID, title: "レコーダーの残り容量",
                       body: RecorderDisk.lowSpaceBody(freeGB: freeGB,
                                                       naming: RecorderDisk.label(disk.destination, named: disk.name)))
        }
    }

    /// The USB disk's notice's identifier. Not the internal disk's, "low-space", or each would take the other's
    /// place in the notification centre; and the same from one version to the next, so that a notice still shown
    /// from an earlier one is replaced rather than joined.
    static let usbLowSpaceID = "low-space-usb"

    /// What is to be done about the USB disk's space against `marked`, the disk last warned about: the
    /// recorder's rule (`RecorderDisk.usbSpace`), at the line the app warns at unless told another.
    static func usbSpace(_ disk: RecorderDisk, marked: String?,
                         warnBelowGB: Double = lowSpaceGB) -> RecorderDisk.SpaceNotice {
        RecorderDisk.usbSpace(disk, marked: marked, warnBelowGB: warnBelowGB)
    }
}
