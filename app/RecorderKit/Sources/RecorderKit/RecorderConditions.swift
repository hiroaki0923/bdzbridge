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
                // What a check heard in place of the recorder while the slot was waited for, which ended the wait
                // with the slot unanswered, stops it here, in the turn the wait ended in: the check below asks
                // again, and the recorder answering that one would send a condition naming a disk the slot has not
                // answered.
                guard link.mayBeSent else { return .notDone(self.whyNotSent(on: link)) }
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
    /// are seldom told apart. Nothing was sent; or the delete was sent and the recorder answered that it holds no
    /// condition under that number (`conditionNotHeld`), and the list was read after it. Either way the list on
    /// screen is the one just read.
    public nonisolated static let conditionNotInList = "この条件はレコーダーのおまかせ・まる録の一覧に見つかりませんでした。"
        + "レコーダーで変更された場合も含みます。一覧を更新しました。"

    /// Deletes a condition, never edits one: a condition read over the LAN lacks the channel narrowing the
    /// recorder's own screen can set, and writing it back would erase that. What it came to, with its sentence;
    /// the lists read before and after it go to `keep` (`readAgain`). Turned away at the door as a condition
    /// added is, the result saying that the app is not connected and the line left as it was. Otherwise under one
    /// line until it is answered, and the list read after it, when one is read, is in.
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
    /// The list is read after a delete that went through, and after one the recorder refused because it holds no
    /// condition under that number (`conditionNotHeld`): gone since the read before it, or renumbered by the
    /// recorder's own screen, which renumbers a condition whenever it edits one. That one the result then says
    /// was not in the list (`conditionNotInList`), the list on screen being the one just read, as a reservation's
    /// delete that met a number the recorder no longer has says it was renumbered (`cancel`); when that read does
    /// not go through, what it failed with; and answered so once the recorder has been let go of, nothing is read
    /// and the result says why (`whyLetGo`), the answer being about the recorder let go of. Not after any other
    /// refusal, which is said in the recorder's words, nothing having changed that the reader did; nor after one
    /// that was not sent -- turned away at the door, by the read before it, or after the check -- nor after
    /// silence, the recorder not being there to read.
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
            // Whether the recorder held it: a refusal that says it does not is an answer, as a delete's is.
            let came = await self.asked(nil, .aWrite(sending: Self.mayHaveArrived), on: link,
                                        since: began) { _, client -> Bool in
                do {
                    try await client.deleteRecorderRule(id: rule.id)
                    return true
                } catch let error as RecorderError where Self.saysItHoldsNoSuchCondition(error) {
                    return false
                }
            }
            guard case .went(let held) = came else { return self.altered(came, on: link) }
            let after = await self.readAgain(on: link, since: began, keep: keep)
            if held { return .done(saying: nil) }
            guard let after else { return .notDone(self.whyLetGo(on: link)) }
            return .notDone(after.list == nil ? after.why ?? self.whyNotConnected : Self.conditionNotInList)
        }
    }

    /// What a BDZ-FBT4100 answers to the delete of a number it holds no condition under: HTTP 500 with UPnP
    /// error 892 (docs/xsrs-api.md). The delete's alone: no other action has been seen to answer it, and what it
    /// means there is not known.
    static let conditionNotHeld = "892"

    /// Whether `error` is the recorder's answer that it holds no condition under the number deleted.
    private static func saysItHoldsNoSuchCondition(_ error: RecorderError) -> Bool {
        guard case .soap(_, _, let code, _) = error else { return false }
        return code == conditionNotHeld
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

/// A new keyword condition as its form holds it, before it is sent (`RecorderDriver.addRule`): what the recorder
/// takes -- five keywords, two exclusions, the genres, broadcasts and times of day it knows -- and the check that
/// a condition names something to look for. The words are rows, each with an identity of its own, so that a
/// list on screen does not reorder them as they are typed.
public struct RecorderRuleDraft: Sendable, Equatable {
    /// How many keywords, and how many exclusions, the recorder holds on one condition.
    public static let keywordLimit = 5
    public static let excludedLimit = 2

    /// Said while the condition names neither a keyword nor a genre, which the recorder would take for anything.
    public static let needsAKeywordOrAGenre = "キーワードかジャンルを指定してください"

    /// What the recorder records in where the form was given a mode it does not offer: LSR.
    public static let fallbackQualityCode = 240

    /// One word of the condition.
    public struct Word: Identifiable, Sendable, Equatable {
        public let id: UUID
        public var text: String

        public init(_ text: String = "") {
            id = UUID()
            self.text = text
        }
    }

    /// One choice the form offers, as the recorder spells it and as the form says it.
    public struct Choice: Sendable, Equatable, Hashable {
        public var code: String
        public var label: String
    }

    /// The genres a condition can name: the twelve kinds of programme. The table also holds the extension area
    /// (0xE), which says what the bytes after it are for and is no kind of programme. It has sub-genres of its
    /// own, so the test for those, which keeps その他 (0xF) out, lets it in: it is left out by name.
    public static let genres = Codes.genreLabel.keys.sorted().filter { $0 != 0xE && Codes.subGenreLabel[$0] != nil }

    /// The sub-genres of `genre`, none without one.
    public static func subGenres(of genre: Int?) -> [Int] {
        genre.flatMap { Codes.subGenreLabel[$0]?.keys.sorted() } ?? []
    }

    /// How several keywords are combined.
    public static let logics = [Choice(code: "OR", label: "いずれかを含む"), Choice(code: "AND", label: "すべてを含む")]

    /// The broadcasts a condition can be narrowed to: the 4K ones only where the guide has 4K channels, which a
    /// recorder without 4K tuners has not.
    public static func broadcastingScopes(guide counts: [String: GuideCounts]) -> [Choice] {
        let fourK = GuideRefresh.offeredTypes(counts).contains("bs4k")
        return ["ALL", "TRD", "BSD", "CSD"].map(scope) + (fourK ? Codes.advancedScopes.map(scope) : [])
    }

    public static let timeScopes = ["ALL", "MORNING", "AFTERNOON", "NIGHT", "MIDNIGHT"].map {
        Choice(code: $0, label: Codes.timeScopeLabel[$0] ?? $0)
    }

    private static func scope(_ code: String) -> Choice {
        Choice(code: code, label: Codes.broadcastingScopeLabel[code] ?? code)
    }

    /// One empty keyword row to begin with, and no exclusion.
    public var keywords = [Word()]
    public var excluded: [Word] = []
    public var logic = "OR"
    /// The level-1 genre, nil for none. Choosing another takes the sub-genre away: a genre's sub-genres are
    /// its own.
    public var genre: Int? {
        didSet { if genre != oldValue { subGenre = nil } }
    }
    /// One sub-genre of `genre`, nil for the whole genre.
    public var subGenre: Int?
    public var broadcastingScope = "ALL"
    public var timeScope = "ALL"
    /// The recording mode by its name (`RecorderDriver.recordsIn`).
    public var quality: String

    public init(quality: String) {
        self.quality = quality
    }

    /// The words as they are sent: trimmed, the empty ones left out.
    public var words: [String] { Self.cleaned(keywords) }
    public var excludedWords: [String] { Self.cleaned(excluded) }

    public var mayAddKeyword: Bool { keywords.count < Self.keywordLimit }
    public var mayAddExclusion: Bool { excluded.count < Self.excludedLimit }
    /// Whether the last keyword row may be taken away: one is always left to type into.
    public var mayRemoveKeyword: Bool { keywords.count > 1 }
    /// Whether how the keywords are combined is asked: only once there is more than one.
    public var asksHowToCombine: Bool { words.count > 1 }

    /// Why the condition cannot be sent yet, or nil.
    public var problem: String? {
        words.isEmpty && genre == nil ? Self.needsAKeywordOrAGenre : nil
    }

    /// What is sent to record to `disk`, the internal disk where none was picked.
    public func request(to disk: String?) -> RecorderRuleRequest {
        RecorderRuleRequest(keywords: words, excluded: excludedWords, logic: logic, genreLevel1: genre,
                            genreLevel2: genre == nil ? nil : subGenre, timeScope: timeScope,
                            broadcastingScope: broadcastingScope,
                            qualityCode: Codes.quality[quality] ?? Self.fallbackQualityCode,
                            destination: disk ?? RecorderDisk.internalID)
    }

    private static func cleaned(_ rows: [Word]) -> [String] {
        rows.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

public extension RecorderRule {
    /// What a condition's row says under its name: the keywords, what is left out, how the keywords are combined,
    /// the broadcasts, the times of day, the genre, the modes, and last the disk it records to where the app names
    /// one (`disk`, nil for the internal disk, so that nothing changes in a home with no USB disk).
    func details(disk: String? = nil) -> String {
        var parts = [keywords.joined(separator: "、")]
        if !excluded.isEmpty { parts.append("除外: " + excluded.joined(separator: "、")) }
        parts.append(logic == "AND" ? "すべて含む" : "いずれか含む")
        parts.append(broadcastingScopeLabel)
        parts.append(timeScopeLabel)
        if let genreLabel { parts.append(genreLabel) }
        if let qualityName { parts.append(Codes.qualityLabel[qualityName] ?? qualityName) }
        // The 4K waves have a mode of their own. A condition on every wave made without it records BS4K and CS4K in
        // DR whatever the mode beside it says, and this is where one is seen, to be made again.
        if let qualityName4K { parts.append("4K: " + (Codes.qualityLabel[qualityName4K] ?? qualityName4K)) }
        if let disk { parts.append(disk) }
        return parts.joined(separator: " · ")
    }
}
