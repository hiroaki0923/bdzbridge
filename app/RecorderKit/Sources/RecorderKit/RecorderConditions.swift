import Foundation

/// The recorder's own keyword conditions (おまかせ・まる録): read, added and removed, never changed. The steps,
/// and what each says on the host's screen; the list and why it could not be read are the app's to keep.
extension RecorderDriver {
    /// The line on screen while the conditions are read.
    static let conditionsLine = "おまかせ・まる録の設定を取得中"

    /// The lines on screen while a condition is registered, and while one is deleted.
    static let registeringLine = "レコーダーに登録中"
    static let removingConditionLine = "レコーダーから削除中"

    /// What a read of the conditions came to, for the screen: the list, or nil and why there is none.
    public typealias ConditionsRead = (list: [RecorderRule]?, why: String?)

    /// The conditions as the recorder lists them, read now, or why they could not be, said by the read itself.
    /// One operation, as `DeviceLink.run` makes one (`asked`), on the client in hand at the door. Nothing is
    /// asked when there is no recorder's client or the recorder is known to be away, which is that the app is
    /// not connected (`whyNotConnected`); whether to ask at all is the app's to say. After a check that heard
    /// something in place of the recorder saying which it is, nothing is read, as for the reservations: what it
    /// heard is what the read fails as (`asked`), and why is said as `conditionsRead` says it.
    ///
    /// One read at a time, as for the recordings (`titles`, `folded`): whoever asks while one is out for the same
    /// recorder, on the same client, is handed what it came to, and one out otherwise is waited for first. The
    /// list read before a condition is deleted, and after one is added or deleted, is one of them (`readAgain`).
    public func recorderRules() async -> ConditionsRead {
        guard let link else { return (nil, Self.notConnected) }
        guard let client = link.client as? RecorderClient, !link.session.unreachable else {
            return (nil, whyNotConnected)
        }
        return await folded(\.conditionsReading, on: link, client) {
            let began = link.generation
            return self.conditionsRead(await self.asked(Self.conditionsLine, .aRead, on: link, since: began) {
                _, client in try await client.recorderRules()
            }, on: link)
        }
    }

    /// What a read of the conditions asked through `asked` came to: the list, or why there is none -- a refusal
    /// in the recorder's words, and otherwise what the link said of it, as the reservations' delete and change
    /// say what their reads came to: a check that said no has said why on the line, silence too, and with
    /// nothing on the line -- a check turned away for the local network permission, a silence not said -- that
    /// the app is not connected.
    func conditionsRead(_ came: Asked<[RecorderRule]>, on link: DeviceLink) -> ConditionsRead {
        switch came {
        case .went(let list): (list, nil)
        case .failed(.refused(_, let sentence)): (nil, sentence)
        default: (nil, link.owner?.problem ?? whyNotConnected)
        }
    }

    /// Registers a condition on the recorder itself, which then records by it with nothing else running. What it
    /// came to, with its sentence; the list read after it goes to `keep` (`readAgain`).
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
    public func addRule(_ request: RecorderRuleRequest, keep: @MainActor (ConditionsRead) -> Void) async -> Altered {
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
            if came.wentThrough { await self.readAgain(on: link, since: began, keep: keep) }
            return altered
        }
    }

    /// Said when a condition asked to be deleted is not in the list just read as the screen showed it: gone from
    /// the recorder, or changed there -- the recorder renumbers a condition its own screen edits, so the two
    /// are seldom told apart. Nothing was sent, and the list on screen is the one just read.
    public nonisolated static let conditionNotInList = "この条件はレコーダーのおまかせ・まる録の一覧に見つかりませんでした。"
        + "レコーダーで変更された場合も含みます。一覧を更新しました。"

    /// Deletes a condition, never edits one: a condition read over the LAN lacks the channel narrowing the
    /// recorder's own screen can set, and writing it back would erase that. What it came to, with its sentence;
    /// the lists read before and after it go to `keep` (`readAgain`). Turned away at the door as a condition
    /// added is, the result saying that the app is not connected and the line left as it was. Otherwise under one
    /// line until the list read after it is in.
    ///
    /// The id a condition was read with is not to be trusted later: the recorder renumbers a condition its own
    /// screen edits (docs/xsrs-api.md). So the list is read again first, with no line of its own, and the delete
    /// goes only from it, as a reservation's does (`cancel`): a read that did not go through ends it there,
    /// nothing sent, the result saying what the read left; a read that went through has cleared the line. A
    /// condition not in that list as the screen showed it -- by its id and everything else it was read with --
    /// is not sent for, and the result says so (`conditionNotInList`), the list on screen being the one just
    /// read. Let go of while the read was out, nothing is sent and the result says why (`whyLetGo`).
    ///
    /// Then the delete, as `DeviceLink.run` makes one, on the client the check is asked with then: silence says
    /// that the delete may have arrived, and what the check or a failure said is in the result as well as on the
    /// line (`altered`).
    ///
    /// The list is read after a delete the recorder answered, whether it went through or was refused: the
    /// recorder renumbers a condition whenever its own screen edits one, so a refusal may be of a number it no
    /// longer has, and which code it answers to one has not been seen. Not after one that was not sent -- turned
    /// away at the door, by the read before it, or after the check -- nor after silence: nothing has changed
    /// that the reader did, or the recorder is not there to read.
    public func removeRule(_ rule: RecorderRule, keep: @MainActor (ConditionsRead) -> Void) async -> Altered {
        guard let link else { return .notDone(Self.notConnected) }
        guard link.client is RecorderClient, !link.session.unreachable, canBeAsked(on: link) else {
            return .notDone(whyNotConnected)
        }
        let began = link.generation
        return await link.underALine(Self.removingConditionLine) { _ -> Altered in
            guard let read = await self.readAgain(on: link, since: began, keep: keep) else {
                return .notDone(self.whyLetGo(on: link))
            }
            guard let list = read.list else { return .notDone(read.why ?? self.whyNotConnected) }
            guard list.contains(rule) else { return .notDone(Self.conditionNotInList) }
            let came = await self.asked(nil, .aWrite(sending: Self.mayHaveArrived), on: link,
                                        since: began) { _, client in
                try await client.deleteRecorderRule(id: rule.id)
            }
            let altered = self.altered(came, on: link)
            if came.answered { await self.readAgain(on: link, since: began, keep: keep) }
            return altered
        }
    }

    /// The list read again as a step of a condition's add or delete -- before a delete, and after either -- under
    /// its line, with none of its own, and by the count it noted at its door. Handed to `keep` as any read of the
    /// list is (`recorderRules`), with why when it could not be read, and handed back; nil across a let-go: the
    /// list to read is the newcomer's, which its own connect reads, and one that comes back once the recorder has
    /// been let go of is neither handed over nor said.
    ///
    /// One of the conditions' reads (`folded`), but one that takes no other's answer: a read out as it begins was
    /// asked before what this step follows was answered, and its list may not show it, so it is waited for, and
    /// the list read after it. Whoever asks for the conditions while this read is out is handed what it comes
    /// to, and a newcomer's connect, which reads them, waits for it as for any read of them out for a recorder
    /// let go of.
    @discardableResult
    private func readAgain(on link: DeviceLink, since began: Int,
                           keep: @MainActor (ConditionsRead) -> Void) async -> ConditionsRead? {
        if let out = conditionsReading { _ = await out.value.value }
        // The client is gone only once the recorder has been let go of (`DeviceLink.forgetTheDevice`).
        guard !link.letGo(since: began), let client = link.client as? RecorderClient else { return nil }
        let read = await folded(\.conditionsReading, on: link, client) {
            self.conditionsRead(await self.asked(nil, .aRead, on: link, since: began) { _, client in
                try await client.recorderRules()
            }, on: link)
        }
        guard !link.letGo(since: began) else { return nil }
        keep(read)
        return read
    }
}
