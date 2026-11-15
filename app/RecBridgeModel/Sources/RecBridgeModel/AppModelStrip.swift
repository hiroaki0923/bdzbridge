import Foundation
import RecorderKit

extension AppModel {
    /// What the strip at the top of a screen says: one thing at a time. Which one is chosen here and not in
    /// the view that draws it, so that the order can be held by a test, and so are its words and its button
    /// (`says`, `offer`); the view draws them with its own icons.
    public enum Strip: Equatable, Sendable {
        /// Something is under way with a device, and this is its line.
        case busy(String)
        /// Another recorder answered where the last one had been (`anotherTookOver`).
        case anotherTookOver
        /// What became of what was waiting (`queueReport`). `inFull`: not cut at three lines. With a
        /// television saved, what a sending to one says can end with what making a reservation did to
        /// another, which is the last thing a cut would leave.
        case report(String, inFull: Bool)
        /// Everything on screen is invented.
        case demo
        /// The local network permission stands between the app and the recorder, or the television.
        case blocked
        /// The recorder was given every chance and did not answer.
        case recorderGaveUp
        /// The television answers, and takes nothing until the app is registered with it again.
        case tvNeedsPairing
        /// The television was given up on.
        case tvGaveUp
        /// The disk the television records to is away, and a reservation waits for it to come back
        /// (`tvWaitsForItsDisk`).
        case tvDiskAway
    }

    /// The first of these that holds, or nil when the strip has nothing to say. `inSheet` for the strip at
    /// the top of a sheet, which leaves the demo's line to the screen underneath
    /// (`RecorderActivityBar.inSheet`).
    ///
    /// That another recorder took over is said only while connected: the line says the lists were read
    /// again, which they were not if that recorder went quiet before it had been asked, and then the strip
    /// offers the reconnect instead and says this after it. It is ahead of the queue's line, which says
    /// what became of the reservations waiting under the same change of recorder and is read better
    /// knowing of it. The queue's line is ahead of the reconnect in turn: a sending the recorder walked
    /// out of says which were sent, and the strip goes back to offering the reconnect once that is closed.
    /// The television's own lines come after everything about the recorder, and only when one is saved.
    /// Its disk is the last of them: nothing went wrong that the reader is to put right here, and a
    /// television that is to be registered or reconnected to is sent nothing whatever its disk does.
    public func strip(inSheet: Bool = false) -> Strip? {
        if let busy { return .busy(busy) }
        if anotherTookOver, connected { return .anotherTookOver }
        if let line = queueReport { return .report(line, inFull: tv != nil) }
        if demo, DemoData.banner(in: defaults), !inSheet { return .demo }
        if connectBlocked { return .blocked }
        if gaveUp { return .recorderGaveUp }
        if waitingForTVTitles { return .busy(TVDriver.titlesComingLine) }
        if tv?.session.connectBlocked == true { return .blocked }
        if tvDriver?.facts.needsPairing == true { return .tvNeedsPairing }
        if tv?.session.gaveUp == true { return .tvGaveUp }
        if tvWaitsForItsDisk { return .tvDiskAway }
        return nil
    }
}

extension AppModel.Strip {
    /// What the line says.
    @MainActor
    public var says: String {
        switch self {
        case .busy(let line), .report(let line, _): line
        case .anotherTookOver: AppModel.anotherTookOverLine
        case .demo: "サンプルデータを表示しています"
        case .blocked: "ローカルネットワークが許可されていません"
        case .recorderGaveUp: "レコーダーの応答がありません"
        case .tvNeedsPairing: "テレビの登録が必要です"
        case .tvGaveUp: "テレビの応答がありません"
        case .tvDiskAway: TVDriver.diskNotFound
        }
    }

    /// The button beside what the line says, if it has one of the model's. None while something is under way, which
    /// goes by itself. None of the model's while the local network permission stands in the way: giving it is the one
    /// thing the app cannot do, and 再接続 would only run into the same refusal, so the way to the switch is offered
    /// instead, where the platform has one. None for the television's disk, which is put back at the television: the
    /// next sending of what waits reads it again, which pulling the reservations down asks for.
    public var offer: AppModel.Offer? {
        switch self {
        case .busy, .blocked, .tvDiskAway: nil
        case .anotherTookOver, .report: .close
        case .demo: .leaveDemo
        case .recorderGaveUp: .reconnect
        case .tvNeedsPairing: .registerTV
        case .tvGaveUp: .reconnectTV
        }
    }
}

extension AppModel {
    /// A button of the strip at the top of every screen (`Strip.offer`) or of a screen with no recorder to talk to
    /// (`NoRecorderSays`): its word here, whether it is held (`holds`), and what a press does (`act(on:)`).
    public enum Offer: Equatable, Sendable {
        /// The line stays until it is closed (`close(_:)`). Drawn as a mark: the word is for whatever reads the
        /// screen aloud.
        case close
        /// The demo ended: whatever was there before it is put back.
        case leaveDemo
        /// The recorder connected to again, woken first if that is what it needs.
        case reconnect
        /// The tutorial, for its search: a screen of the platform's to open.
        case search
        /// The television is there and takes nothing until the app is registered with it again: the sheet that
        /// does it, a screen of the platform's to open over the model's state of it (`TVRegisterState`).
        case registerTV
        /// The television connected to again.
        case reconnectTV

        public var label: String {
            switch self {
            case .close: "閉じる"
            case .leaveDemo: "終了"
            case .reconnect, .reconnectTV: "再接続"
            case .search: "レコーダーを探す"
            case .registerTV: "登録"
            }
        }
    }

    /// Whether the button is held now. 終了 while the recorder in play may not be changed, a connect or a job
    /// under way, which `busy` alone does not always show (`canChangeRecorder`). 再接続 to the recorder while a bulk
    /// job runs, when a connect is only owed until it ends and dropped if it meets silence first
    /// (`DeviceLink.connect`), and the search with it, whose recorders could not be taken while the job has the
    /// recorder. With no recorder set up there is no job, and the search is not held.
    public func holds(_ offer: Offer) -> Bool {
        switch offer {
        case .leaveDemo: !canChangeRecorder
        case .reconnect, .search: jobRunning
        case .close, .registerTV, .reconnectTV: false
        }
    }

    /// What a press does: the demo left, or the recorder or the television connected to again. The search and the
    /// television's registration open screens of the platform's, and 閉じる takes down the line it is on
    /// (`close(_:)`): nothing is done for them here.
    public func act(on offer: Offer) async {
        switch offer {
        case .leaveDemo: await leaveDemo()
        case .reconnect: await connect()
        case .reconnectTV: await tv?.connect()
        case .close, .search, .registerTV: break
        }
    }

    /// 閉じる on a line that stays until it is closed: that another recorder took over, or what became of what was
    /// waiting, for both devices. Any other line is left as it is.
    public func close(_ line: Strip) {
        switch line {
        case .anotherTookOver: anotherTookOver = false
        case .report: closeQueueReport()
        default: break
        }
    }
}
