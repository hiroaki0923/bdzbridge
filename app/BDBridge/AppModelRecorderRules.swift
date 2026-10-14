import Foundation
import RecorderKit
import SwiftUI

/// The recorder's own keyword conditions (おまかせ・まる録): read, added and removed, never changed.
extension AppModel {
    func loadRecorderRules() async {
        let said = recorderHost.said
        await start()
        await loadRecorderRulesNow(into: said)
    }

    /// The read itself, without `start()`, for anything `connect()` reaches: see there. The read is the driver's
    /// (`RecorderDriver.recorderRules`), and so is why it could not be made; what the screen holds of it is the
    /// app's, kept on what was said as the entry began (`RecorderSaid.keep`), the one in play when `said` is nil,
    /// as for the recordings: a read for a recorder let go of meanwhile says nothing on the screen of the one
    /// after it, whose own connect reads its list. While it is out it is counted (`RecorderHost.conditionReads`).
    func loadRecorderRulesNow(into said: RecorderSaid? = nil) async {
        let said = said ?? recorderHost.said
        guard let recorderDriver, client != nil, !unreachable else {
            // A list read before stays on screen under the strip that says the recorder is not there; with
            // none, the screen says why there is nothing rather than waiting for a read that is not coming.
            if !recorderRulesLoaded {
                recorderHost.said.recorderRulesFailure = recorderDriver?.whyNotConnected ?? RecorderDriver.notConnected
            }
            return
        }
        recorderHost.conditionReads += 1
        defer { recorderHost.conditionReads -= 1 }
        said.keep(rules: await recorderDriver.recorderRules())
    }

    /// What pulling the conditions down asks for: the list read again, or a connect when nothing can be written
    /// to the recorder -- the driver's to decide (`RecorderDriver.refresh`), after `start()` whichever it does.
    /// Counted as a read of the list across the connect it may make, as the recordings' pull-down is
    /// (`conditionReads`).
    func refreshRecorderRules() async {
        let said = recorderHost.said
        await start()
        recorderHost.conditionReads += 1
        defer { recorderHost.conditionReads -= 1 }
        await recorderDriver?.refresh { await self.loadRecorderRulesNow(into: said) }
    }

    /// The disk a condition's row names, or nil for none: only one off the internal disk, by the one rule the
    /// reservations' rows go by (`RecorderDisk.shown`).
    func diskShown(_ rule: RecorderRule) -> String? {
        RecorderDisk.shown(rule.destination, on: .recorder, usb: usbDisk)
    }

    /// Registers a condition on the recorder itself (`RecorderDriver.addRule`), which reads the list again once it
    /// has, kept on what was said as the entry began (`RecorderSaid.keep`). What it came to, for the sheet to say.
    /// Counted as a read of the list while it is out (`conditionReads`), the read after among it: another recorder
    /// answering meanwhile has its own conditions read by its connect, as for any read of them out.
    func addRecorderRule(_ request: RecorderRuleRequest) async -> Altered {
        let said = recorderHost.said
        await start()
        guard let recorderDriver else { return .notDone(RecorderDriver.notConnected) }
        recorderHost.conditionReads += 1
        defer { recorderHost.conditionReads -= 1 }
        return await recorderDriver.addRule(request) { said.keep(rules: $0) }
    }

    /// Delete only, never edit (`RecorderDriver.removeRule`), which reads the list again after any answer, kept
    /// as a condition added has its list kept: a refusal may be of a number the recorder no longer has. What it
    /// came to, for the screen to say: a refusal is said there, and the read after it clears the line when it
    /// goes through, as the read after a reservation's delete refused so does, or says its own failure when it
    /// does not. Counted while it is out, as a condition added is.
    func removeRecorderRule(_ rule: RecorderRule) async -> Altered {
        let said = recorderHost.said
        await start()
        guard let recorderDriver else { return .notDone(RecorderDriver.notConnected) }
        recorderHost.conditionReads += 1
        defer { recorderHost.conditionReads -= 1 }
        return await recorderDriver.removeRule(rule) { said.keep(rules: $0) }
    }
}
