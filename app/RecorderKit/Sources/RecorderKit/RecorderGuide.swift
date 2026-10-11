import Foundation

/// Which of the guide's broadcasting types a refresh is asked for (`RecorderDriver.refreshGuide`).
public enum GuideAsked: Sendable {
    /// Every type the app keeps (`GuideRefresh.broadcastingTypes`).
    case all
    /// These, in this order.
    case only([String])
    /// The types the recorder has not answered for since this moment, or ever, by the marks the cache holds as
    /// the refresh comes to fetch (`GuideRefresh.staleTypes(_:since:types:)`): none, where every type has been
    /// answered for since.
    case notAnsweredSince(Date)
}

/// What a refresh of the guide came to (`RecorderDriver.refreshGuide`, `refreshGuideByHand`), for the app to
/// keep and a screen to say: the screen it was asked for on says `said`, in an alert, the line of what went
/// wrong not being on every screen that asks. What was sent and failed is on that line as well, as for any
/// operation, and stays there for the refresh a connect makes with nobody having pressed.
public struct GuideRefreshed: Sendable, Equatable {
    /// Whether the refresh ran to its end, types that failed among it or not, though nothing may have been
    /// behind: one that comes to fetch and finds every type answered for already asks for no file, and went
    /// through. False when it was turned away -- at the door, or by the check before it -- and when silence
    /// stopped it.
    public var wentThrough = false
    /// How many programmes were stored, over every type; the types the recorder answered for; and the types
    /// that could not be fetched or stored, each with why (`GuideRefresh.Outcome`). Of a refresh stopped by
    /// silence, what came before the silence.
    public var stored = 0
    public var answered: [String] = []
    public var failed: [GuideRefresh.Failure] = []
    /// What there is to say of it, nil for nothing. Of a refresh that went through: a line for each type that
    /// failed, as the step wrote them on the host's line of what went wrong. Turned away at the door: that the
    /// app is not connected. A press whose own connect let go of the recorder: what a write says then; and one
    /// whose own connect came to no recorder that can be asked: what that connect left on the host's line, or
    /// that the app is not connected where it left nothing (`refreshGuideByHand`). Stopped by silence: a line
    /// for each type that failed before it, which are not on the host's line, and then that the recorder did
    /// not answer, as a read says it. Otherwise -- the check before it said no -- whatever stands on the
    /// host's line of what went wrong, or that the app is not connected where the line is empty: what the
    /// check wrote there if it wrote, and if it did not, what an earlier operation left. That is the
    /// reservations' rule (`Reserved`), and no more is promised of it: a check that ends on a recorder let go
    /// of meanwhile writes nothing, and one that ends waiting for the local network permission empties the
    /// line. And where that check heard something in place of the recorder saying which it is, nothing having
    /// been asked for: what it heard, in the recorder's words, as the step wrote it on the host's line.
    public var said: String?

    /// What a refresh comes to that was not asked for at all, its host having no recorder's driver to ask:
    /// nothing asked, and that the app is not connected (`RecorderDriver.notConnected`). Only the driver makes
    /// any other.
    public static let notConnected = GuideRefreshed(said: RecorderDriver.notConnected)
}

/// The guide fetched from the recorder by hand and at a connect: the step, which a connect asks, the press of
/// 番組表を更新, which connects first where the recorder cannot be asked, and what each says on the host's
/// screen. What the screens show of the cache, and when they read it again, is the app's; fetching the types in
/// turn is `GuideRefresh.run`, which the overnight run asks as well.
extension RecorderDriver {
    /// The line on screen while the guide is fetched, and as each type of it is.
    public nonisolated static let guideLine = "番組表を取得中"

    public nonisolated static func guideLine(for broadcasting: String) -> String {
        "\(guideLine) (\(Codes.broadcastingLabel[broadcasting] ?? broadcasting))"
    }

    /// Said of a type that could not be fetched or stored, a line to a type.
    public nonisolated static func guideFailed(_ failure: GuideRefresh.Failure) -> String {
        "\(Codes.broadcastingInSentence(failure.broadcasting))の番組表：\(failure.reason)"
    }

    /// Downloads the broadcasting types asked for and replaces what the cache holds for each. One operation, as
    /// `DeviceLink.run` makes one, written on its parts: under a line of its own, which says the type being
    /// fetched, the recorder made sure of first, and going through clears the line of what went wrong. A type
    /// that fails is passed over (`GuideRefresh.run`) and the recorder kept; the types that failed are then
    /// written on that line, a line to a type, and are fetched again at the next connect.
    ///
    /// The line of what went wrong is cleared only by a refresh that asked the recorder for a type. One that
    /// came to fetch and found nothing to -- every type answered for since the moment it was asked with
    /// (`GuideAsked.notAnsweredSince`) -- went through, and leaves the line as it stands: nothing was asked
    /// that could have put right what the line says.
    ///
    /// Silence stops it, and what came before the silence is handed back with it: the types that answered,
    /// what was stored, the types that failed. It is said here, through the link, as the round of what waits
    /// says its own (`say(stopped:on:)`): as any read's, the recorder lost, while the recorder is not known to
    /// be away already (`takesSilenceOnARead`). The line of what went wrong is not cleared then, and holds the
    /// silence alone, or what it held where the silence is not said; the types that failed before it are said
    /// in what is handed back.
    ///
    /// Nothing is asked without a recorder's client, without the host's cache, with the recorder known to be
    /// away, or of a recorder that has not said which it is (`canBeAsked`) -- a connect under way, or the last
    /// one answered busy with somebody else, the client in hand never having heard who answers it. The door of
    /// a write, though the guide is read: what is fetched goes into the cache for good, and the files' own
    /// server names no recorder. Turned away, the refresh says that the app is not connected
    /// (`whyNotConnected`), and the line of what went wrong is left as it was. The files are asked of the client
    /// in hand at that door, and what comes goes into the cache in hand there.
    ///
    /// After a check that heard something in place of the recorder saying which it is -- busy with somebody
    /// else, a fault (`DeviceLink.heardInstead`) -- nothing is fetched, as no list is read after one
    /// (`reservations`): the files' server names no recorder either, and an answer that does not say which
    /// device gave it says nothing of the device asked next. The refresh fails with what was heard, which the
    /// link says on the line as a read's failure (`DeviceLink.say`) and the refresh says again in what it
    /// hands back. The check after such a check asks who answers however lately the recorder answered
    /// (`DeviceLink.checksAgain`).
    ///
    /// `stored` is called with each type once its programmes and logos are in the cache, and waited for before
    /// the next type is asked for, so that a screen can show the type without waiting for the rest. A type
    /// stored before the recorder fell silent over its logos is not reported to it.
    public func refreshGuide(_ which: GuideAsked,
                             stored: @escaping @MainActor @Sendable (String) async -> Void) async -> GuideRefreshed {
        guard let link, let (client, store) = inHandForTheGuide(on: link) else {
            return GuideRefreshed(said: whyNotConnected)
        }
        // Read once, as `DeviceLink.run` reads it: what went wrong is cleared on the host the refresh began under.
        let owner = link.owner
        let ran = await link.underALine(Self.guideLine) { line -> Result<GuideRefresh.Outcome, OperationFailure> in
            if case .notUp(let why) = await link.check(evenIfRecent: link.checksAgain) {
                return .failure(.notSent(why))
            }
            if let heard = link.heardInstead {
                return .failure(link.say(OperationFailure(heard, sending: nil), ofARead: true))
            }
            // In a task of its own, because the guide is the app's rather than a screen's. A pull-down that
            // connected is cancelled when its screen goes away, and the refresh stops between types when it
            // is cancelled -- which is for the overnight run, whose time runs out.
            let refresh = Task {
                let types = await Self.types(which, by: store)
                return await GuideRefresh.run(client: client, store: store, types: types, onType: { broadcasting in
                    if let line { link.owner?.updateActivity(line, to: Self.guideLine(for: broadcasting)) }
                }, onStored: stored)
            }
            let outcome = await refresh.value
            if outcome.stopped == .silent {
                _ = link.say(.silentOnARead(sentence: self.noAnswerLine))
            } else if !(outcome.answered.isEmpty && outcome.failed.isEmpty) {
                owner?.problem = nil
            }
            return .success(outcome)
        }
        let outcome: GuideRefresh.Outcome
        switch ran {
        case .success(let fetched):
            outcome = fetched
        case .failure(let failure):
            // What the link said of what the check heard; or the check said no, and has said why.
            return GuideRefreshed(said: failure.sentence ?? link.owner?.problem ?? whyNotConnected)
        }
        var refreshed = GuideRefreshed(wentThrough: outcome.stopped == nil, stored: outcome.stored,
                                       answered: outcome.answered, failed: outcome.failed)
        var lines = outcome.failed.map(Self.guideFailed)
        if outcome.stopped == nil {
            if !lines.isEmpty { link.owner?.problem = lines.joined(separator: "\n") }
        } else {
            lines.append(noAnswerLine)
        }
        if !lines.isEmpty { refreshed.said = lines.joined(separator: "\n") }
        return refreshed
    }

    /// The step's door: the recorder's client and the host's cache, for a refresh to ask and to write to, or
    /// nil where nothing is to be asked -- no recorder's client in hand, no cache, the recorder known to be
    /// away, or one that has not said which it is (`canBeAsked`).
    private func inHandForTheGuide(on link: DeviceLink) -> (client: RecorderClient, store: GuideStore)? {
        guard let client = link.client as? RecorderClient, let store = link.owner?.cache,
              !link.session.unreachable, canBeAsked(on: link) else { return nil }
        return (client, store)
    }

    /// The types a refresh asked for with `which` fetches, judged as it comes to fetch them. A cache whose
    /// marks cannot be read is taken as never answered for.
    private nonisolated static func types(_ which: GuideAsked, by store: GuideStore) async -> [String] {
        switch which {
        case .all: GuideRefresh.broadcastingTypes
        case .only(let these): these
        case .notAnsweredSince(let moment):
            GuideRefresh.staleTypes((try? await store.counts()) ?? [:], since: moment)
        }
    }

    /// 番組表を更新, as the reader presses it on the guide's tab and in Settings: every type, fetched from a
    /// recorder that has said which it is. What it came to, as the step hands it back.
    ///
    /// With the app not connected, or the recorder known to be away, it is turned away as the step is, with
    /// nothing asked: its buttons are not live then, and 再接続 is what the reader has. With the recorder to be
    /// asked, it is the step, for every type.
    ///
    /// Connected, and nothing can be written to the recorder (`canBeAsked`) -- its last connect the recorder
    /// answered busy with somebody else, the app being connected from the attach before, the buttons live and
    /// no 再接続 offered -- the reader has asked for it to be tried again, as by pulling a list down
    /// (`refresh(reading:)`): a connect, and then the fetch. By the step, so through its door: a connect that
    /// did not come to a recorder that can be asked has nothing fetched after it. That connect has said why on
    /// the line of what went wrong, as a check that said no has, and the press says what stands there, and
    /// that the app is not connected only where nothing does: the buttons are live there with no 再接続
    /// offered, which is where that sentence sends the reader. Nor is anything fetched after a connect that
    /// let go of the recorder, another having described itself at the address: the newcomer's connect fetches
    /// its own guide (`LinkHost.reached`), and the press says that another recorder answered (`whyLetGo`).
    ///
    /// Each file that answered is asked for once. A connect that goes through has fetched what the cache says
    /// is behind by the time it hands back (`LinkHost.reached`), so after its own connect the press asks only
    /// for the types not answered for since it began (`GuideAsked.notAnsweredSince`), by the cache's marks. A
    /// type the recorder could not give that connect has no mark, and is asked for once more by the press,
    /// which is what puts it in what the press says. The moment is noted to the whole second, as the marks are
    /// written (`GuideRefresh.toTheSecond`): kept with its fraction it would be later than a mark that connect
    /// writes within the same second, and every file would be asked for twice. So a type counts as answered
    /// for when its mark is of the second the press began in or later, whoever wrote it -- the overnight run,
    /// through a connection of its own, among them -- and is not asked for again. Not provided for: marks
    /// later than now, written while the phone's clock was ahead, which leave their types out of this press
    /// though the same press with the recorder to be asked fetches them; and a clock set back between the
    /// press and its connect's marks, after which every file is asked for twice.
    public func refreshGuideByHand(stored: @escaping @MainActor @Sendable (String) async -> Void) async
        -> GuideRefreshed {
        guard let link, link.client is RecorderClient, link.owner?.cache != nil, link.session.connected,
              !link.offline else { return GuideRefreshed(said: whyNotConnected) }
        guard !canBeAsked(on: link) else { return await refreshGuide(.all, stored: stored) }
        let began = link.generation
        let pressed = GuideRefresh.toTheSecond(Date())
        await link.connect()
        guard !link.letGo(since: began) else { return GuideRefreshed(said: whyLetGo(on: link)) }
        // The step's door, asked here for what the press says where it is shut: what the connect left.
        guard inHandForTheGuide(on: link) != nil else {
            return GuideRefreshed(said: link.owner?.problem ?? whyNotConnected)
        }
        return await refreshGuide(.notAnsweredSince(pressed), stored: stored)
    }
}
