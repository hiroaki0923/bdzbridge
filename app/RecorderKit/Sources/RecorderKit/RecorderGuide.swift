import Foundation

/// Which of the guide's broadcasting types a refresh is asked for (`RecorderDriver.refreshGuide`).
public enum GuideAsked: Sendable {
    /// Every type the app keeps (`GuideRefresh.broadcastingTypes`).
    case all
    /// These, in this order.
    case only([String])
}

/// What a refresh of the guide came to (`RecorderDriver.refreshGuide`), for the app to keep and a screen to say:
/// the screen it was asked for on says `said`, in an alert, the line of what went wrong not being on every
/// screen that asks. What was sent and failed is on that line as well, as for any operation, and stays there for
/// the refresh a connect makes with nobody having pressed.
public struct GuideRefreshed: Sendable, Equatable {
    /// Whether the recorder was asked and the refresh ran to its end, types that failed among it or not. False
    /// when nothing was asked -- turned away at the door, or by the check before it -- and when silence stopped it.
    public var wentThrough = false
    /// How many programmes were stored, over every type; the types the recorder answered for; and the types
    /// that could not be fetched or stored, each with why (`GuideRefresh.Outcome`). Of a refresh stopped by
    /// silence, what came before the silence.
    public var stored = 0
    public var answered: [String] = []
    public var failed: [GuideRefresh.Failure] = []
    /// What there is to say of it, nil for nothing. Of a refresh that went through: a line for each type that
    /// failed, as the step wrote them on the host's line of what went wrong. Turned away at the door: that the
    /// app is not connected. Stopped by silence: a line for each type that failed before it, which are not on
    /// the host's line, and then that the recorder did not answer, as a read says it. Otherwise -- the check
    /// before it said no -- whatever stands on the host's line of what went wrong, or that the app is not
    /// connected where the line is empty: what the check wrote there if it wrote, and if it did not, what an
    /// earlier operation left. That is the reservations' rule (`Reserved`), and no more is promised of it: a
    /// check that ends on a recorder let go of meanwhile writes nothing, and one that ends waiting for the
    /// local network permission empties the line.
    public var said: String?

    /// What a refresh comes to that was not asked for at all, its host having no recorder's driver to ask:
    /// nothing asked, and that the app is not connected (`RecorderDriver.notConnected`). Only the driver makes
    /// any other.
    public static let notConnected = GuideRefreshed(said: RecorderDriver.notConnected)
}

/// The guide fetched from the recorder by hand and at a connect: the step, and what it says on the host's
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
    /// Silence stops it, and what came before the silence is handed back with it: the types that answered,
    /// what was stored, the types that failed. It is said here, through the link, as the round of what waits
    /// says its own (`say(stopped:on:)`): as any read's, the recorder lost, while the recorder is not known to
    /// be away already (`takesSilenceOnARead`). The line of what went wrong is not cleared then, and holds the
    /// silence alone, or what it held where the silence is not said; the types that failed before it are said
    /// in what is handed back.
    ///
    /// Nothing is asked without a recorder's client, without the host's cache, or with the recorder known to be
    /// away, and nothing is said on the line then. The files are asked of the client in hand at that door, and
    /// what comes goes into the cache in hand there. After a check that heard something in place of the recorder
    /// saying which it is, the guide is fetched all the same, and nobody is asked again who answers.
    ///
    /// `stored` is called with each type once its programmes and logos are in the cache, and waited for before
    /// the next type is asked for, so that a screen can show the type without waiting for the rest. A type
    /// stored before the recorder fell silent over its logos is not reported to it.
    public func refreshGuide(_ which: GuideAsked,
                             stored: @escaping @MainActor @Sendable (String) async -> Void) async -> GuideRefreshed {
        guard let link, let client = link.client as? RecorderClient, let store = link.owner?.cache,
              !link.session.unreachable else { return GuideRefreshed(said: whyNotConnected) }
        let types: [String]
        switch which {
        case .all: types = GuideRefresh.broadcastingTypes
        case .only(let these): types = these
        }
        // Read once, as `DeviceLink.run` reads it: what went wrong is cleared on the host the refresh began under.
        let owner = link.owner
        let ran = await link.underALine(Self.guideLine) { line -> GuideRefresh.Outcome? in
            guard case .up = await link.check() else { return nil }
            // In a task of its own, because the guide is the app's rather than a screen's. A pull-down that
            // connected is cancelled when its screen goes away, and the refresh stops between types when it
            // is cancelled -- which is for the overnight run, whose time runs out.
            let refresh = Task {
                await GuideRefresh.run(client: client, store: store, types: types, onType: { broadcasting in
                    if let line { link.owner?.updateActivity(line, to: Self.guideLine(for: broadcasting)) }
                }, onStored: stored)
            }
            let outcome = await refresh.value
            if outcome.stopped == .silent {
                _ = link.say(.silentOnARead(sentence: self.noAnswerLine))
            } else {
                owner?.problem = nil
            }
            return outcome
        }
        // The check said no, and has said why.
        guard let outcome = ran else { return GuideRefreshed(said: link.owner?.problem ?? whyNotConnected) }
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
}
