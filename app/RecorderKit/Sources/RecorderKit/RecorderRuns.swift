import Foundation

/// What a run over many recordings does to each of them: deletes it, protects it or takes its protection off,
/// or, for the scan for duplicates, asks the recorder what it is about, which changes nothing.
public enum RunKind: Sendable, Equatable {
    case delete
    case protecting(Bool)
    case scanning
}

/// What the recorder's driver knows of a run between two of its recordings: what the run does, the count of
/// recorders let go of as it began (`DeviceLink.generation`), and the client in hand then, which the run's
/// requests go on. Made as the run begins (`RecorderDriver.beginRun`) and handed back with each of its steps.
public struct Run: Sendable {
    let kind: RunKind
    let began: Int
    let client: RecorderClient
}

/// Why a run stopped before its end, or did not begin, on the recorder's account: what its job keeps once it
/// has stopped, for what it says then (`RecorderDriver.outcome`) and for the line under that. An `Error` only so
/// that it can be the failure of `RecorderDriver.beginRun`'s `Result`, which asks that of it; nothing throws it.
public enum RunStop: Error, Sendable, Equatable {
    /// Turned away, with a sentence. For a run that did not begin, that the app is not connected
    /// (`RecorderDriver.beginRun`). For one stopped before a recording (`RecorderDriver.mayGoOn`), whatever
    /// stands on the host's line of what went wrong, or that the app is not connected where the line is empty:
    /// what a check wrote there if one wrote, and if none did, what an earlier operation left.
    case said(String)
    /// The recorder said nothing to a request of the run. `afterSending` says whether that request was one that
    /// changes the recorder: it may have arrived all the same.
    case silent(afterSending: Bool)

    /// The sentence handed back with a run turned away, as `.said` has it, for the job to show under what it
    /// says once it has stopped. Nil for silence, which what the job says then says itself
    /// (`RecorderDriver.outcome`).
    public var said: String? {
        if case .said(let why) = self { why } else { nil }
    }
}

/// Where a run stands as it asks whether it may go on (`RecorderDriver.mayGoOn`): before its first recording,
/// before a later one, or before one it waited for while the app was away.
public enum RunMoment: Sendable {
    case first, next, afterAReturn
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
    /// The run stops at this recording, and why (`RunStop`).
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
    /// A run that deletes or protects has the doors of a single protect (`protect(_:_:keep:)`), as far as they
    /// go here: the link gone, no recorder's client in hand, or the recorder known to be away, each that the
    /// app is not connected (`whyNotConnected`). It still begins beside a connect under way, and on a client
    /// that has not heard which recorder answers it.
    ///
    /// A scan has the one door, a recorder's client in hand, the client its requests then go on: one whose
    /// texts are all in the cache asks the recorder nothing, and comes to its end with the recorder known to be
    /// away. Whether a text may be read is `mayGoOn`'s to say, asked before the first that is to be.
    public func beginRun(_ kind: RunKind) -> Result<Run, RunStop> {
        guard let link else { return .failure(.said(Self.notConnected)) }
        guard let client = link.client as? RecorderClient else { return .failure(.said(whyNotConnected)) }
        if kind != .scanning, link.session.unreachable { return .failure(.said(whyNotConnected)) }
        return .success(Run(kind: kind, began: link.generation, client: client))
    }

    /// Whether a run may go on to a recording: nil when it may, or why it stops there, with nothing sent. Asked
    /// before each recording, by where the run stands:
    ///
    /// - `.first`, before its first recording: the recorder is made sure of, like anything else the reader asks
    ///   for (`DeviceLink.ensureUp`) -- one asleep since the list was read would otherwise cost the first
    ///   recording a timeout, and every one after it another. A check that is out is waited for in place of a
    ///   probe of the run's own.
    /// - `.next`, before each recording after it: a check of the recorder that is out is heard first. It may be
    ///   waking the recorder, which counts as not answering until the waking is over, and its verdict may be
    ///   that another recorder answers here now. Then the run goes on unless the recorder is known to be away:
    ///   silence met by anything stops a run, not only silence met by the run.
    /// - `.afterAReturn`, before a recording the run waited for while the app was away: a check that is out is
    ///   heard -- a screen coming back may be waking the recorder already, and its outcome is the one to go by
    ///   -- then the recorder, which has had all that time to fall asleep, is made sure of, and then as `.next`.
    ///
    /// A no hands back whatever stands on the host's line of what went wrong, or that the app is not connected
    /// where the line is empty, as a write's result says a check's no again (`altered`): the run's job shows it
    /// as why the run stopped. That is what a check wrote there, when one did. A no to `.next` with the recorder
    /// known to be away and no check out hands back what an earlier operation left, which need not be about the
    /// run. Nothing is written on the line here.
    public func mayGoOn(_ run: Run, _ moment: RunMoment) async -> RunStop? {
        guard let link else { return .said(Self.notConnected) }
        switch moment {
        case .first:
            return await link.ensureUp() ? nil : whatTheLinkSaid(on: link)
        case .afterAReturn:
            if let check = link.wakeCheck { _ = await check.value }
            guard await link.ensureUp() else { return whatTheLinkSaid(on: link) }
            fallthrough
        case .next:
            if let check = link.wakeCheck { _ = await check.value }
            return link.session.unreachable ? whatTheLinkSaid(on: link) : nil
        }
    }

    /// What a no of `mayGoOn` hands back: whatever stands on the host's line of what went wrong, or that the app
    /// is not connected where the line is empty.
    private func whatTheLinkSaid(on link: DeviceLink) -> RunStop {
        .said(link.owner?.problem ?? whyNotConnected)
    }

    // MARK: - one recording of a run

    /// Deletes one recording of a run, and says what that came to. A recording that cannot be deleted now, by
    /// the rule a single delete's door and the screens ask (`whyNot(deleting:)`) -- still being recorded, or
    /// protected -- is passed over with that rule's sentence and nothing asked: the screens offer neither to a
    /// run, but a row can have changed since it was chosen.
    ///
    /// The recorder answers success for an id it no longer has. So the recording is asked about first: an id the
    /// recorder does not know comes back as UPnP error 820, which means it went away on its own and there is
    /// nothing to report as an error. Anything else that question comes to, short of silence, is not worth
    /// giving up on: the delete is sent, and says what went wrong.
    ///
    /// Silence is a stop and not a recording passed over (`RunStop.silent`): a recorder gone to sleep part way
    /// through would otherwise turn every recording left into one passed over, each after a thirty-second
    /// timeout. The run stops at the first, and does not send that recording again: a write that met silence may
    /// have arrived all the same. Silence to the question asked first stops the run as well, the delete not
    /// sent: nothing has been deleted yet, but the delete would only wait out the same silence.
    public func delete(_ title: RecordedTitle, in run: Run) async -> ItemCame {
        if let why = Self.whyNot(deleting: title) { return .passedOver(why) }

        switch await asked(in: run, sending: false, { try await $0.titleDetail(id: title.id) }) {
        case .went: break
        case .refused(let error): if (error as? any DeviceError)?.failure == .unknownItem { return .gone }
        case .stopped(let stop): return .stopped(stop)
        }

        switch await asked(in: run, sending: true, { try await $0.deleteTitle(id: title.id) }) {
        case .went: return .done
        case .refused(let error): return .passedOver(Self.inTheRecordersWords(error))
        case .stopped(let stop): return .stopped(stop)
        }
    }

    /// Why a recording is not sent to be protected, or to have its protection taken off (`on` false): it is
    /// already the way it should be. Nil when it is not.
    public nonisolated static func whyNot(protecting title: RecordedTitle, _ on: Bool) -> String? {
        guard title.protected == on else { return nil }
        return on ? "すでに保護されています" : "保護されていません"
    }

    /// Protects one recording of a run, or takes its protection off, and says what that came to. Nothing is
    /// sent when the recording is already the way it should be (`whyNot(protecting:_:)`). Silence stops the run,
    /// as for `delete(_:in:)`.
    public func protect(_ title: RecordedTitle, _ on: Bool, in run: Run) async -> ItemCame {
        if let why = Self.whyNot(protecting: title, on) { return .passedOver(why) }
        switch await asked(in: run, sending: true, { try await $0.updateTitle(id: title.id, protected: on) }) {
        case .went: return .done
        case .refused(let error): return .passedOver(Self.inTheRecordersWords(error))
        case .stopped(let stop): return .stopped(stop)
        }
    }

    /// The text the duplicate scan compares, and caches for good, so only what the recorder actually said counts
    /// as read: two failures kept as empty texts would agree with each other and come up as copies. Silence
    /// stops the scan, as for `delete(_:in:)`.
    public func text(of title: RecordedTitle, in run: Run) async -> TextCame {
        switch await asked(in: run, sending: false, { try await $0.titleDetail(id: title.id).summary }) {
        case .went(let text):
            return .read(text)
        case .refused(let error):
            if (error as? any DeviceError)?.failure == .unknownItem { return .gone }
            return .failed(Self.inTheRecordersWords(error))
        case .stopped(let stop):
            return .stopped(stop)
        }
    }

    /// What the recorder said as it turned a request down, or what else went wrong with its answer.
    private nonisolated static func inTheRecordersWords(_ error: any Error) -> String {
        (error as? any DeviceError)?.explanation ?? String(describing: error)
    }

    // MARK: - a run's end

    /// Ends a run. After one that deletes, the free space is read again, on the run's client, and kept in the
    /// session for the screens -- unless the recorder is known to be away, which would cost the read its
    /// timeout. It is only shown, so a recorder that will not say leaves it unknown (`storage(of:)`) and the run
    /// it follows is not said to have failed. Silence is still silence: it loses the recorder, with nothing
    /// said on the line. Whatever `deleted`, the number of recordings the run deleted, and `stopped`, what
    /// stopped it if anything did: the free space is read after a run that deleted nothing, and after one the
    /// recorder stopped while it is not known to be away.
    public func end(_ run: Run, deleted: Int, stopped: RunStop?) async {
        guard case .delete = run.kind, let link, !link.session.unreachable else { return }
        do {
            link.session.learned(storage: try await Self.storage(of: run.client))
        } catch {
            link.lost()
        }
    }
}
