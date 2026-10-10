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

/// Why a run stopped before its end, or did not begin, on the recorder's account. An `Error` only so that it can
/// be the failure of `RecorderDriver.beginRun`'s `Result`, which asks that of it; nothing throws it.
public enum RunStop: Error, Sendable, Equatable {
    /// Turned away, with a sentence. For a run that did not begin, that the app is not connected
    /// (`RecorderDriver.beginRun`). For one stopped before a recording (`RecorderDriver.mayGoOn`), whatever
    /// stands on the host's line of what went wrong, or that the app is not connected where the line is empty:
    /// what a check wrote there if one wrote, and if none did, what an earlier operation left.
    case said(String)
    /// The recorder said nothing to a request of the run. `afterSending` says whether that request was one that
    /// changes the recorder: it may have arrived all the same.
    case silent(afterSending: Bool)

    /// The sentence handed back with a run turned away, as `.said` has it. Nil for silence, which what the job
    /// says once it has stopped says itself (`RecorderDriver.outcome`).
    public var said: String? {
        if case .said(let why) = self { why } else { nil }
    }
}

/// Where a run stands as it asks whether it may go on (`RecorderDriver.mayGoOn`): before its first recording,
/// before a later one, or before one it waited for while the app was away.
public enum RunMoment: Sendable {
    case first, next, afterAReturn
}

/// The recorder's work over many recordings, one request at a time because that is all the recorder will take:
/// the bulk delete, the bulk protect and the scan for duplicates. What is here is the recorder's side of a run:
/// its words, and when it may begin, go on and what it reads as it ends. The loop around the recordings, its job
/// with the progress and the stop button, the wait while the app is away, one recording's requests and the lists
/// are the app's.
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
    /// it changed -- a scan, how many it looked at (`done`) -- whether it came to its end, was stopped by 中止
    /// (`cancelled`) or lost the recorder (`lost`), which is said whether or not 中止 was tapped as well, and how
    /// many it passed over.
    public nonisolated static func outcome(of kind: RunKind, done: Int, changed: Int, passedOver: Int,
                                           cancelled: Bool, lost: Bool) -> String {
        if case .scanning = kind {
            let head = lost ? "\(done) 件まで調べたところで、レコーダーの応答がなくなったため中止しました"
                : cancelled ? "\(done) 件まで調べて中止しました" : "\(done) 件の確認が完了しました"
            return passedOver == 0 ? head : head + "（\(passedOver) 件は番組内容を取得できず、比べていません）"
        }
        let verb = verb(of: kind)
        let head = lost ? "\(changed) 件を\(verb)したところで、レコーダーの応答がなくなったため中止しました"
            : cancelled ? "\(changed) 件を\(verb)したところで中止しました" : "\(changed) 件を\(verb)しました"
        return passedOver == 0 ? head : head + "（\(passedOver) 件はスキップ）"
    }

    /// Why a recording was passed over that the list no longer holds by the time the run comes to it.
    public nonisolated static let notInTheList = "一覧に見つかりません"

    // MARK: - a run's recorder

    /// Begins a run of `kind`: the run, for its steps to be handed back with, or why none begins. The one door
    /// is a recorder's client in hand, the client the run's requests then go on. A run begins beside a connect
    /// under way, on a client that has not heard which recorder answers it, and with the recorder known to be
    /// away: whether its first recording may go is `mayGoOn`'s to say. Nothing is asked, and nothing said.
    public func beginRun(_ kind: RunKind) -> Result<Run, RunStop> {
        guard let link else { return .failure(.said(Self.notConnected)) }
        guard let client = link.client as? RecorderClient else { return .failure(.said(whyNotConnected)) }
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
    /// where the line is empty. That is what a check wrote there, when one did. A no to `.next` with the recorder
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
