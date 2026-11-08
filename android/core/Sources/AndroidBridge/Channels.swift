import Foundation
import Observation
import RecBridgeModel
import RecorderKit

/// Which stations the guide shows, and in what order, one broadcasting type at a time, over the model's own state of
/// it (`ChannelsState`): only this phone's guide changes.
public struct ChannelsScreen: Sendable {
    /// The broadcasting types offered, by their short names, and the one picked.
    public var types: [Labelled]
    public var broadcasting: String
    /// The stations of the type the list was read for, in the reader's order.
    public var stations: [ArrangedStation]
    /// The list has been read once: an empty one is then the type's having no stations (`empty`).
    public var loaded: Bool
    public var empty: Said
    /// Whether anything differs from the recorder's order with every station shown, which the reset goes back to.
    public var customised: Bool
    public var footer: String
    public var resetQuestion: String
    /// What a save that did not go through had to say.
    public var failure: String
}

public struct ArrangedStation: Sendable {
    public var id: String
    public var name: String
    /// The logo the recorder sent for it, as an image file; empty for a station whose logo the recorder never had.
    public var logo: [UInt8]
    public var shown: Bool
}

public final class ChannelsWindow: Sendable {
    let channels: ChannelsState
    private let shown: Watched<ChannelsScreen>
    private let follows = Follows()

    @MainActor
    init(_ channels: ChannelsState) {
        self.channels = channels
        shown = Watched { ChannelsWindow.screen(channels) }
        // `task(id: channels.source)`: read again for another type, or for the cache changing underneath, the last
        // read given up.
        follows.add(Task { @MainActor in
            var reading: Task<Void, Never>?
            var last: ChannelsState.Source?
            for await source in Observations({ channels.source }) where source != last {
                last = source
                reading?.cancel()
                reading = Task { await channels.load() }
            }
            reading?.cancel()
        })
    }

    public func read() async -> ChannelsScreen { await shown.read() }

    public func observe(_ listener: some ScreenListener) {
        follows.add(shown.watch(listener))
    }

    /// The screen has closed: nothing more is followed for it. A save under way goes on.
    public func closed() async {
        follows.end()
    }

    /// The broadcasting type, one of those offered.
    public func choose(_ broadcasting: String) async {
        await MainActor.run { if channels.types.contains(broadcasting) { channels.broadcasting = broadcasting } }
    }

    /// A station turned on or off.
    public func show(_ id: String, _ show: Bool) async {
        await MainActor.run {
            guard let channel = channels.channels.first(where: { $0.id == id }) else { return }
            channels.show(channel, show)
        }
    }

    /// A station dragged from where it was, `from`, to where it is now, `to`, both as places in the list on screen.
    public func move(from: Int64, to: Int64) async {
        await MainActor.run {
            let count = Int64(channels.channels.count)
            guard from != to, (0..<count).contains(from), (0..<count).contains(to) else { return }
            // As a list moves its rows: put back before the row that was at the place handed on.
            channels.move(from: IndexSet(integer: Int(from)), to: Int(to > from ? to + 1 : to))
        }
    }

    /// レコーダーの順に戻す, answered yes.
    public func reset() async {
        await MainActor.run { if channels.customised { channels.reset() } }
    }

    /// The report of a save that did not go through has been closed.
    public func failureClosed() async {
        await MainActor.run { channels.failure = nil }
    }

    @MainActor
    private static func screen(_ channels: ChannelsState) -> ChannelsScreen {
        ChannelsScreen(
            types: channels.types.map { Labelled(code: $0, label: Codes.broadcastingShortLabel[$0] ?? $0) },
            broadcasting: channels.broadcasting,
            stations: channels.channels.map {
                ArrangedStation(id: $0.id, name: $0.name, logo: $0.logo.map { [UInt8]($0) } ?? [], shown: !$0.hidden)
            },
            loaded: channels.loaded, empty: Said(channels.empty), customised: channels.customised,
            footer: ChannelsState.footer, resetQuestion: channels.resetQuestion,
            failure: channels.failure?.asABody ?? "")
    }
}
