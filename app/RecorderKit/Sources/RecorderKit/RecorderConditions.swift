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
        return try? await asked(Self.conditionsLine, on: link) { _ in try await client.recorderRules() }.get()
    }

    /// Registers a condition on the recorder itself, which then records by it with nothing else running. What it
    /// came to, with its sentence; `readAfter` is what the caller has done once it has gone through, before the
    /// line from the press is taken down.
    ///
    /// Its disk is the one the reader picked, sent as picked or not at all: a USB disk no longer offered is
    /// refused before anything is sent, as a reservation's is (`reserve`), and so is one the slot has not answered
    /// since the recorder last answered and does not answer while it is waited for (`withholds`): each says which
    /// disk cannot be had, by what the sheet has left to offer (`RecorderDisk.chooseAnother`). A condition is
    /// never changed, so one made to a disk the reader did not pick could only be deleted and made again. The
    /// disk the last request found not to be had is forgotten as it begins (`clearTheDiskNotHad`).
    ///
    /// What a door turns away, with nothing sent, is said in the result and not on the line, which keeps what an
    /// earlier operation left there (`Reserved`): the link gone, no recorder's client in hand, or the recorder
    /// known to be away, each that the app is not connected (`whyNotConnected`); a disk not had; a wait for the
    /// slot given up on (`slotWaitGivenUp`).
    ///
    /// To the slot, the recorder is made sure of, and the slot waited for, before the registration goes out --
    /// waking the recorder leaves the disk to be waited for -- under the registration's line from the press,
    /// which stays up until the caller's `readAfter` is over: the sheet holds its button while a line is up, so a
    /// second press cannot make a second condition meanwhile. The recorder not answering, at the check or at the
    /// slot, ends it there with nothing sent, the result saying again what that left on the line. Then one
    /// operation, as `DeviceLink.run` makes one, on the client in hand at the door, under a line of its own:
    /// silence says that the registration may have arrived, and what the check or a failure said is in the
    /// result as well as on the line (`altered`).
    public func addRule(_ request: RecorderRuleRequest, readAfter: @MainActor () async -> Void) async -> Altered {
        clearTheDiskNotHad()
        guard let link else { return .notDone(Self.notConnected) }
        guard let client = link.client as? RecorderClient else { return .notDone(whyNotConnected) }
        let owner = link.owner
        guard RecorderDisk.offers(request.destination, with: link.session.usbDisk) else {
            return .notDone(RecorderDisk.chooseAnother(than: request.destination, usb: link.session.usbDisk))
        }
        guard !link.session.unreachable else { return .notDone(whyNotConnected) }
        let toTheSlot = request.destination == RecorderDisk.usbID
        return await link.underALine(toTheSlot ? Self.registeringLine : nil) { _ -> Altered in
            if toTheSlot {
                guard await link.ensureUp() else { return .notDone(owner?.problem ?? self.whyNotConnected) }
                switch await self.withholds(request.destination) {
                case nil:
                    break
                case .noDisk?:
                    return .notDone(RecorderDisk.chooseAnother(than: request.destination, usb: link.session.usbDisk))
                case .silence?:
                    return .notDone(owner?.problem ?? self.whyNotConnected)
                case .givenUp?:
                    return .notDone(Self.slotWaitGivenUp)
                }
            }
            let came = await self.asked(Self.registeringLine, sending: Self.mayHaveArrived, on: link) { _ in
                _ = try await client.createRecorderRule(request)
            }
            let altered = self.altered(came, on: link)
            if came.wentThrough { await readAfter() }
            return altered
        }
    }

    /// Deletes a condition, never edits one: a condition read over the LAN lacks the channel narrowing the
    /// recorder's own screen can set, and writing it back would erase that. What it came to, with its sentence.
    /// Turned away at the door as a condition added is, the result saying that the app is not connected and the
    /// line left as it was. Otherwise one operation, as `DeviceLink.run` makes one, on the client in hand at the
    /// door: silence says that the delete may have arrived, and what the check or a failure said is in the result
    /// as well as on the line (`altered`). The recorder renumbers a condition whenever its own screen edits one,
    /// so the caller reads the list again afterwards either way.
    public func removeRule(_ rule: RecorderRule) async -> Altered {
        guard let link else { return .notDone(Self.notConnected) }
        guard let client = link.client as? RecorderClient, !link.session.unreachable else {
            return .notDone(whyNotConnected)
        }
        return altered(await asked(Self.removingConditionLine, sending: Self.mayHaveArrived, on: link) { _ in
            try await client.deleteRecorderRule(id: rule.id)
        }, on: link)
    }
}
