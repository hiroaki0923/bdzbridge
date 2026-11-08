import Foundation
import RecorderKit

extension AppModel {
    /// What the strip at the top of a screen says: one thing at a time. Which one is chosen here and not in
    /// the view that draws it, so that the order can be held by a test.
    enum Strip: Equatable {
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
    func strip(inSheet: Bool = false) -> Strip? {
        if let busy { return .busy(busy) }
        if anotherTookOver, connected { return .anotherTookOver }
        if let line = queueReport { return .report(line, inFull: tv != nil) }
        if demo, DemoData.banner, !inSheet { return .demo }
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
