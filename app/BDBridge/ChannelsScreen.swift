import RecorderKit
import SwiftUI

/// Which channels the guide shows, and in what order, one broadcasting type at a time. The cache has kept the
/// reader's choice all along (`GuideStore.setChannelPreferences`), and the list, the grid and the search follow
/// it; only a screen to make it on was missing, while the store's description of the app promised one. A
/// broadcasting type easily has sixty channels, most of them never watched, and the grid is read across them.
///
/// Only this phone's guide changes. The recorder is not told, the reservations and recordings lists show
/// every channel as before, and a hidden channel records as it always did.
struct ChannelsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var broadcasting: String
    @State private var channels: [Channel] = []
    /// The broadcasting type `channels` was read for. The picker moves before the new list is in, and a change
    /// made in between belongs to the list on screen, not to the type just picked.
    @State private var listed: String
    @State private var loaded = false
    @State private var failure: String?
    @State private var confirmingReset = false
    /// The save under way. Each waits for the one before it: a save carries the whole of the order, or the
    /// whole of what is hidden, so two quick changes arriving the wrong way round would undo the second.
    @State private var saving: Task<Void, Never>?

    init(broadcasting: String) {
        _broadcasting = State(initialValue: broadcasting)
        _listed = State(initialValue: broadcasting)
    }

    /// What the list is read again for: another broadcasting type, or the cache changing underneath it -- a
    /// refresh bringing in a channel, or the demo starting or ending, which puts another cache in its place.
    private struct Source: Equatable {
        var broadcasting: String
        var counts: GuideCounts?
        var demo: Bool
    }

    private var source: Source {
        Source(broadcasting: broadcasting, counts: model.counts[broadcasting], demo: model.demo)
    }

    /// Whether anything differs from the recorder's order with everything shown, which is what the reset
    /// goes back to.
    private var customised: Bool {
        channels.contains { $0.hidden || $0.position != nil }
    }

    var body: some View {
        List {
            if !channels.isEmpty {
                Section {
                    ForEach(channels) { channel in
                        ChannelRow(channel: channel, shown: shown(channel))
                    }
                    .onMove(perform: move)
                } footer: {
                    Text("オフにした局は、番組表と番組の検索に出なくなります。右端の三本線をドラッグすると、並び順を変えられます。"
                         + "予約と録画の一覧、レコーダーの録画はそのままです。")
                }
                Section {
                    Button("レコーダーの順に戻して、すべて表示") { confirmingReset = true }
                        .disabled(!customised)
                        // On the button, which is where the question then points from.
                        .confirmationDialog("\(GuideEmptyView.inSentence(listed))の局をすべて表示して、"
                                            + "レコーダーの順に戻しますか？",
                                            isPresented: $confirmingReset, titleVisibility: .visible) {
                            Button("レコーダーの順に戻す") { reset() }
                        }
                }
            }
        }
        // Always editing, so that every row shows its handle. A reorder behind an 編集 button is one that few
        // would find, and there is nothing else on this screen for the button to switch away from.
        .environment(\.editMode, .constant(.active))
        .overlay {
            if loaded, channels.isEmpty { empty }
        }
        .safeAreaInset(edge: .top, spacing: 0) { typePicker }
        .navigationTitle("チャンネルの表示と並び順")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: source) { await load() }
        .alert("保存できませんでした", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private var typePicker: some View {
        Picker("放送", selection: $broadcasting) {
            ForEach(GuideRefresh.broadcastingTypes, id: \.self) { type in
                Text(GuideScreen.shortLabel[type] ?? type).tag(type)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var empty: some View {
        let type = GuideEmptyView.inSentence(broadcasting)
        ContentUnavailableView("\(type)の局はありません", systemImage: "antenna.radiowaves.left.and.right",
                               description: Text(model.demo ? DemoData.guideCoverage
                                                            : "局の一覧は、番組表と一緒にレコーダーから取得します"))
    }

    private func shown(_ channel: Channel) -> Binding<Bool> {
        Binding(get: {
            !(channels.first { $0.id == channel.id }?.hidden ?? channel.hidden)
        }, set: { show in
            guard let index = channels.firstIndex(where: { $0.id == channel.id }) else { return }
            channels[index].hidden = !show
            let broadcasting = listed
            let hidden = channels.filter(\.hidden).map(\.serviceID)
            save { try await model.setChannelPreferences(broadcasting: broadcasting, hidden: hidden) }
        })
    }

    private func move(from source: IndexSet, to destination: Int) {
        channels.move(fromOffsets: source, toOffset: destination)
        // As the cache will hold them, so that the reset knows there is an order to undo.
        for index in channels.indices { channels[index].position = index }
        let broadcasting = listed
        let order = channels.map(\.serviceID)
        save { try await model.setChannelPreferences(broadcasting: broadcasting, order: order) }
    }

    private func reset() {
        let broadcasting = listed
        save {
            try await model.setChannelPreferences(broadcasting: broadcasting, order: [], hidden: [])
            await read()
        }
    }

    /// The list on screen is changed first and the cache after, so a drag does not wait on the database. A
    /// save that fails puts the list back to what the cache holds, and says why.
    private func save(_ change: @escaping @MainActor () async throws -> Void) {
        let before = saving
        saving = Task {
            await before?.value
            do {
                try await change()
            } catch {
                failure = String(describing: error)
                await read()
            }
        }
    }

    private func load() async {
        await saving?.value
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

/// The same over the guide, opened from its channel menu or from an empty guide with every channel hidden.
struct ChannelsSheet: View {
    let broadcasting: String

    var body: some View {
        NavigationStack {
            ChannelsScreen(broadcasting: broadcasting)
                .toolbar { SheetCloseButton() }
        }
    }
}

private struct ChannelRow: View {
    let channel: Channel
    @Binding var shown: Bool

    var body: some View {
        Toggle(isOn: $shown) {
            HStack(spacing: 10) {
                // The space is held where a station has no logo, so that the names line up.
                Group {
                    if let logo = channel.logo, let image = UIImage(data: logo) {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 36, height: 18)
                .accessibilityHidden(true)
                Text(channel.name)
                    .foregroundStyle(shown ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
    }
}
