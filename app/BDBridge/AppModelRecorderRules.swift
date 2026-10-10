import Foundation
import RecorderKit
import SwiftUI

/// The recorder's own keyword conditions (おまかせ・まる録): read, added and removed, never changed.
extension AppModel {
    func loadRecorderRules() async {
        let forgotten = timesForgotten
        await start()
        await loadRecorderRulesNow(since: forgotten)
    }

    /// The read itself, without `start()`, for anything `connect()` reaches: see there. The read is the driver's
    /// (`RecorderDriver.recorderRules`); what the screen says of it is the app's, kept by the count noted as the
    /// entry began (`keepRecorderRules`), now when `forgotten` is nil. While it is out it is counted
    /// (`conditionReads`).
    func loadRecorderRulesNow(since forgotten: Int? = nil) async {
        let forgotten = forgotten ?? timesForgotten
        guard client != nil, !unreachable else {
            // A list read before stays on screen under the strip that says the recorder is not there; with
            // none, the screen says why there is nothing rather than waiting for a read that is not coming.
            if !recorderRulesLoaded { recorderRulesFailure = problem ?? Self.rulesNotAsked }
            return
        }
        conditionReads += 1
        defer { conditionReads -= 1 }
        keepRecorderRules(await recorderDriver?.recorderRules(), since: forgotten)
    }

    /// Puts what a read of the conditions came to on the screen, one read on behalf of an entry that noted
    /// `timesForgotten` as `forgotten` when it began: the list, or why there is none. Only while the count is
    /// still that, as for the recordings (`keepTitles`): a read for a recorder let go of meanwhile says nothing
    /// on the screen of the one after it, whose own connect reads its list.
    func keepRecorderRules(_ read: [RecorderRule]?, since forgotten: Int) {
        guard timesForgotten == forgotten else { return }
        if let read {
            recorderRules = read
            recorderRulesLoaded = true
            recorderRulesFailure = nil
        } else {
            // With no message the recorder was never asked: the check before the read found the local network
            // permission missing, which the strip explains. Saying the recorder returned an error would be
            // saying something it did not do.
            recorderRulesFailure = problem ?? Self.rulesNotAsked
        }
    }

    private static let rulesNotAsked = "レコーダーに接続していません"

    /// What pulling the conditions down asks for: the list read again, or a connect when nothing can be written
    /// to the recorder -- the driver's to decide (`RecorderDriver.refresh`), after `start()` whichever it does.
    /// Counted as a read of the list across the connect it may make, as the recordings' pull-down is
    /// (`conditionReads`).
    func refreshRecorderRules() async {
        let forgotten = timesForgotten
        await start()
        conditionReads += 1
        defer { conditionReads -= 1 }
        await recorderDriver?.refresh { await self.loadRecorderRulesNow(since: forgotten) }
    }

    /// The disk a condition's row names, or nil for none: only one off the internal disk, by the one rule the
    /// reservations' rows go by (`RecorderDisk.shown`).
    func diskShown(_ rule: RecorderRule) -> String? {
        RecorderDisk.shown(rule.destination, on: .recorder, usb: usbDisk)
    }

    /// Registers a condition on the recorder itself (`RecorderDriver.addRule`), and reads the list again once it
    /// has. What it came to, for the sheet to say.
    func addRecorderRule(_ request: RecorderRuleRequest) async -> Altered {
        await start()
        guard let recorderDriver else { return .notDone(RecorderDriver.notConnected) }
        return await recorderDriver.addRule(request) { await self.loadRecorderRules() }
    }

    /// Delete only, never edit (`RecorderDriver.removeRule`). The list is read again afterwards either way,
    /// because the recorder renumbers a condition whenever its screen edits one -- but for no recorder's client
    /// in hand, with nothing to read from. What it came to, for the screen to say.
    func removeRecorderRule(_ rule: RecorderRule) async -> Altered {
        await start()
        guard let recorderDriver else { return .notDone(RecorderDriver.notConnected) }
        let removed = await recorderDriver.removeRule(rule)
        guard client != nil else { return removed }
        // The read that follows clears the message when it works, and for a delete that failed the message is
        // the reason the screen shows. Put back only over nothing: a read that failed has said something newer,
        // such as the recorder no longer answering, and that is what is true now.
        let reason = problem
        await loadRecorderRules()
        if case .notDone = removed, problem == nil { problem = reason }
        return removed
    }
}
