import AppIntents

/// The Shortcuts action that sends the reservations waiting on this phone.
///
/// Made for an automation on joining the home Wi-Fi, which is the only thing that can have the queue sent on
/// arriving home: iOS wakes no app because a network has come, and without it the queue waits for the app to
/// be opened, or for the overnight run. Since iOS 17 such an automation can run without asking. It runs in
/// the background; see `BackgroundWork.sendWaiting` for what it does and does not do.
struct SendWaitingIntent: AppIntent {
    static let title: LocalizedStringResource = "送信待ちの予約を送る"
    static let description = IntentDescription("""
        端末にためている録画予約をレコーダーに送ります。自宅の Wi-Fi に接続したときのオートメーションに使えます。\
        送るものがないときは、レコーダーには何もしません。
        """)

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let sending = await BackgroundWork.sendWaiting()
        let said = Self.saying(sending, televisionSaved: BackgroundWork.televisionSaved)
        return .result(dialog: IntentDialog(stringLiteral: said))
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
