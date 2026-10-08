import Foundation
import RecorderKit
import SwiftUI

/// The recorder's own keyword conditions (おまかせ・まる録): read, added and removed, never changed.
extension AppModel {
    func loadRecorderRules() async {
        await start()
        await loadRecorderRulesNow()
    }

    /// The read itself, without `start()`, for anything `connect()` reaches: see there.
    func loadRecorderRulesNow() async {
        guard let client, !unreachable else {
            // A list read before stays on screen under the strip that says the recorder is not there; with
            // none, the screen says why there is nothing rather than waiting for a read that is not coming.
            if !recorderRulesLoaded { recorderRulesFailure = problem ?? Self.rulesNotAsked }
            return
        }
        let read = await run("おまかせ・まる録の設定を取得中") { self.recorderRules = try await client.recorderRules() }
        if read {
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

    /// The disk a condition's row names, or nil for none: only one off the internal disk, by the one rule the
    /// reservations' rows go by (`RecorderDisk.shown`).
    func diskShown(_ rule: RecorderRule) -> String? {
        RecorderDisk.shown(rule.destination, on: .recorder, usb: usbDisk)
    }

    /// Registers a condition on the recorder itself, which then records by it with nothing else running.
    ///
    /// Its disk is the one the reader picked, sent as picked or not at all: a USB disk no longer offered is
    /// refused before anything is sent, as a reservation's is (`reserve`), and so is one the slot has not answered
    /// since the recorder last answered and does not answer while it is waited for (`RecorderDriver.withholds`).
    /// A condition is never changed, so one made to a disk the reader did not pick could only be deleted and made
    /// again.
    ///
    /// To the slot, the recorder is made sure of, and the slot waited for, before the registration goes out --
    /// waking the recorder leaves the disk to be waited for -- under the registration's line from the press, as
    /// `run` puts its line up before its own check: the sheet holds its button while a line is up, so a second
    /// press cannot make a second condition meanwhile.
    func addRecorderRule(_ request: RecorderRuleRequest) async -> Bool {
        await start()
        recorderDriver?.clearTheDiskNotHad()
        guard let client else { return false }
        guard RecorderDisk.offers(request.destination, with: usbDisk) else {
            problem = RecorderDisk.chooseAnother(than: request.destination, usb: usbDisk)
            return false
        }
        let toTheSlot = request.destination == RecorderDisk.usbID
        let line = toTheSlot ? activities.begin(Self.registering) : nil
        defer { if let line { activities.end(line) } }
        if toTheSlot {
            guard await wakeIfDozing() else { return false }
            if let withheld = await recorderDriver?.withholds(request.destination) {
                if withheld == .noDisk {
                    problem = RecorderDisk.chooseAnother(than: request.destination, usb: usbDisk)
                }
                return false
            }
        }
        let made = await run(Self.registering, sending: true) {
            _ = try await client.createRecorderRule(request)
        }
        if made { await loadRecorderRules() }
        return made
    }

    /// The line while a condition is registered.
    private static let registering = "レコーダーに登録中"

    /// Delete only, never edit: a condition read over the LAN lacks the channel narrowing the recorder's own
    /// screen can set, and writing it back would erase that. The list is read again afterwards either way,
    /// because the recorder renumbers a condition whenever its screen edits one.
    func removeRecorderRule(_ rule: RecorderRule) async -> Bool {
        await start()
        guard let client else { return false }
        let removed = await run("レコーダーから削除中", sending: true) {
            try await client.deleteRecorderRule(id: rule.id)
        }
        // The read that follows clears the message when it works, and for a delete that failed the message is
        // the reason the screen shows. Put back only over nothing: a read that failed has said something newer,
        // such as the recorder no longer answering, and that is what is true now.
        let reason = problem
        await loadRecorderRules()
        if !removed, problem == nil { problem = reason }
        return removed
    }
}
