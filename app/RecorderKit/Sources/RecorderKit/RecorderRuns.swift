import Foundation

/// What a run over many recordings does to each of them: deletes it, protects it or takes its protection off,
/// or, for the scan for duplicates, asks the recorder what it is about, which changes nothing.
public enum RunKind: Sendable, Equatable {
    case delete
    case protecting(Bool)
    case scanning
}

/// What the recorder's driver knows of a run between two of its recordings: what the run does, and the count of
/// recorders let go of as it began (`DeviceLink.generation`), which says which recorder the run is about: asked
/// again before anything of the run is sent and as each answer comes back (`DeviceLink.letGo(since:)`). Made as
/// the run begins (`RecorderDriver.beginRun`), in the turn its job is set up, and handed back with each of its
/// steps. It holds no client: each request of a run goes on the client the link has in hand as it is sent.
public struct Run: Sendable {
    let kind: RunKind
    let began: Int
}

/// Why a run stopped before its end, or did not begin, on the recorder's account: what its job keeps once it
/// has stopped, for what it says then (`RecorderDriver.outcome`) and for the line under that. An `Error` only so
/// that it can be the failure of `RecorderDriver.beginRun`'s `Result`, which asks that of it; nothing throws it.
public enum RunStop: Error, Sendable, Equatable {
    /// Turned away, with a sentence. For a run that did not begin, that the app is not connected
    /// (`RecorderDriver.beginRun`). For one stopped before a recording, or before a later request for one
    /// (`RecorderDriver.mayGoOn`): at a door, that the app is not connected; after a check that said no, what
    /// that check left on the host's line of what went wrong, or that the app is not connected where it left
    /// nothing; and after a check that heard something in place of the recorder saying which it is, what it
    /// heard, in the recorder's words. The same for one stopped at a recording's own request, which is asked as
    /// a single write is and not sent then. For a run whose recorder was let go of, before a request or with its
    /// answer, what a single write says then (`RecorderDriver.whyLetGo`): that another recorder answered, or,
    /// with no recorder in hand since, what whatever let go of it left on the line.
    case said(String)
    /// The recorder said nothing to a request of the run, which the link has said on the line of what went
    /// wrong as it says any silence (`DeviceLink.say`). `afterSending` says whether that request was one that
    /// changes the recorder, a delete or a protect: it may have arrived all the same, and the list of recordings
    /// is to be read again once the recorder answers. Not after silence to a request that only asks.
    case silent(afterSending: Bool)

    /// The sentence handed back with a run turned away, as `.said` has it, for the job to show under what it
    /// says once it has stopped. Nil for silence, which what the job says then says itself
    /// (`RecorderDriver.outcome`).
    public var said: String? {
        if case .said(let why) = self { why } else { nil }
    }
}

/// What deleting or protecting one recording of a run came to (`RecorderDriver.delete(_:in:)`,
/// `protect(_:_:in:)`).
public enum ItemCame: Sendable, Equatable {
    /// The recorder took it.
    case done
    /// The recorder no longer had it: deleted there since the list was read. Nothing went wrong, and the
    /// caller's list should stop showing it. A case of its own so that the caller need not tell it from the
    /// other reasons by the words of the sentence.
    case gone
    /// Nothing was changed, and why. The run goes on.
    case passedOver(String)
    /// The run stops at this recording, and why (`RunStop`): nothing more is sent for it, and it counts neither
    /// as changed nor as passed over.
    case stopped(RunStop)

    /// Why nothing was changed, for the run's list of what it passed over. Nil when something was, and when the
    /// run stopped.
    public var reason: String? {
        switch self {
        case .done, .stopped: nil
        case .gone: "すでに削除されています"
        case .passedOver(let reason): reason
        }
    }
}

/// What asking the recorder for one recording's programme text came to, for the duplicate scan
/// (`RecorderDriver.text(of:in:)`).
public enum TextCame: Sendable, Equatable {
    /// What the recorder holds. An empty text is an answer too: some recordings come with none.
    case read(String)
    /// UPnP error 820: the recorder no longer has the recording.
    case gone
    /// The recorder answered, but not with the text, and this is why.
    case failed(String)
    /// The scan stops at this recording, and why (`RunStop`).
    case stopped(RunStop)
}

/// The recorder's work over many recordings, one request at a time because that is all the recorder will take:
/// the bulk delete, the bulk protect and the scan for duplicates. What is here is the recorder's side of a run:
/// its words, when it may begin and go on, what is asked for one recording and decided about it, including the
/// recorder's two traps, and what it reads as it ends. The loop around the recordings belongs to the app, which
/// is what gives it the progress and the stop button, with the wait while the app is away and the lists.
extension RecorderDriver {
    // MARK: - a run's words

    /// What a run of this kind does, as its job says it while it runs (「削除中 3 / 12」).
    public nonisolated static func verb(of kind: RunKind) -> String {
        switch kind {
        case .delete: "削除"
        case .protecting(true): "保護"
        case .protecting(false): "保護解除"
        case .scanning: "重複の検出"
        }
    }

    /// What to tell the reader once a run has stopped, in the shape the web app settled on: how many recordings
    /// it changed -- a scan, how many it looked at (`done`) -- whether it came to its end or was stopped before
    /// it, and how many it passed over. A run the recorder's silence stopped (`RunStop.silent`) says that the
    /// recorder stopped answering, whether or not 中止 was tapped as well. One stopped for anything else
    /// (`RunStop.said`) says only that it was stopped, as one stopped by 中止 (`cancelled`) does: why is the
    /// stop's own sentence, which the job shows under this one.
    public nonisolated static func outcome(of kind: RunKind, done: Int, changed: Int, passedOver: Int,
                                           cancelled: Bool, stopped: RunStop?) -> String {
        let silent = if case .silent = stopped { true } else { false }
        let cut = cancelled || stopped != nil
        if case .scanning = kind {
            let head = silent ? "\(done) 件まで調べたところで、レコーダーの応答がなくなったため中止しました"
                : cut ? "\(done) 件まで調べて中止しました" : "\(done) 件の確認が完了しました"
            return passedOver == 0 ? head : head + "（\(passedOver) 件は番組内容を取得できず、比べていません）"
        }
        let verb = verb(of: kind)
        let head = silent ? "\(changed) 件を\(verb)したところで、レコーダーの応答がなくなったため中止しました"
            : cut ? "\(changed) 件を\(verb)したところで中止しました" : "\(changed) 件を\(verb)しました"
        return passedOver == 0 ? head : head + "（\(passedOver) 件はスキップ）"
    }

    /// Why a recording was passed over that the list no longer holds by the time the run comes to it.
    public nonisolated static let notInTheList = "一覧に見つかりません"

    // MARK: - a run's recorder

    /// Begins a run of `kind`: the run, for its steps to be handed back with, or why none begins, for its job to
    /// say. Nothing is asked, and nothing is said on the line, which keeps what an earlier operation left there
    /// (`Reserved`).
    ///
    /// A run that deletes or protects has the doors of a single protect (`protect(_:_:keep:)`): the link gone,
    /// no recorder's client in hand, the recorder known to be away, or nothing that can be written to it
    /// (`canBeAsked`) -- the recorder not having said which it is, as after a reconnect it answered busy with
    /// somebody else -- each that the app is not connected (`whyNotConnected`).
    ///
    /// A scan has the one door, a recorder's client in hand: one whose texts are all in the cache asks the
    /// recorder nothing, and comes to its end with the recorder known to be away. Whether a text may be read is
    /// `mayGoOn`'s to say, asked before the first that is to be.
    ///
    /// And neither begins while a connect is under way, with the same sentence: the client in hand is the last
    /// one until the connect has made its own, which has then yet to hear which recorder answers, and once it
    /// has, the attach is still sending what waits, whose silence has the connect try again with another client.
    /// A connect does not start beside a run either (`LinkHost.holdsOffConnect`), so the two keep out of each
    /// other's way in whichever order they are asked for.
    public func beginRun(_ kind: RunKind) -> Result<Run, RunStop> {
        guard let link else { return .failure(.said(Self.notConnected)) }
        guard link.client is RecorderClient, !link.session.connecting else { return .failure(.said(whyNotConnected)) }
        if kind != .scanning {
            guard !link.session.unreachable, canBeAsked(on: link) else { return .failure(.said(whyNotConnected)) }
        }
        return .success(Run(kind: kind, began: link.generation))
    }

    /// Whether a run may go on: nil when it may, or why it stops there, with nothing sent. Asked before each
    /// recording, and again before each request for a recording after the first (`delete(_:in:)`), in the order
    /// a single write keeps, a run being so many of them:
    ///
    /// 1. A check of the recorder that is out is heard first. It may be waking the recorder, which counts as not
    ///    answering until the waking is over, and a run waits for it and goes on by what it found, where a
    ///    single operation pressed meanwhile is turned away at its door. A check that said no -- silence, a
    ///    waking the recorder turned away, another recorder answering, the recorder let go of -- stops the run,
    ///    with what it left on the line.
    /// 2. The doors of a single protect (`protect(_:_:keep:)`), which leave the line as it was: no recorder's
    ///    client in hand, the recorder known to be away, or nothing that can be written to it (`canBeAsked`),
    ///    each that the app is not connected (`whyNotConnected`). Whatever the run does: a scan only reads, and
    ///    a read of a list has no such door, but what a scan reads is kept in the cache for good, under a number
    ///    each recorder gives out for itself, and a text read from the wrong recorder is not put right by the
    ///    next connect as a list is.
    /// 3. The recorder is made sure of (`DeviceLink.check`), like anything else the reader asks for: one asleep
    ///    since it last answered would otherwise cost the recording a timeout, and every one after it another.
    ///    Inside a run it asks nothing as a rule, the recorder having answered a moment ago; after a check
    ///    that heard something in place of the recorder saying which it is, it asks however lately the recorder
    ///    answered (`DeviceLink.checksAgain`). A no stops the run, with what the check left on the line.
    /// 4. Nothing goes after a check that heard something in place of the recorder saying which it is -- busy
    ///    with somebody else, a fault (`DeviceLink.mayBeSent`): the run stops with what was heard, which goes on
    ///    the line as well, being the recorder's answer, as for a single write (`whyNotSent`). A scan stops the
    ///    same way, by the rule of a list's read, which fails with what the check heard: its text is kept.
    ///
    /// Not to be taken for a recording the recorder was too busy to answer for: that one request, turned down
    /// through the client's tries, passes the recording over and the run goes on.
    ///
    /// A run is for the recorder it began with (`Run`). Let go of since -- another recorder answered a check, or
    /// the app let go of it over a cache it could not make over to the one that answered -- the run stops, with
    /// nothing asked, nothing written on the line, which is the newcomer's or says already why, and nobody lost:
    /// why is what a single write says then (`whyLetGo`). Asked after the wait of 1, ahead of what that check
    /// found, so that a check which ended on another recorder is said so and not as a check that failed; and
    /// again after the check of 3, which can itself be what hears the other recorder.
    public func mayGoOn(_ run: Run) async -> RunStop? {
        await mayGoOn(since: run.began) { link in
            guard link.client is RecorderClient, !link.session.unreachable, self.canBeAsked(on: link) else {
                return .said(self.whyNotConnected)
            }
            return nil
        }
    }

    /// The same asking by the count alone, which is all of a run that it reads (`DeviceLink.generation`, as
    /// noted when the requests began), and with the doors handed in: for whatever else is so many requests of
    /// one recorder, asked one after another. That is a refresh of the guide (`refreshGuide`), which has a door
    /// more than a run and says another thing where one is shut. `shut` is asked with the link where the doors
    /// stand in the order, 2, and says why one is shut, or nil with every door open.
    func mayGoOn(since began: Int, shut: @MainActor (DeviceLink) -> RunStop?) async -> RunStop? {
        guard let link else { return .said(Self.notConnected) }
        var found: NotUp?
        if let check = link.wakeCheck { found = await check.value }
        guard !link.letGo(since: began) else { return .said(whyLetGo(on: link)) }
        guard found == nil else { return whatTheLinkSaid(on: link) }
        if let why = shut(link) { return why }
        let check = await link.check(evenIfRecent: link.checksAgain)
        guard !link.letGo(since: began) else { return .said(whyLetGo(on: link)) }
        guard case .up = check else { return whatTheLinkSaid(on: link) }
        guard link.mayBeSent else { return .said(whyNotSent(on: link)) }
        return nil
    }

    /// What stops a run after a check that said no, before a recording (`mayGoOn`) or before one of its requests
    /// (`asked(in:_:_:)`): what that check left on the host's line of what went wrong, or that the app is not
    /// connected where it left nothing, as a write's result says a check's no again (`altered`). A refresh of
    /// the guide says the same where a door of its own is found shut (`refreshGuide`).
    func whatTheLinkSaid(on link: DeviceLink) -> RunStop {
        .said(link.owner?.problem ?? whyNotConnected)
    }

    // MARK: - one recording of a run

    /// Deletes one recording of a run, and says what that came to. A recording that cannot be deleted now, by
    /// the rule a single delete's door and the screens ask (`whyNot(deleting:usb:)`) -- still being recorded, or
    /// protected -- is passed over with that rule's sentence and nothing asked: the screens offer neither to a
    /// run, but a row can have changed since it was chosen. That rule's first part, a USB disk gone from the slot,
    /// is no reason to go on to the next recording: the run stops at the first of that disk's rows, with
    /// nothing asked of it (`waitForTheDisk`).
    ///
    /// The recorder answers success for an id it no longer has. So the recording is asked about first: an id the
    /// recorder does not know comes back as UPnP error 820, which means it went away on its own and there is
    /// nothing to report as an error. And the delete is sent only once that question has been answered. When the
    /// recorder turns the question down otherwise -- busy with somebody else through the client's tries, a fault,
    /// an answer that cannot be read -- nothing is known of whether the recording is still there, and a delete
    /// sent all the same would come back as done for one already gone and be counted so: the recording is passed
    /// over with what the recorder said, and the run goes on.
    ///
    /// Each of the two is asked as a single write is (`asked(in:_:_:)`). Between them the run asks again whether
    /// it may go on (`mayGoOn`), as before each recording: a check of the recorder that came in behind the
    /// question is waited for, and heard, before the delete is handed over, and a no stops the run with the
    /// recording neither deleted nor passed over.
    ///
    /// Silence is a stop and not a recording passed over (`RunStop.silent`): a recorder gone to sleep part way
    /// through would otherwise turn every recording left into one passed over, each after a thirty-second
    /// timeout. The run stops at the first, and does not send that recording again: a write that met silence may
    /// have arrived all the same, which the line then says (`mayHaveArrived`), as after a single delete. Silence
    /// to the question asked first stops the run as well, the delete not sent: nothing has been deleted yet, but
    /// the delete would only wait out the same silence; it is said as a read's.
    public func delete(_ title: RecordedTitle, in run: Run) async -> ItemCame {
        if let why = Self.whyNot(deleting: title, usb: title.readFrom) { return .passedOver(why) }

        let asking = await asked(in: run, .aWrite(sending: nil)) {
            try await self.waitForTheDisk(of: title, handed: $0, since: run.began).titleDetail(id: title.id)
        }
        switch asking {
        case .went:
            break
        case .refused(.unknownItem, _):
            return .gone
        case .refused(_, let why):
            return .passedOver(why)
        case .stopped(let stop):
            return .stopped(stop)
        }

        if let stop = await mayGoOn(run) { return .stopped(stop) }
        switch await asked(in: run, .aWrite(sending: Self.mayHaveArrived), { try await $0.deleteTitle(id: title.id) }) {
        case .went: return .done
        case .refused(_, let why): return .passedOver(why)
        case .stopped(let stop): return .stopped(stop)
        }
    }

    /// Why a recording is not sent to be protected, or to have its protection taken off (`on` false): it is
    /// being recorded to a USB disk, its id going as it ends, or it is already the way it should be. Nil when
    /// neither.
    public nonisolated static func whyNot(protecting title: RecordedTitle, _ on: Bool) -> String? {
        if title.idChangesWhenItEnds { return recordingOnTheUSBDisk }
        guard title.protected == on else { return nil }
        return on ? "すでに保護されています" : "保護されていません"
    }

    /// Protects one recording of a run, or takes its protection off, and says what that came to. Nothing is
    /// sent when the recording is already the way it should be (`whyNot(protecting:_:)`). Silence stops the run,
    /// as for `delete(_:in:)`, the line saying that the protect may have arrived, and so does a USB disk gone from
    /// the slot (`waitForTheDisk`).
    public func protect(_ title: RecordedTitle, _ on: Bool, in run: Run) async -> ItemCame {
        if let why = Self.whyNot(protecting: title, on) { return .passedOver(why) }
        let came = await asked(in: run, .aWrite(sending: Self.mayHaveArrived)) {
            try await self.waitForTheDisk(of: title, handed: $0, since: run.began)
                .updateTitle(id: title.id, protected: on)
        }
        switch came {
        case .went: return .done
        case .refused(_, let why): return .passedOver(why)
        case .stopped(let stop): return .stopped(stop)
        }
    }

    /// The text the duplicate scan compares, and caches for good, so only what the recorder actually said counts
    /// as read: two failures kept as empty texts would agree with each other and come up as copies. Silence
    /// stops the scan, as for `delete(_:in:)`, and is said as a read's; a USB disk gone from the slot stops it too
    /// (`waitForTheDisk`), the text of another disk's recording being no text to keep under this id.
    public func text(of title: RecordedTitle, in run: Run) async -> TextCame {
        let asking = await asked(in: run, .aWrite(sending: nil)) {
            try await self.waitForTheDisk(of: title, handed: $0, since: run.began).titleDetail(id: title.id).summary
        }
        switch asking {
        case .went(let text): return .read(text)
        case .refused(.unknownItem, _): return .gone
        case .refused(_, let why): return .failed(why)
        case .stopped(let stop): return .stopped(stop)
        }
    }

    /// What one request of a run came to, as a run tells it (`asked(in:_:_:)`).
    private enum AskedInARun<T> {
        /// The recorder answered, and what it brought back.
        case went(T)
        /// The recorder answered and turned the request down, or with something that cannot be read: what kind
        /// of refusal the recorder's client made of it, and what it said, in the recorder's words or as the
        /// error describes itself. For the run to say of that recording; said nowhere else.
        case refused(DeviceFailure?, String)
        /// The run stops, and why.
        case stopped(RunStop)
    }

    /// One request of a run, asked as anything else that acts on the recorder is (`asked`) -- the recorder made
    /// sure of, nothing sent to one let go of or heard in place of saying which it is, silence said once through
    /// the link -- under no line, and leaving the line of what went wrong to what stops the run: a recording
    /// done or passed over neither clears it nor writes on it. `asking` gives the sentence for silence: that it
    /// may have arrived, for a delete or a protect; none for the question a delete asks first and for a scan's
    /// text, which change nothing and whose silence is said as a read's. Those two are asked as something that
    /// acts on the recorder all the same, as playing is: a delete rests on the one, and the other is kept for
    /// good, so neither goes after a check that heard something else.
    ///
    /// `asked` hands back alike what a run tells apart -- a recording to pass over and a run to stop, an answer
    /// for the recorder in play and one for a recorder let go of -- so what it handed back is read here:
    ///
    /// - Not sent -- the recorder let go of, something heard in its place by the check, a client no attach went
    ///   through: the run stops, with why, which is the sentence a single write is turned away with.
    /// - The check before it said no: the run stops, with what that check left on the line (`whatTheLinkSaid`).
    /// - Silence: the run stops (`RunStop.silent`). The link has said it and lost the recorder
    ///   (`DeviceLink.say`), by the count the run began with: across a let-go, silence on something sent is
    ///   still said, since it may have arrived, and loses nobody; silence on the other two is neither said nor
    ///   taken.
    /// - Refused -- busy with somebody else through the client's tries, a fault, an answer that cannot be read:
    ///   handed back for the run to say of that recording, which is passed over, and the run goes on. A check
    ///   that heard the recorder busy never comes back as this: what is asked here is not sent after one.
    /// - Answered. A request sent before the recorder was let go of is answered also once it has been, when
    ///   `asked` still says that it went through, as it does of a single write (one that waited in the client's
    ///   queue meanwhile is not sent, and stops the run as not sent). A run does not: it reads the count itself,
    ///   for an answer and for a refusal, and stops, saying
    ///   why (`whyLetGo`), so that the caller counts nothing, takes no row out of a list that is the newcomer's
    ///   by then, and keeps no text.
    ///
    /// The count is asked before `asked` as well, as it is before a run's own check (`mayGoOn`): a run notes it
    /// long before a request, and nothing of it is to reach a recorder taken up since, not the check either.
    private func asked<T>(in run: Run, _ asking: Asking,
                          _ work: @MainActor (RecorderClient) async throws -> T) async -> AskedInARun<T> {
        guard let link else { return .stopped(.said(Self.notConnected)) }
        guard !link.letGo(since: run.began) else { return .stopped(.said(whyLetGo(on: link))) }
        let came = await asked(nil, asking, on: link, since: run.began, leavingTheLine: true) { _, client in
            try await work(client)
        }
        switch came {
        case .notSent(let why):
            return .stopped(.said(why))
        case .failed(.notSent):
            return .stopped(whatTheLinkSaid(on: link))
        case .failed(.silentAfterSending):
            return .stopped(.silent(afterSending: true))
        case .failed(.silentOnARead):
            return .stopped(.silent(afterSending: false))
        case .failed(.letGoMeanwhile):
            return .stopped(.said(whyLetGo(on: link)))
        case .failed(.refused(let kind, let sentence)):
            guard !link.letGo(since: run.began) else { return .stopped(.said(whyLetGo(on: link))) }
            return .refused(kind, sentence)
        case .went(let value):
            guard !link.letGo(since: run.began) else { return .stopped(.said(whyLetGo(on: link))) }
            return .went(value)
        }
    }

    // MARK: - a run's end

    /// Ends a run. After a bulk delete that deleted something (`deleted`, how many) and that nothing stopped on
    /// the recorder's account (`stopped`) -- it came to the end of its recordings, or the reader pressed 中止 --
    /// the free space is read again and kept in the session for the screens, as after a single delete
    /// (`learnTheFreeSpace`), on the client the link has in hand. It is only shown, so a recorder that will not
    /// say leaves it unknown (`storage(of:)`) and the run it follows is not said to have failed. Silence is said
    /// as any read's, on the line of what went wrong, and loses the recorder.
    ///
    /// Nothing is read after a run that deleted nothing, which has freed nothing, nor after one the recorder
    /// stopped, whatever it had deleted: that read makes no check of its own, and would go straight behind a
    /// check that heard the recorder busy, or wait out its timeout on a recorder that has just gone silent.
    ///
    /// Nor is a run that nothing stopped sure of its recorder as it ends: nothing has made sure of it since
    /// the run's last request was answered. So the read is made only where a check would have nothing to ask,
    /// which is the read's own rule, for whoever asks (`learnTheFreeSpace`): not beside a check that is out or
    /// after one that heard something in the recorder's place, and not of a recorder known to be away or quiet
    /// a long while. The free space shown then stays as it was last read, until the recordings are next read.
    ///
    /// Not for a recorder the run did not begin with (`Run`): let go of since, nothing is read, the free space
    /// being another recorder's or nobody's to ask. Let go of while the read is out, what comes back is not
    /// kept in the session, which is the newcomer's by then, and its silence is neither said nor taken.
    public func end(_ run: Run, deleted: Int, stopped: RunStop?) async {
        guard case .delete = run.kind, deleted > 0, stopped == nil, let link, !link.letGo(since: run.began),
              let client = link.client as? RecorderClient else { return }
        await learnTheFreeSpace(on: client, link, since: run.began)
    }
}
