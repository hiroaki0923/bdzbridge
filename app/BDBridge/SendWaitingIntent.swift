import AppIntents
import RecorderKit

/// The Shortcuts action that sends the reservations waiting on this phone, to the recorder and to the
/// television.
///
/// Made for an automation on joining the home Wi-Fi, which is the only thing that can have the queue sent on
/// arriving home: iOS wakes no app because a network has come, and without it the queue waits for the app to
/// be opened, or for the overnight run. Since iOS 17 such an automation can run without asking. It runs in
/// the background; see `BackgroundWork.sendWaiting` and `BackgroundWork.sendToTheTelevisionNow` for what it
/// does and does not do.
struct SendWaitingIntent: AppIntent {
    static let title: LocalizedStringResource = "送信待ちの予約を送る"
    static let description = IntentDescription("""
        端末にためている録画予約を、レコーダーやテレビに送ります。自宅の Wi-Fi に接続したときのオートメーションに使えます。\
        送るものがないときは、レコーダーにもテレビにも何もしません。
        """)

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Beside the recorder's, whose waking can take a minute: not after it.
        async let television = BackgroundWork.sendToTheTelevisionNow()
        let sending = await BackgroundWork.sendWaiting()
        let said = Self.saying(sending, beside: await television, televisionSaved: BackgroundWork.televisionSaved())
        return .result(dialog: IntentDialog(stringLiteral: said))
    }

    /// What the action says with the television's sending beside the recorder's. With none -- no television
    /// saved, or the demo -- it is `saying(_:televisionSaved:)`, as it has always been. With one: the
    /// recorder's sentence as that gives it with a television saved, then the television's
    /// (`TVDriver.says`); a device with nothing to say is left out, and with neither, 「送信待ちの予約はありません。」
    /// once. The television has nothing to say only when nothing waited for it, or another sending took what
    /// did. The recorder has nothing to say in a home with no recorder, with nothing waiting for it, and after a
    /// sending with nothing in it that was not cut short. Two sentences are joined with 。, each without its own
    /// at the end; one is said as it is.
    static func saying(_ sending: BackgroundWork.Sending, beside television: NoScreenSending?,
                       televisionSaved: Bool) -> String {
        guard let television else { return saying(sending, televisionSaved: televisionSaved) }
        var recorders: String?
        switch sending {
        case .noRecorder, .nothingWaiting:
            break
        case .sent(let outcome) where outcome.said(withATelevisionSaved: true) == nil && !outcome.interrupted:
            break
        default:
            recorders = saying(sending, televisionSaved: true)
        }
        let halves = [recorders, TVDriver.says(television, naming: DeviceSlot.tv.label)].compactMap { $0 }
        guard halves.count > 1 else { return halves.first ?? "送信待ちの予約はありません。" }
        return halves.map { $0.hasSuffix("。") ? String($0.dropLast()) : $0 }.joined(separator: "。")
    }

    /// What the action says when it is run by hand. An automation that runs by itself shows nothing of it,
    /// which is why what was sent is also a notification, as it is from the overnight run.
    ///
    /// `televisionSaved`: the reader has a television beside the recorder, and what became of the queue then
    /// says which device it went to (`PendingQueue.Outcome.said`). Handed in, since nothing here has a model
    /// to ask; left out, it is a home with a recorder alone, whose sentences are as they have always been.
    static func saying(_ sending: BackgroundWork.Sending, televisionSaved: Bool = false) -> String {
        switch sending {
        case .demo:
            "サンプルデータの表示中は送りません。"
        case .noRecorder:
            "レコーダーが設定されていません。"
        case .nothingWaiting:
            "送信待ちの予約はありません。"
        case .unreachable:
            "レコーダーに接続できませんでした。送信待ちの予約はそのまま残しています。"
        case .anotherRecorder:
            Notify.anotherRecorderAnswered
        case .sent(let outcome):
            outcome.said(withATelevisionSaved: televisionSaved)
                ?? (outcome.interrupted
                    ? "途中でレコーダーの応答がなくなりました。送信待ちの予約はそのまま残しています。"
                    : "送信待ちの予約はありません。")
        }
    }
}

/// Puts the action in the Shortcuts app without anybody having to find it first.
struct BDBridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SendWaitingIntent(),
                    phrases: ["\(.applicationName)で送信待ちの予約を送る"],
                    shortTitle: "送信待ちの予約を送る",
                    systemImageName: "tray.and.arrow.up")
    }
}
