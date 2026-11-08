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
        送信待ちの録画予約を、レコーダーやテレビに送ります。自宅の Wi-Fi に接続したときのオートメーションに使えます。\
        送るものがないときは、レコーダーにもテレビにも何もしません。
        """)

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Beside the recorder's, whose waking can take a minute: not after it.
        async let television = BackgroundWork.sendToTheTelevisionNow()
        let sending = await BackgroundWork.sendWaiting()
        let said = BackgroundWork.saying(sending, beside: await television, televisionSaved: BackgroundWork.televisionSaved())
        return .result(dialog: IntentDialog(stringLiteral: said))
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
