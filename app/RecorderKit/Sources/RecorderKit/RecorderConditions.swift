import Foundation

/// The recorder's own keyword conditions (おまかせ・まる録): read, added and removed, never changed. The steps,
/// and what each says on the host's screen; the list and why it could not be read are the app's to keep.
extension RecorderDriver {
    /// The line on screen while the conditions are read.
    static let conditionsLine = "おまかせ・まる録の設定を取得中"

    /// The lines on screen while a condition is registered, and while one is deleted.
    static let registeringLine = "レコーダーに登録中"
    static let removingConditionLine = "レコーダーから削除中"

    /// The conditions as the recorder lists them, read now; nil when they could not be read, and the host's line
    /// says why where there is anything to say. One operation, as `DeviceLink.run` makes one (`asked`), on the
    /// client in hand at the door. Nothing is asked when there is no recorder's client; whether to ask at all is
    /// the app's to say.
    public func recorderRules() async -> [RecorderRule]? {
        guard let link, let client = link.client as? RecorderClient else { return nil }
        return await asked(Self.conditionsLine, on: link) { _ in try await client.recorderRules() }
    }

    /// Registers a condition on the recorder itself, which then records by it with nothing else running. Whether
    /// it went through; `readAfter` is what the caller has done once it has, before the line from the press is
    /// taken down.
    ///
    /// Its disk is the one the reader picked, sent as picked or not at all: a USB disk no longer offered is
    /// refused before anything is sent, as a reservation's is (`reserve`), and so is one the slot has not answered
    /// since the recorder last answered and does not answer while it is waited for (`withholds`): each says on the
    /// line which disk cannot be had, by what the sheet has left to offer (`RecorderDisk.chooseAnother`). A
    /// condition is never changed, so one made to a disk the reader did not pick could only be deleted and made
    /// again. The disk the last request found not to be had is forgotten as it begins (`clearTheDiskNotHad`).
    /// With no recorder's client, it fails with nothing said.
    ///
    /// To the slot, the recorder is made sure of, and the slot waited for, before the registration goes out --
    /// waking the recorder leaves the disk to be waited for -- under the registration's line from the press,
    /// which stays up until the caller's `readAfter` is over: the sheet holds its button while a line is up, so a
    /// second press cannot make a second condition meanwhile. The recorder not answering, or the wait given up,
    /// fails it with nothing more said. Then one operation, as `DeviceLink.run` makes one, on the client in hand
    /// at the door, under a line of its own: silence says that the registration may have arrived.
    public func addRule(_ request: RecorderRuleRequest, readAfter: @MainActor () async -> Void) async -> Bool {
        clearTheDiskNotHad()
        guard let link, let client = link.client as? RecorderClient else { return false }
        let owner = link.owner
        guard RecorderDisk.offers(request.destination, with: link.session.usbDisk) else {
            owner?.problem = RecorderDisk.chooseAnother(than: request.destination, usb: link.session.usbDisk)
            return false
        }
        let toTheSlot = request.destination == RecorderDisk.usbID
        return await link.underALine(toTheSlot ? Self.registeringLine : nil) { _ in
            if toTheSlot {
                guard await link.ensureUp() else { return false }
                if let withheld = await self.withholds(request.destination) {
                    if withheld == .noDisk {
                        owner?.problem = RecorderDisk.chooseAnother(than: request.destination,
                                                                    usb: link.session.usbDisk)
                    }
                    return false
                }
            }
            let made = await self.asked(Self.registeringLine, sending: Self.mayHaveArrived, on: link) { _ in
                _ = try await client.createRecorderRule(request)
            } != nil
            if made { await readAfter() }
            return made
        }
    }

    /// Deletes a condition, never edits one: a condition read over the LAN lacks the channel narrowing the
    /// recorder's own screen can set, and writing it back would erase that. Whether it went through. With no
    /// recorder's client, it fails with nothing said. Otherwise one operation, as `DeviceLink.run` makes one, on
    /// the client in hand at the door: silence says that the delete may have arrived. The recorder renumbers a
    /// condition whenever its own screen edits one, so the caller reads the list again afterwards either way.
    public func removeRule(_ rule: RecorderRule) async -> Bool {
        guard let link, let client = link.client as? RecorderClient else { return false }
        return await asked(Self.removingConditionLine, sending: Self.mayHaveArrived, on: link) { _ in
            try await client.deleteRecorderRule(id: rule.id)
        } != nil
    }
}
