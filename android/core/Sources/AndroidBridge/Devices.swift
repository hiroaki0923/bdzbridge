import Foundation
import Observation
import RecBridgeModel
import RecorderKit

/// The screen where a recorder is chosen, as the iOS app's tutorial chooses one: レコーダーとテレビを探す, a recorder
/// the search found, an address typed, or the demo. The televisions the search finds come with the television's
/// screens.
public struct DevicesScreen: Sendable {
    /// Whether no recorder or television has been set up: the app opens on this screen then.
    public var welcomes: Bool
    /// Whether the search holds its button, and how far it has got (`done` of `total`, both 0 when none runs).
    public var searching: Bool
    public var searched: Int64
    public var toSearch: Int64
    /// What the search came to, `failed` in red, then the line and the causes the iOS app puts under it.
    public var outcome: String
    public var outcomeFailed: Bool
    public var outcomeNote: String
    public var causes: [String]
    /// The recorder's line while the app works on it, and what went wrong with it.
    public var busy: String
    public var problem: String
    public var recorders: [FoundRecorder]
    /// Whether the recorder in play may be changed now (`AppModel.canChangeRecorder`): what the rows, the address
    /// and the demo wait for.
    public var canChoose: Bool
    /// The demo is on.
    public var demo: Bool
    /// A recorder chosen here has answered: the screen has done its work and closes, as the tutorial does.
    public var chosenAnswered: Bool
}

public struct FoundRecorder: Sendable {
    public var host: String
    /// The product, as the row's first line.
    public var name: String
    /// `192.0.2.10 · BDZ-FBT4100 · 番組表あり`.
    public var details: String
    public var inUse: Bool

    /// As the tutorial and the settings list it (`FoundRecorderRow`).
    init(_ found: RecorderDescription, inUse: Bool) {
        host = found.host
        name = found.product
        details = "\(found.host) · \(found.friendlyName)" + (found.epgCapable ? " · 番組表あり" : " · 番組表なし")
        self.inUse = inUse
    }
}

/// What a typed address comes to: the address to connect to, and what is said under the field (`warning` in red).
public struct TypedAddress: Sendable {
    public var host: String
    public var usable: Bool
    public var note: String
    public var warning: Bool
}

/// The tutorial's own state: whether a recorder chosen on it has answered yet. Not the model's: on iOS the
/// tutorial keeps it (`WelcomeView.take`), and it goes with the screen.
@MainActor @Observable
final class Choosing {
    var chosenAt: Int?

    nonisolated init() {}
}

public final class DevicesWindow: Sendable {
    let model: AppModel
    private let choosing: Choosing
    private let shown: Watched<DevicesScreen>

    init(_ model: AppModel) {
        self.model = model
        let choosing = Choosing()
        self.choosing = choosing
        shown = Watched { DevicesWindow.screen(model, choosing) }
    }

    public func read() async -> DevicesScreen { await shown.read() }
    public func observe(_ listener: some ScreenListener) { shown.watch(listener) }

    /// Looks through the subnet for a recorder and a television, both kinds at once.
    public func search() async {
        await model.scanForDevices()
    }

    /// The search ends with the screen.
    public func stopSearching() async {
        await model.stopScanning()
    }

    /// Connects to `host`, a recorder the search found or an address typed. The screen closes once the recorder has
    /// answered, in the middle of the connect: the reservations and the guide are read after that, and the screens
    /// behind can show them coming (`WelcomeView.take`).
    public func choose(_ host: String) async {
        let before = await MainActor.run { () -> Int in
            choosing.chosenAt = model.timesAttached
            return model.timesAttached
        }
        await model.adopt(host: host)
        await MainActor.run {
            if model.timesAttached == before, !model.connectBlocked { choosing.chosenAt = nil }
        }
    }

    /// The screen has closed: a choice still out is no longer this screen's to close for.
    public func closed() async {
        await MainActor.run { choosing.chosenAt = nil }
        await model.stopScanning()
    }

    /// The demo's invented recorder and guide, in a database of their own.
    public func enterDemo() async {
        await model.enterDemo()
    }

    /// Puts back what was there before the demo, and deletes the demo's guide.
    public func leaveDemo() async {
        await model.leaveDemo()
    }

    /// What `typed` comes to as an address, and what the field says of it (`RecorderAddress.Typed.note`).
    public func typed(_ typed: String) -> TypedAddress {
        let tidied = RecorderAddress.tidy(typed)
        let note = tidied.note
        return TypedAddress(host: tidied.host, usable: RecorderAddress.isUsable(tidied.host), note: note?.text ?? "",
                            warning: note?.warning ?? false)
    }

    @MainActor
    private static func screen(_ model: AppModel, _ choosing: Choosing) -> DevicesScreen {
        let outcome = model.scanOutcome
        let scanning = model.scanBlocked ? nil : model.scanning
        return DevicesScreen(
            welcomes: model.welcomes, searching: model.scanHoldsTheButton,
            searched: Int64(scanning?.done ?? 0), toSearch: Int64(scanning?.total ?? 0),
            outcome: outcome?.text ?? "", outcomeFailed: outcome?.failed ?? false,
            outcomeNote: outcome?.noRecorderBeside ?? "", causes: outcome?.causes ?? [],
            busy: model.busy ?? "", problem: model.problem(for: .recorder)?.asABody ?? "",
            recorders: model.found.map { FoundRecorder($0, inUse: model.inUse($0)) },
            canChoose: model.canChangeRecorder, demo: model.demo,
            chosenAnswered: choosing.chosenAt.map { model.timesAttached > $0 } ?? false)
    }
}
