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
    /// the app's to say. After a check that heard something in place of the recorder saying which it is, nothing
    /// is read, as for the reservations: what it heard is what the read fails as (`asked`).
    public func recorderRules() async -> [RecorderRule]? {
        guard let link, link.client is RecorderClient else { return nil }
        if case .went(let list) = await asked(Self.conditionsLine, .aRead, on: link, since: link.generation, {
            _, client in try await client.recorderRules()
        }) { return list }
        return nil
    }

    /// Registers a condition on the recorder itself, which then records by it with nothing else running. What it
    /// came to, with its sentence; the list read after it goes to `keep` (`readAfter`).
    ///
    /// Its disk is the one the reader picked, sent as picked or not at all: a USB disk no longer offered is
    /// refused before anything is sent, as a reservation's is (`reserve`), and so is one the slot has not answered
    /// since the recorder last answered and does not answer while it is waited for (`withholds`): each says which
    /// disk cannot be had, by what the sheet has left to offer (`RecorderDisk.chooseAnother`). A condition is
    /// never changed, so one made to a disk the reader did not pick could only be deleted and made again. The
    /// disk the last request found not to be had is forgotten as it begins (`clearTheDiskNotHad`).
    ///
    /// What a door turns away, with nothing sent, is said in the result and not on the line, which keeps what an
    /// earlier operation left there (`Reserved`): the link gone, no recorder's client in hand, the recorder
    /// known to be away, or nothing that can be written to it (`canBeAsked`), each that the app is not connected
    /// (`whyNotConnected`); a disk not had; a wait for the slot given up on (`slotWaitGivenUp`).
    ///
    /// One line from the press, for either disk, until the list read after it is in, as a reservation's is: the
    /// reader sees one thing asked for, with no moment between its steps in which nothing is, and the sheet holds
    /// its button while a line is up, so a second press cannot make a second condition meanwhile. To the slot,
    /// the recorder is made sure of, and the slot waited for, before the registration goes out -- waking the
    /// recorder leaves the disk to be waited for. The recorder not answering, at the check or at the slot, ends
    /// it there with nothing sent, the result saying again what that left on the line; so does a check that
    /// heard something in place of the recorder saying which it is (`DeviceLink.mayBeSent`), what it heard said
    /// on the line, being the recorder's answer, as for a reservation to the slot (`reserve`). Then one
    /// operation, as `DeviceLink.run` makes one, on the client in hand at the door: silence says that the
    /// registration may have arrived, and what the check or a failure said is in the result as well as on the
    /// line (`altered`). A registration that went through has the list read after it.
    public func addRule(_ request: RecorderRuleRequest, keep: @MainActor ([RecorderRule]?) -> Void) async -> Altered {
        clearTheDiskNotHad()
        guard let link else { return .notDone(Self.notConnected) }
        guard link.client is RecorderClient else { return .notDone(whyNotConnected) }
        let owner = link.owner
        guard RecorderDisk.offers(request.destination, with: link.session.usbDisk) else {
            return .notDone(RecorderDisk.chooseAnother(than: request.destination, usb: link.session.usbDisk))
        }
        guard !link.session.unreachable, canBeAsked(on: link) else { return .notDone(whyNotConnected) }
        let began = link.generation
        let toTheSlot = request.destination == RecorderDisk.usbID
        return await link.underALine(Self.registeringLine) { _ -> Altered in
            if toTheSlot {
                guard case .up = await link.check(evenIfRecent: link.checksAgain) else {
                    guard !link.letGo(since: began) else { return .notDone(self.whyLetGo(on: link)) }
                    return .notDone(owner?.problem ?? self.whyNotConnected)
                }
                guard link.mayBeSent else { return .notDone(self.whyNotSent(on: link)) }
                let withheld = await self.withholds(request.destination)
                // Let go of while the slot was waited for, whatever it answered: what it answered is about the
                // recorder let go of.
                guard !link.letGo(since: began) else { return .notDone(self.whyLetGo(on: link)) }
                switch withheld {
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
            // Asked again whether it may be sent, after the slot: another operation's check may have heard
            // something in place of the recorder meanwhile. On the client the check is asked with then: a connect
            // to the same recorder made while the slot was waited for has one of its own.
            let came = await self.asked(nil, .aWrite(sending: Self.mayHaveArrived), on: link,
                                        since: began) { _, client in
                _ = try await client.createRecorderRule(request)
            }
            let altered = self.altered(came, on: link)
            if came.wentThrough { await self.readAfter(on: link, since: began, keep: keep) }
            return altered
        }
    }

    /// Deletes a condition, never edits one: a condition read over the LAN lacks the channel narrowing the
    /// recorder's own screen can set, and writing it back would erase that. What it came to, with its sentence;
    /// the list read after it goes to `keep` (`readAfter`). Turned away at the door as a condition added is, the
    /// result saying that the app is not connected and the line left as it was. Otherwise one operation, as
    /// `DeviceLink.run` makes one, on the client in hand at the door, under one line until the list read after it
    /// is in: silence says that the delete may have arrived, and what the check or a failure said is in the
    /// result as well as on the line (`altered`).
    ///
    /// The list is read after a delete the recorder answered, whether it went through or was refused: the
    /// recorder renumbers a condition whenever its own screen edits one, so a refusal may be of a number it no
    /// longer has, and which code it answers to one has not been seen. Not after one that was not sent -- turned
    /// away at the door, or after the check -- nor after silence: nothing has changed that the reader did, or the
    /// recorder is not there to read.
    public func removeRule(_ rule: RecorderRule, keep: @MainActor ([RecorderRule]?) -> Void) async -> Altered {
        guard let link else { return .notDone(Self.notConnected) }
        guard link.client is RecorderClient, !link.session.unreachable, canBeAsked(on: link) else {
            return .notDone(whyNotConnected)
        }
        let began = link.generation
        return await link.underALine(Self.removingConditionLine) { _ -> Altered in
            let came = await self.asked(nil, .aWrite(sending: Self.mayHaveArrived), on: link,
                                        since: began) { _, client in
                try await client.deleteRecorderRule(id: rule.id)
            }
            let altered = self.altered(came, on: link)
            if came.answered { await self.readAfter(on: link, since: began, keep: keep) }
            return altered
        }
    }

    /// The list read again after a condition was added or deleted, as a step of that operation: under its line,
    /// with none of its own, and by the count it noted at its door. Handed to `keep` once read, or as nil when it
    /// could not be, the failure said on the line as for any read. Not across a let-go: the list to read is the
    /// newcomer's, which its own connect reads, and one that comes back once the recorder has been let go of is
    /// neither handed over nor said.
    private func readAfter(on link: DeviceLink, since began: Int, keep: @MainActor ([RecorderRule]?) -> Void) async {
        guard !link.letGo(since: began) else { return }
        let came = await asked(nil, .aRead, on: link, since: began) { _, client in try await client.recorderRules() }
        guard !link.letGo(since: began) else { return }
        if case .went(let list) = came {
            keep(list)
        } else {
            keep(nil)
        }
    }
}
