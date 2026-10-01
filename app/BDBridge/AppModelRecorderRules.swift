import Foundation
import RecorderKit
import SwiftUI

/// The recorder's own keyword conditions (おまかせ・まる録): read, added and removed, never changed.
extension AppModel {
    func loadRecorderRules() async {
        await start()
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

    /// Registers a condition on the recorder itself, which then records by it with nothing else running.
    func addRecorderRule(_ request: RecorderRuleRequest) async -> Bool {
        await start()
        guard let client else { return false }
        let made = await run("レコーダーに登録中", sending: true) {
            _ = try await client.createRecorderRule(request)
        }
        if made { await loadRecorderRules() }
        return made
    }

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
        // the reason the screen shows. Without this it could say only that the recorder had returned an error.
        // Put back only over nothing: a read that failed has said something newer, such as the recorder no
        // longer answering, and that is what is true now.
        let reason = problem
        await loadRecorderRules()
        if !removed, problem == nil { problem = reason }
        return removed
    }
}
