import Foundation
import Observation
import RecorderKit

/// Which channels the guide shows, and in what order, one broadcasting type at a time. The cache keeps the reader's
/// choice (`GuideStore.setChannelPreferences`), and the list, the grid and the search follow it. A broadcasting type
/// easily has sixty channels, most of them never watched, and the grid is read across them.
///
/// Only this phone's guide changes. The recorder is not told, the reservations and recordings lists show every
/// channel as before, and a hidden channel records as it always did. The screen lays it out and hands this the
/// reader's toggles and drags.
@MainActor
@Observable
public final class ChannelsState {
    @ObservationIgnored private let model: AppModel

    /// The broadcasting type picked.
    public var broadcasting: String
    public private(set) var channels: [Channel] = []
    /// The broadcasting type `channels` was read for. The picker moves before the new list is in, and a change made
    /// in between belongs to the list on screen, not to the type just picked.
    public private(set) var listed: String
    public private(set) var loaded = false
    public var failure: String?

    public init(broadcasting: String, model: AppModel) {
        self.model = model
        self.broadcasting = broadcasting
        listed = broadcasting
    }

    /// What the list is read again for: another broadcasting type, or the cache changing underneath it -- a refresh
    /// bringing in a channel, or the demo starting or ending, which puts another cache in its place.
    public struct Source: Equatable, Sendable {
        var broadcasting: String
        var counts: GuideCounts?
        var demo: Bool
    }

    public var source: Source {
        Source(broadcasting: broadcasting, counts: model.counts[broadcasting], demo: model.demo)
    }

    /// The broadcasting types the picker offers.
    public var types: [String] { GuideRefresh.offeredTypes(model.counts) }

    /// Whether anything differs from the recorder's order with everything shown, which is what the reset goes back
    /// to.
    public var customised: Bool { channels.contains { $0.hidden || $0.position != nil } }

    /// The screen's title, which is also what the way to it is called, in the guide's menu and in the settings, whose
    /// words are defined as it and so are not the main actor's.
    public nonisolated static let title = "チャンネルの表示と並び順"

    /// What the screen says under the list, and the question before the reset, for the type the list is of.
    public static let footer = "オフにした局は、番組表と番組の検索に出なくなります。右端の三本線をドラッグすると、並び順を変えられます。"
        + "予約と録画の一覧、レコーダーの録画はそのままです。"
    public var resetQuestion: String {
        "\(Codes.broadcastingInSentence(listed))の局をすべて表示して、レコーダーの順に戻しますか？"
    }

    /// What an empty list says: the type has no channels, and where they come from.
    public var empty: AppModel.ScreenSays {
        AppModel.ScreenSays("\(Codes.broadcastingInSentence(broadcasting))の局はありません",
                            model.demo ? DemoLineUp.guideCoverage : "局の一覧は、番組表と一緒にレコーダーから取得します")
    }

    // MARK: - the reader's changes

    /// Whether `channel` is shown, as the list on screen has it.
    public func isShown(_ channel: Channel) -> Bool {
        !(channels.first { $0.id == channel.id }?.hidden ?? channel.hidden)
    }

    /// A channel turned on or off: the list on screen first, then the cache (`save`).
    public func show(_ channel: Channel, _ show: Bool) {
        guard let index = channels.firstIndex(where: { $0.id == channel.id }) else { return }
        channels[index].hidden = !show
        let broadcasting = listed
        let hidden = channels.filter(\.hidden).map(\.serviceID)
        save { try await self.model.setChannelPreferences(broadcasting: broadcasting, hidden: hidden) }
    }

    /// Channels dragged to another place, as a list moves rows: those at `offsets` taken out, in their order, and
    /// put back before the row that was at `destination`.
    public func move(from offsets: IndexSet, to destination: Int) {
        let moving = offsets.map { channels[$0] }
        var rest = channels
        for index in offsets.sorted(by: >) { rest.remove(at: index) }
        rest.insert(contentsOf: moving, at: destination - offsets.count { $0 < destination })
        channels = rest
        // As the cache will hold them, so that the reset knows there is an order to undo.
        for index in channels.indices { channels[index].position = index }
        let broadcasting = listed
        let order = channels.map(\.serviceID)
        save { try await self.model.setChannelPreferences(broadcasting: broadcasting, order: order) }
    }

    /// レコーダーの順に戻す: every channel shown, in the recorder's order, and the list read again.
    public func reset() {
        let broadcasting = listed
        save {
            try await self.model.setChannelPreferences(broadcasting: broadcasting, order: [], hidden: [])
            await self.read()
        }
    }

    /// The list on screen is changed first and the cache after, so a drag does not wait on the database. A save
    /// that fails puts the list back to what the cache holds, and says why. Each waits for the one before it,
    /// whichever screen made that one: the saves are in one line for the model (`AppModel.savingChannels`).
    /// What runs in that line reads the list with `read`, never `load`, which would wait for itself.
    private func save(_ change: @escaping @MainActor () async throws -> Void) {
        let before = model.savingChannels
        model.savingChannels = Task {
            await before?.value
            do {
                try await change()
            } catch {
                failure = String(describing: error)
                await read()
            }
        }
    }

    /// Reads the list for the type picked, once every save under way is done, this screen's or another's: for the
    /// screen to run as the source changes (`source`).
    public func load() async {
        await model.savingChannels?.value
        await read()
    }

    private func read() async {
        let wanted = broadcasting
        do {
            let read = try await model.channelsToArrange(broadcasting: wanted)
            // The picker may have moved on while this was being read, and the read for that is on its way.
            guard wanted == broadcasting else { return }
            channels = read
            listed = wanted
        } catch {
            failure = String(describing: error)
        }
        loaded = true
    }
}
